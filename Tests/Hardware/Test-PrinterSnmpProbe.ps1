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

    [ValidatePattern('^\d+(?:\.\d+)+$')]
    [string]$Oid = '1.3.6.1.2.1.1.1.0',

    [ValidateRange(100,10000)]
    [int]$ResponseTimeoutMs = 2000,

    [switch]$ConfirmSnmpProbe
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $ConfirmSnmpProbe) {
    throw 'Physical printer SNMP probe was not confirmed. Re-run with -ConfirmSnmpProbe.'
}

function Join-ByteArray {
    param([Parameter(ValueFromRemainingArguments)][byte[][]]$Arrays)
    $result = [System.Collections.Generic.List[byte]]::new()
    foreach ($array in $Arrays) {
        if ($null -ne $array) {
            $result.AddRange($array)
        }
    }
    return $result.ToArray()
}

function ConvertTo-BerLength {
    param([int]$Length)
    if ($Length -lt 0x80) {
        return [byte[]]@([byte]$Length)
    }
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
    if ($Value -lt 0) {
        throw 'Only non-negative BER integers are supported by this probe.'
    }
    $octets = [System.Collections.Generic.List[byte]]::new()
    $remaining = [uint32]$Value
    do {
        $octets.Insert(0, [byte]($remaining -band 0xFF))
        $remaining = $remaining -shr 8
    } while ($remaining -gt 0)
    if (($octets[0] -band 0x80) -ne 0) {
        $octets.Insert(0, 0)
    }
    return $octets.ToArray()
}

function ConvertTo-BerOidContent {
    param([string]$Oid)
    $parts = @($Oid.Trim('.').Split('.') | ForEach-Object { [uint64]$_ })
    if ($parts.Count -lt 2 -or $parts[0] -gt 2 -or $parts[1] -gt 39) {
        throw "Unsupported OID: $Oid"
    }
    $encoded = [System.Collections.Generic.List[byte]]::new()
    $encoded.Add([byte](40 * $parts[0] + $parts[1]))
    foreach ($part in $parts[2..($parts.Count - 1)]) {
        $base128 = [System.Collections.Generic.List[byte]]::new()
        $remaining = [uint64]$part
        do {
            $base128.Insert(0, [byte]($remaining -band 0x7F))
            $remaining = $remaining -shr 7
        } while ($remaining -gt 0)
        for ($index = 0; $index -lt ($base128.Count - 1); $index++) {
            $base128[$index] = [byte]($base128[$index] -bor 0x80)
        }
        $encoded.AddRange($base128)
    }
    return $encoded.ToArray()
}

function Read-BerTlv {
    param([byte[]]$Bytes, [ref]$Offset)
    if ($Offset.Value -ge $Bytes.Length) {
        throw 'Unexpected end of BER response while reading tag.'
    }
    $tag = $Bytes[$Offset.Value]
    $Offset.Value++
    if ($Offset.Value -ge $Bytes.Length) {
        throw 'Unexpected end of BER response while reading length.'
    }
    $firstLength = $Bytes[$Offset.Value]
    $Offset.Value++
    if (($firstLength -band 0x80) -eq 0) {
        $length = [int]$firstLength
    }
    else {
        $lengthOctets = $firstLength -band 0x7F
        if ($lengthOctets -eq 0 -or $lengthOctets -gt 4 -or ($Offset.Value + $lengthOctets) -gt $Bytes.Length) {
            throw 'Unsupported or truncated BER length.'
        }
        $length = 0
        for ($index = 0; $index -lt $lengthOctets; $index++) {
            $length = ($length -shl 8) -bor $Bytes[$Offset.Value]
            $Offset.Value++
        }
    }
    if (($Offset.Value + $length) -gt $Bytes.Length) {
        throw 'BER value exceeds response boundary.'
    }
    $contentOffset = $Offset.Value
    $Offset.Value += $length
    return [pscustomobject]@{ Tag = $tag; Length = $length; ContentOffset = $contentOffset; EndOffset = $Offset.Value }
}

function ConvertFrom-BerInteger {
    param([byte[]]$Bytes, [object]$Tlv)
    if ($Tlv.Tag -ne 0x02 -or $Tlv.Length -lt 1 -or $Tlv.Length -gt 4) {
        throw 'Invalid BER integer.'
    }
    [int64]$value = if (($Bytes[$Tlv.ContentOffset] -band 0x80) -ne 0) { -1 } else { 0 }
    for ($index = 0; $index -lt $Tlv.Length; $index++) {
        $value = ($value -shl 8) -bor $Bytes[$Tlv.ContentOffset + $index]
    }
    return [int]$value
}

function ConvertFrom-BerOid {
    param([byte[]]$Bytes, [object]$Tlv)
    if ($Tlv.Tag -ne 0x06 -or $Tlv.Length -lt 1) {
        throw 'Invalid BER OID.'
    }
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

$hardwareRoot = (Resolve-Path -LiteralPath $PSScriptRoot).Path
$profilesRoot = (Resolve-Path -LiteralPath (Join-Path $hardwareRoot 'Profiles')).Path
$profilesRootPrefix = $profilesRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
$resolvedProfilePath = (Resolve-Path -LiteralPath $ProfilePath -ErrorAction Stop).Path
if (-not $resolvedProfilePath.StartsWith($profilesRootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "ProfilePath must be inside the hardware Profiles directory: $profilesRoot"
}
$schemaPath = Join-Path $hardwareRoot 'Schemas\printer-test-profile-v1.schema.json'
$profileJson = Get-Content -LiteralPath $resolvedProfilePath -Raw
if (-not ($profileJson | Test-Json -SchemaFile $schemaPath)) {
    throw 'Printer test profile does not satisfy the profile schema.'
}
$printerProfile = $profileJson | ConvertFrom-Json

$parsedIp = $null
if (-not [System.Net.IPAddress]::TryParse($PrinterIp, [ref]$parsedIp)) {
    throw "PrinterIp is not a valid IP address: $PrinterIp"
}
if ($parsedIp.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
    throw 'Only IPv4 printer addresses are supported.'
}
$ipBytes = $parsedIp.GetAddressBytes()
$isPrivateIpv4 =
    ($ipBytes[0] -eq 10) -or
    ($ipBytes[0] -eq 172 -and $ipBytes[1] -ge 16 -and $ipBytes[1] -le 31) -or
    ($ipBytes[0] -eq 192 -and $ipBytes[1] -eq 168)
if (-not $isPrivateIpv4) {
    throw 'PrinterIp must be an RFC1918 private IPv4 address.'
}

$requestId = [System.Security.Cryptography.RandomNumberGenerator]::GetInt32(1, 0x7FFFFFFF)
$oidTlv = ConvertTo-BerTlv 0x06 (ConvertTo-BerOidContent $oid)
$nullTlv = [byte[]]@(0x05,0x00)
$varBind = ConvertTo-BerTlv 0x30 (Join-ByteArray $oidTlv $nullTlv)
$varBindList = ConvertTo-BerTlv 0x30 $varBind
$requestPdu = ConvertTo-BerTlv 0xA0 (Join-ByteArray `
    (ConvertTo-BerTlv 0x02 (ConvertTo-BerIntegerContent $requestId)) `
    (ConvertTo-BerTlv 0x02 ([byte[]]@(0x00))) `
    (ConvertTo-BerTlv 0x02 ([byte[]]@(0x00))) `
    $varBindList)
$packet = ConvertTo-BerTlv 0x30 (Join-ByteArray `
    (ConvertTo-BerTlv 0x02 ([byte[]]@(0x00))) `
    (ConvertTo-BerTlv 0x04 ([System.Text.Encoding]::ASCII.GetBytes($Community))) `
    $requestPdu)

$testRunId = 'HWSNMP-{0}-{1}' -f (
    [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ', [System.Globalization.CultureInfo]::InvariantCulture)
), ([guid]::NewGuid().ToString('N').Substring(0,8))
$startedAtUtc = [DateTime]::UtcNow
$finishedAtUtc = $null
$attemptCount = 1
$sendStarted = $false
$responseBytes = $null
$responseValue = $null
$responseValueType = $null
$semanticValue = $null
$status = 'FAILED'
$failure = $null
$udp = [System.Net.Sockets.UdpClient]::new()

try {
    $udp.Connect($parsedIp, 161)
    $sendStarted = $true
    $status = 'UNKNOWN'
    $bytesSent = $udp.Send($packet, $packet.Length)
    if ($bytesSent -ne $packet.Length) {
        throw "UDP send accepted $bytesSent of $($packet.Length) bytes."
    }

    $receiveTask = $udp.ReceiveAsync()
    if (-not $receiveTask.Wait($ResponseTimeoutMs)) {
        throw "SNMP response timed out after $ResponseTimeoutMs ms."
    }
    $responseBytes = $receiveTask.Result.Buffer

    $offset = 0
    $message = Read-BerTlv $responseBytes ([ref]$offset)
    if ($message.Tag -ne 0x30 -or $message.EndOffset -ne $responseBytes.Length) { throw 'Invalid SNMP message sequence.' }
    $innerOffset = $message.ContentOffset
    $version = Read-BerTlv $responseBytes ([ref]$innerOffset)
    if ((ConvertFrom-BerInteger $responseBytes $version) -ne 0) { throw 'SNMP response is not version 1.' }
    $responseCommunity = Read-BerTlv $responseBytes ([ref]$innerOffset)
    if ($responseCommunity.Tag -ne 0x04) { throw 'SNMP response community is malformed.' }
    $responseCommunityValue = [System.Text.Encoding]::ASCII.GetString(
        $responseBytes,
        $responseCommunity.ContentOffset,
        $responseCommunity.Length
    )
    if ($responseCommunityValue -cne $Community) { throw 'SNMP response community does not match the request.' }
    $responsePdu = Read-BerTlv $responseBytes ([ref]$innerOffset)
    if ($responsePdu.Tag -ne 0xA2) { throw ('Unexpected SNMP PDU tag: 0x{0:X2}.' -f $responsePdu.Tag) }
    $pduOffset = $responsePdu.ContentOffset
    $responseRequestId = Read-BerTlv $responseBytes ([ref]$pduOffset)
    if ((ConvertFrom-BerInteger $responseBytes $responseRequestId) -ne $requestId) { throw 'SNMP request ID does not match.' }
    $errorStatus = Read-BerTlv $responseBytes ([ref]$pduOffset)
    $errorStatusValue = ConvertFrom-BerInteger $responseBytes $errorStatus
    $errorIndex = Read-BerTlv $responseBytes ([ref]$pduOffset)
    $null = ConvertFrom-BerInteger $responseBytes $errorIndex
    if ($errorStatusValue -ne 0) { throw "SNMP agent returned error status $errorStatusValue." }
    $responseVarBindList = Read-BerTlv $responseBytes ([ref]$pduOffset)
    if ($responseVarBindList.Tag -ne 0x30) { throw 'SNMP varbind list is malformed.' }
    $varBindOffset = $responseVarBindList.ContentOffset
    $responseVarBind = Read-BerTlv $responseBytes ([ref]$varBindOffset)
    if ($responseVarBind.Tag -ne 0x30) { throw 'SNMP varbind is malformed.' }
    $valueOffset = $responseVarBind.ContentOffset
    $responseOid = Read-BerTlv $responseBytes ([ref]$valueOffset)
    if ($responseOid.Tag -ne 0x06) { throw 'SNMP response OID is malformed.' }
    $responseOidValue = ConvertFrom-BerOid $responseBytes $responseOid
    if ($responseOidValue -cne $oid) { throw 'SNMP response OID does not match the request.' }
    $valueTlv = Read-BerTlv $responseBytes ([ref]$valueOffset)
    switch ($valueTlv.Tag) {
        0x02 {
            $responseValueType = 'Integer'
            $responseValue = ConvertFrom-BerInteger $responseBytes $valueTlv
        }
        0x04 {
            $responseValueType = 'OctetString'
            $responseValue = [System.Text.Encoding]::ASCII.GetString($responseBytes, $valueTlv.ContentOffset, $valueTlv.Length)
        }
        0x05 {
            $responseValueType = 'Null'
            $responseValue = $null
        }
        default {
            throw ('OID returned unsupported BER tag 0x{0:X2}.' -f $valueTlv.Tag)
        }
    }
    if ($oid -ceq '1.3.6.1.2.1.43.6.1.1.3.1.1' -and $responseValueType -ceq 'Integer') {
        $semanticValue = switch ([int]$responseValue) {
            1 { 'OTHER' }
            3 { 'COVER_OPEN' }
            4 { 'COVER_CLOSED' }
            5 { 'INTERLOCK_OPEN' }
            6 { 'INTERLOCK_CLOSED' }
            default { 'UNKNOWN' }
        }
    }
    elseif ($oid -ceq '1.3.6.1.2.1.43.8.2.1.10.1.1' -and $responseValueType -ceq 'Integer') {
        $semanticValue = switch ([int]$responseValue) {
            -3 { 'AT_LEAST_ONE_UNIT_REMAINS' }
            -2 { 'UNKNOWN' }
            -1 { 'OTHER' }
            0 { 'EMPTY' }
            default { 'QUANTITY_REPORTED' }
        }
    }
    elseif ($oid -ceq '1.3.6.1.2.1.43.8.2.1.11.1.1' -and $responseValueType -ceq 'Integer') {
        $statusValue = [int]$responseValue
        $availability = switch ($statusValue -band 0x07) {
            0 { 'AVAILABLE_IDLE' }
            1 { 'UNAVAILABLE_ON_REQUEST' }
            2 { 'AVAILABLE_STANDBY' }
            3 { 'UNAVAILABLE_BROKEN' }
            4 { 'AVAILABLE_ACTIVE' }
            5 { 'UNKNOWN' }
            6 { 'AVAILABLE_BUSY' }
            default { 'RESERVED' }
        }
        $semanticValue = '{0};NON_CRITICAL={1};CRITICAL={2};OFFLINE={3};TRANSITIONING={4}' -f `
            $availability,
            (($statusValue -band 0x08) -ne 0),
            (($statusValue -band 0x10) -ne 0),
            (($statusValue -band 0x20) -ne 0),
            (($statusValue -band 0x40) -ne 0)
    }
    $status = 'RESPONSE_RECEIVED'
}
catch {
    $failure = $_.Exception.GetBaseException().Message
    if (-not $sendStarted) {
        $status = 'FAILED'
    }
}
finally {
    $finishedAtUtc = [DateTime]::UtcNow
    $udp.Dispose()
}

$outputRoot = Join-Path $hardwareRoot 'Output'
New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
$evidence = [ordered]@{
    schemaVersion = '1.0'
    testRunId = $testRunId
    testType = 'SnmpReadOnlyProbe'
    profileId = [string]$printerProfile.profileId
    printerIp = $parsedIp.ToString()
    printerPort = 161
    snmpVersion = 'v1'
    operation = 'GET'
    oid = $oid
    valueType = $responseValueType
    value = $responseValue
    semanticValue = $semanticValue
    responseBytes = if ($null -eq $responseBytes) { 0 } else { $responseBytes.Length }
    attemptCount = $attemptCount
    automaticRetryPerformed = $false
    sendStarted = $sendStarted
    queryStatus = $status
    readOnly = $true
    printPortContacted = $false
    printDataIncluded = $false
    startedAtUtc = $startedAtUtc.ToString('O', [System.Globalization.CultureInfo]::InvariantCulture)
    finishedAtUtc = $finishedAtUtc.ToString('O', [System.Globalization.CultureInfo]::InvariantCulture)
    failure = $failure
}
$evidencePath = Join-Path $outputRoot ($testRunId + '.evidence.json')
$temporaryEvidencePath = $evidencePath + '.tmp'
[System.IO.File]::WriteAllText(
    $temporaryEvidencePath,
    (($evidence | ConvertTo-Json -Depth 5) + [Environment]::NewLine),
    [System.Text.UTF8Encoding]::new($false)
)
Move-Item -LiteralPath $temporaryEvidencePath -Destination $evidencePath

[pscustomobject]@{
    TestRunId = $testRunId
    TestType = 'SnmpReadOnlyProbe'
    QueryStatus = $status
    Oid = $oid
    ValueType = $responseValueType
    Value = $responseValue
    SemanticValue = $semanticValue
    ResponseBytes = if ($null -eq $responseBytes) { 0 } else { $responseBytes.Length }
    AttemptCount = $attemptCount
    AutomaticRetryPerformed = $false
    ReadOnly = $true
    PrintPortContacted = $false
    EvidencePath = $evidencePath
    Failure = $failure
}
