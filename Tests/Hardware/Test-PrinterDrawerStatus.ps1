[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ProfilePath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$PrinterIp,

    [ValidateRange(100,10000)]
    [int]$ResponseTimeoutMs = 2000,

    [switch]$ConfirmStatusQuery
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $ConfirmStatusQuery) {
    throw 'Physical printer status query was not confirmed. Re-run with -ConfirmStatusQuery.'
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

$printerPort = [int]$printerProfile.transport.defaultPort
$connectTimeoutMs = [int]$printerProfile.transport.connectTimeoutMs
$writeTimeoutMs = [int]$printerProfile.transport.writeTimeoutMs
[byte[]]$queryCommand = 0x1D,0x72,0x02
$testRunId = 'HWDRAWERSTATUS-{0}-{1}' -f (
    [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ', [System.Globalization.CultureInfo]::InvariantCulture)
), ([guid]::NewGuid().ToString('N').Substring(0,8))
$startedAtUtc = [DateTime]::UtcNow
$finishedAtUtc = $null
$attemptCount = 1
$sendStarted = $false
$responseByte = $null
$pin3Level = $null
$status = 'FAILED'
$failure = $null
$client = [System.Net.Sockets.TcpClient]::new()
$stream = $null

try {
    $connectTask = $client.ConnectAsync($parsedIp, $printerPort)
    if (-not $connectTask.Wait($connectTimeoutMs)) {
        throw "TCP connect timed out after $connectTimeoutMs ms."
    }
    if (-not $client.Connected) {
        throw 'TCP connect completed without establishing a connection.'
    }

    $stream = $client.GetStream()
    $stream.WriteTimeout = $writeTimeoutMs
    $stream.ReadTimeout = $ResponseTimeoutMs
    $sendStarted = $true
    $status = 'UNKNOWN'
    $stream.Write($queryCommand, 0, $queryCommand.Length)
    $stream.Flush()

    $readValue = $stream.ReadByte()
    if ($readValue -lt 0) {
        throw 'Printer closed the connection without returning drawer status.'
    }

    $responseByte = [byte]$readValue
    $pin3Level = if (($responseByte -band 0x01) -eq 0) { 'LOW' } else { 'HIGH' }
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
    if ($null -ne $stream) {
        $stream.Dispose()
    }
    $client.Dispose()
}

$outputRoot = Join-Path $hardwareRoot 'Output'
New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
$responseHex = if ($null -eq $responseByte) { $null } else { '0x{0:X2}' -f $responseByte }
$evidence = [ordered]@{
    schemaVersion = '1.0'
    testRunId = $testRunId
    testType = 'DrawerStatusQueryOnly'
    profileId = [string]$printerProfile.profileId
    printerIp = $parsedIp.ToString()
    printerPort = $printerPort
    queryCommandHex = '1D7202'
    responseByteHex = $responseHex
    pin3Level = $pin3Level
    physicalDrawerState = 'UNMAPPED'
    attemptCount = $attemptCount
    automaticRetryPerformed = $false
    sendStarted = $sendStarted
    queryStatus = $status
    drawerPulseIncluded = $false
    printDataIncluded = $false
    cutCommandIncluded = $false
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
    TestType = 'DrawerStatusQueryOnly'
    QueryStatus = $status
    ResponseByteHex = $responseHex
    Pin3Level = $pin3Level
    PhysicalDrawerState = 'UNMAPPED'
    AttemptCount = $attemptCount
    AutomaticRetryPerformed = $false
    DrawerPulseIncluded = $false
    PrintDataIncluded = $false
    CutCommandIncluded = $false
    EvidencePath = $evidencePath
    Failure = $failure
}
