[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ProfilePath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$PrinterIp,

    [ValidateNotNullOrEmpty()]
    [string]$Community = 'public',

    [ValidateRange(100,10000)]
    [int]$ResponseTimeoutMs = 2000,

    [ValidateRange(1,64)]
    [int]$MaxRows = 64,

    [switch]$ConfirmSnmpAlertWalk
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $ConfirmSnmpAlertWalk) {
    throw 'Physical printer SNMP alert-table walk was not confirmed. Re-run with -ConfirmSnmpAlertWalk.'
}

function Join-ByteArray {
    param([Parameter(ValueFromRemainingArguments)][byte[][]]$Arrays)
    $result = [System.Collections.Generic.List[byte]]::new()
    foreach ($array in $Arrays) { if ($null -ne $array) { $result.AddRange($array) } }
    return $result.ToArray()
}

function ConvertTo-BerLength {
    param([int]$Length)
    if ($Length -lt 0x80) { return [byte[]]@([byte]$Length) }
    $octets = [System.Collections.Generic.List[byte]]::new()
    $remaining = $Length
    while ($remaining -gt 0) {
        $octets.Insert(0, [byte]($remaining -band 0xFF))
        $remaining = $remaining -shr 8
    }
    return Join-ByteArray ([byte[]]@([byte](0x80 -bor $octets.Count))) $octets.ToArray()
}

function ConvertTo-BerTlv {
    param([byte]$Tag, [byte[]]$Content)
    return Join-ByteArray ([byte[]]@($Tag)) (ConvertTo-BerLength $Content.Length) $Content
}

function ConvertTo-BerIntegerContent {
    param([int]$Value)
    if ($Value -lt 0) { throw 'Only non-negative request integers are supported.' }
    $octets = [System.Collections.Generic.List[byte]]::new()
    $remaining = [uint32]$Value
    do {
        $octets.Insert(0, [byte]($remaining -band 0xFF))
        $remaining = $remaining -shr 8
    } while ($remaining -gt 0)
    if (($octets[0] -band 0x80) -ne 0) { $octets.Insert(0, 0) }
    return $octets.ToArray()
}

function ConvertTo-BerOidContent {
    param([string]$Oid)
    $parts = @($Oid.Trim('.').Split('.') | ForEach-Object { [uint64]$_ })
    if ($parts.Count -lt 2 -or $parts[0] -gt 2 -or $parts[1] -gt 39) { throw "Unsupported OID: $Oid" }
    $encoded = [System.Collections.Generic.List[byte]]::new()
    $encoded.Add([byte](40 * $parts[0] + $parts[1]))
    foreach ($part in $parts[2..($parts.Count - 1)]) {
        $base128 = [System.Collections.Generic.List[byte]]::new()
        $remaining = [uint64]$part
        do {
            $base128.Insert(0, [byte]($remaining -band 0x7F))
            $remaining = $remaining -shr 7
        } while ($remaining -gt 0)
        for ($index = 0; $index -lt ($base128.Count - 1); $index++) { $base128[$index] = [byte]($base128[$index] -bor 0x80) }
        $encoded.AddRange($base128)
    }
    return $encoded.ToArray()
}

function Read-BerTlv {
    param([byte[]]$Bytes, [ref]$Offset)
    if ($Offset.Value -ge $Bytes.Length) { throw 'Unexpected end of BER response while reading tag.' }
    $tag = $Bytes[$Offset.Value]
    $Offset.Value++
    if ($Offset.Value -ge $Bytes.Length) { throw 'Unexpected end of BER response while reading length.' }
    $firstLength = $Bytes[$Offset.Value]
    $Offset.Value++
    if (($firstLength -band 0x80) -eq 0) { $length = [int]$firstLength }
    else {
        $lengthOctets = $firstLength -band 0x7F
        if ($lengthOctets -eq 0 -or $lengthOctets -gt 4 -or ($Offset.Value + $lengthOctets) -gt $Bytes.Length) { throw 'Unsupported or truncated BER length.' }
        $length = 0
        for ($index = 0; $index -lt $lengthOctets; $index++) {
            $length = ($length -shl 8) -bor $Bytes[$Offset.Value]
            $Offset.Value++
        }
    }
    if (($Offset.Value + $length) -gt $Bytes.Length) { throw 'BER value exceeds response boundary.' }
    $contentOffset = $Offset.Value
    $Offset.Value += $length
    return [pscustomobject]@{ Tag = $tag; Length = $length; ContentOffset = $contentOffset; EndOffset = $Offset.Value }
}

function ConvertFrom-BerSignedInteger {
    param([byte[]]$Bytes, [object]$Tlv)
    if ($Tlv.Length -lt 1 -or $Tlv.Length -gt 8) { throw 'Invalid BER integer length.' }
    [int64]$value = if (($Bytes[$Tlv.ContentOffset] -band 0x80) -ne 0) { -1 } else { 0 }
    for ($index = 0; $index -lt $Tlv.Length; $index++) { $value = ($value -shl 8) -bor $Bytes[$Tlv.ContentOffset + $index] }
    return $value
}

function ConvertFrom-BerUnsignedInteger {
    param([byte[]]$Bytes, [object]$Tlv)
    if ($Tlv.Length -lt 1 -or $Tlv.Length -gt 5) { throw 'Invalid BER unsigned integer length.' }
    [uint64]$value = 0
    for ($index = 0; $index -lt $Tlv.Length; $index++) { $value = ($value -shl 8) -bor $Bytes[$Tlv.ContentOffset + $index] }
    return $value
}

function ConvertFrom-BerOid {
    param([byte[]]$Bytes, [object]$Tlv)
    if ($Tlv.Tag -ne 0x06 -or $Tlv.Length -lt 1) { throw 'Invalid BER OID.' }
    $first = [int]$Bytes[$Tlv.ContentOffset]
    if ($first -lt 40) { $parts = [System.Collections.Generic.List[uint64]]@(0, $first) }
    elseif ($first -lt 80) { $parts = [System.Collections.Generic.List[uint64]]@(1, ($first - 40)) }
    else { $parts = [System.Collections.Generic.List[uint64]]@(2, ($first - 80)) }
    [uint64]$component = 0
    for ($index = 1; $index -lt $Tlv.Length; $index++) {
        $octet = $Bytes[$Tlv.ContentOffset + $index]
        $component = ($component -shl 7) -bor ($octet -band 0x7F)
        if (($octet -band 0x80) -eq 0) { $parts.Add($component); $component = 0 }
    }
    if ($component -ne 0) { throw 'Truncated BER OID component.' }
    return ($parts -join '.')
}

function ConvertTo-SnmpGetNextPacket {
    param([string]$Oid, [int]$RequestId, [string]$CommunityValue)
    $varBind = ConvertTo-BerTlv 0x30 (Join-ByteArray (ConvertTo-BerTlv 0x06 (ConvertTo-BerOidContent $Oid)) ([byte[]]@(0x05,0x00)))
    $varBindList = ConvertTo-BerTlv 0x30 $varBind
    $pdu = ConvertTo-BerTlv 0xA1 (Join-ByteArray `
        (ConvertTo-BerTlv 0x02 (ConvertTo-BerIntegerContent $RequestId)) `
        (ConvertTo-BerTlv 0x02 ([byte[]]@(0x00))) `
        (ConvertTo-BerTlv 0x02 ([byte[]]@(0x00))) `
        $varBindList)
    return ConvertTo-BerTlv 0x30 (Join-ByteArray `
        (ConvertTo-BerTlv 0x02 ([byte[]]@(0x00))) `
        (ConvertTo-BerTlv 0x04 ([System.Text.Encoding]::ASCII.GetBytes($CommunityValue))) `
        $pdu)
}

function Read-SnmpResponse {
    param([byte[]]$Bytes, [int]$ExpectedRequestId, [string]$ExpectedCommunity)
    $offset = 0
    $message = Read-BerTlv $Bytes ([ref]$offset)
    if ($message.Tag -ne 0x30 -or $message.EndOffset -ne $Bytes.Length) { throw 'Invalid SNMP message sequence.' }
    $innerOffset = $message.ContentOffset
    $version = Read-BerTlv $Bytes ([ref]$innerOffset)
    if ((ConvertFrom-BerSignedInteger $Bytes $version) -ne 0) { throw 'SNMP response is not version 1.' }
    $responseCommunity = Read-BerTlv $Bytes ([ref]$innerOffset)
    if ($responseCommunity.Tag -ne 0x04) { throw 'Malformed SNMP response community.' }
    $responseCommunityValue = [System.Text.Encoding]::ASCII.GetString(
        $Bytes,
        $responseCommunity.ContentOffset,
        $responseCommunity.Length
    )
    if ($responseCommunityValue -cne $ExpectedCommunity) { throw 'SNMP response community does not match the request.' }
    $responsePdu = Read-BerTlv $Bytes ([ref]$innerOffset)
    if ($responsePdu.Tag -ne 0xA2) { throw ('Unexpected SNMP response PDU tag: 0x{0:X2}.' -f $responsePdu.Tag) }
    $pduOffset = $responsePdu.ContentOffset
    $requestIdTlv = Read-BerTlv $Bytes ([ref]$pduOffset)
    if ((ConvertFrom-BerSignedInteger $Bytes $requestIdTlv) -ne $ExpectedRequestId) { throw 'SNMP request ID does not match.' }
    $errorStatus = ConvertFrom-BerSignedInteger $Bytes (Read-BerTlv $Bytes ([ref]$pduOffset))
    $errorIndex = ConvertFrom-BerSignedInteger $Bytes (Read-BerTlv $Bytes ([ref]$pduOffset))
    if ($errorStatus -ne 0) { throw "SNMP agent returned error status $errorStatus at index $errorIndex." }
    $varBindList = Read-BerTlv $Bytes ([ref]$pduOffset)
    $varBindOffset = $varBindList.ContentOffset
    $varBind = Read-BerTlv $Bytes ([ref]$varBindOffset)
    $valueOffset = $varBind.ContentOffset
    $oidTlv = Read-BerTlv $Bytes ([ref]$valueOffset)
    $responseOid = ConvertFrom-BerOid $Bytes $oidTlv
    $valueTlv = Read-BerTlv $Bytes ([ref]$valueOffset)
    switch ($valueTlv.Tag) {
        0x02 { $type = 'Integer'; $value = ConvertFrom-BerSignedInteger $Bytes $valueTlv }
        0x04 { $type = 'OctetString'; $value = [System.Text.Encoding]::ASCII.GetString($Bytes, $valueTlv.ContentOffset, $valueTlv.Length) }
        0x05 { $type = 'Null'; $value = $null }
        0x06 { $type = 'Oid'; $value = ConvertFrom-BerOid $Bytes $valueTlv }
        0x41 { $type = 'Counter32'; $value = ConvertFrom-BerUnsignedInteger $Bytes $valueTlv }
        0x42 { $type = 'Gauge32'; $value = ConvertFrom-BerUnsignedInteger $Bytes $valueTlv }
        0x43 { $type = 'TimeTicks'; $value = ConvertFrom-BerUnsignedInteger $Bytes $valueTlv }
        default { $type = 'Raw'; $value = [Convert]::ToHexString($Bytes[$valueTlv.ContentOffset..($valueTlv.EndOffset - 1)]) }
    }
    return [pscustomobject]@{ Oid = $responseOid; ValueType = $type; Value = $value; Tag = ('0x{0:X2}' -f $valueTlv.Tag) }
}

$hardwareRoot = (Resolve-Path -LiteralPath $PSScriptRoot).Path
$profilesRoot = (Resolve-Path -LiteralPath (Join-Path $hardwareRoot 'Profiles')).Path
$profilesRootPrefix = $profilesRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
$resolvedProfilePath = (Resolve-Path -LiteralPath $ProfilePath -ErrorAction Stop).Path
if (-not $resolvedProfilePath.StartsWith($profilesRootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) { throw "ProfilePath must be inside the hardware Profiles directory: $profilesRoot" }
$schemaPath = Join-Path $hardwareRoot 'Schemas\printer-test-profile-v1.schema.json'
$profileJson = Get-Content -LiteralPath $resolvedProfilePath -Raw
if (-not ($profileJson | Test-Json -SchemaFile $schemaPath)) { throw 'Printer test profile does not satisfy the profile schema.' }
$printerProfile = $profileJson | ConvertFrom-Json

$parsedIp = $null
if (-not [System.Net.IPAddress]::TryParse($PrinterIp, [ref]$parsedIp)) { throw "PrinterIp is not a valid IP address: $PrinterIp" }
if ($parsedIp.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { throw 'Only IPv4 printer addresses are supported.' }
$ipBytes = $parsedIp.GetAddressBytes()
$isPrivateIpv4 = ($ipBytes[0] -eq 10) -or ($ipBytes[0] -eq 172 -and $ipBytes[1] -ge 16 -and $ipBytes[1] -le 31) -or ($ipBytes[0] -eq 192 -and $ipBytes[1] -eq 168)
if (-not $isPrivateIpv4) { throw 'PrinterIp must be an RFC1918 private IPv4 address.' }

$subtreeOid = '1.3.6.1.2.1.43.18.1.1'
$currentOid = $subtreeOid
$rows = [System.Collections.Generic.List[object]]::new()
$attemptCount = 0
$sendStarted = $false
$status = 'FAILED'
$failure = $null
$startedAtUtc = [DateTime]::UtcNow
$finishedAtUtc = $null
$udp = [System.Net.Sockets.UdpClient]::new()

try {
    $udp.Connect($parsedIp, 161)
    $status = 'RESPONSE_RECEIVED'
    for ($rowIndex = 0; $rowIndex -lt $MaxRows; $rowIndex++) {
        $requestId = [System.Security.Cryptography.RandomNumberGenerator]::GetInt32(1, 0x7FFFFFFF)
        $packet = ConvertTo-SnmpGetNextPacket $currentOid $requestId $Community
        $attemptCount++
        $sendStarted = $true
        $status = 'UNKNOWN'
        $bytesSent = $udp.Send($packet, $packet.Length)
        if ($bytesSent -ne $packet.Length) { throw "UDP send accepted $bytesSent of $($packet.Length) bytes." }
        $receiveTask = $udp.ReceiveAsync()
        if (-not $receiveTask.Wait($ResponseTimeoutMs)) { throw "SNMP response timed out after $ResponseTimeoutMs ms." }
        $response = Read-SnmpResponse $receiveTask.Result.Buffer $requestId $Community
        $status = 'RESPONSE_RECEIVED'
        if (-not $response.Oid.StartsWith($subtreeOid + '.', [System.StringComparison]::Ordinal)) { break }
        if ($response.Oid -ceq $currentOid) { throw 'SNMP GETNEXT did not advance the OID.' }
        $rows.Add($response)
        $currentOid = $response.Oid
    }
}
catch {
    $failure = $_.Exception.GetBaseException().Message
    if (-not $sendStarted) { $status = 'FAILED' }
}
finally {
    $finishedAtUtc = [DateTime]::UtcNow
    $udp.Dispose()
}

$testRunId = 'HWSNMPALERT-{0}-{1}' -f ($startedAtUtc.ToString('yyyyMMddTHHmmssZ', [System.Globalization.CultureInfo]::InvariantCulture)), ([guid]::NewGuid().ToString('N').Substring(0,8))
$outputRoot = Join-Path $hardwareRoot 'Output'
New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
$evidence = [ordered]@{
    schemaVersion = '1.0'; testRunId = $testRunId; testType = 'SnmpReadOnlyAlertTableWalk'
    profileId = [string]$printerProfile.profileId; printerIp = $parsedIp.ToString(); printerPort = 161
    snmpVersion = 'v1'; operation = 'GETNEXT'; subtreeOid = $subtreeOid; maxRows = $MaxRows
    rows = @($rows); rowCount = $rows.Count; requestCount = $attemptCount
    automaticRetryPerformed = $false; queryStatus = $status; readOnly = $true
    printPortContacted = $false; printDataIncluded = $false
    startedAtUtc = $startedAtUtc.ToString('O', [System.Globalization.CultureInfo]::InvariantCulture)
    finishedAtUtc = $finishedAtUtc.ToString('O', [System.Globalization.CultureInfo]::InvariantCulture); failure = $failure
}
$evidencePath = Join-Path $outputRoot ($testRunId + '.evidence.json')
$temporaryEvidencePath = $evidencePath + '.tmp'
[System.IO.File]::WriteAllText($temporaryEvidencePath, (($evidence | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
Move-Item -LiteralPath $temporaryEvidencePath -Destination $evidencePath

[pscustomobject]@{
    TestRunId = $testRunId; TestType = 'SnmpReadOnlyAlertTableWalk'; QueryStatus = $status
    SubtreeOid = $subtreeOid; RowCount = $rows.Count; RequestCount = $attemptCount
    Rows = @($rows); AutomaticRetryPerformed = $false; ReadOnly = $true
    PrintPortContacted = $false; EvidencePath = $evidencePath; Failure = $failure
}
