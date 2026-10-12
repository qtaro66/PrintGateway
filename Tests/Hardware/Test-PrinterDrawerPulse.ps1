[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ProfilePath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$PrinterIp,

    [ValidateSet(2,5)]
    [int]$DrawerPin = 2,

    [ValidateRange(1,255)]
    [int]$OnTimeUnits = 25,

    [ValidateRange(1,255)]
    [int]$OffTimeUnits = 250,

    [switch]$ConfirmDrawerPulse
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $ConfirmDrawerPulse) {
    throw 'Physical drawer pulse was not confirmed. Re-run with -ConfirmDrawerPulse.'
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
if ([string]$printerProfile.capabilities.drawerConnector -cne 'RJ12' -or [int]$printerProfile.capabilities.drawerVoltage -ne 24) {
    throw 'Printer profile must explicitly declare an RJ12 24 V drawer interface.'
}

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
$outputSignal = if ($DrawerPin -eq 2) { 0 } else { 1 }
[byte[]]$pulseCommand = 0x1B,0x70,[byte]$outputSignal,[byte]$OnTimeUnits,[byte]$OffTimeUnits
$pulseHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($pulseCommand))
$testRunId = 'HWDRAWER-{0}-{1}' -f (
    [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ', [System.Globalization.CultureInfo]::InvariantCulture)
), ([guid]::NewGuid().ToString('N').Substring(0,8))
$startedAtUtc = [DateTime]::UtcNow
$finishedAtUtc = $null
$attemptCount = 1
$sendStarted = $false
$bytesAcceptedByStream = 0
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
    $sendStarted = $true
    $status = 'UNKNOWN'
    $stream.Write($pulseCommand, 0, $pulseCommand.Length)
    $stream.Flush()
    $bytesAcceptedByStream = $pulseCommand.Length
    $status = 'SENT'
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
$evidence = [ordered]@{
    schemaVersion = '1.0'
    testRunId = $testRunId
    testType = 'DrawerPulseOnly'
    profileId = [string]$printerProfile.profileId
    printerIp = $parsedIp.ToString()
    printerPort = $printerPort
    commandSha256 = $pulseHash
    commandBytes = $pulseCommand.Length
    drawerPin = $DrawerPin
    onTimeUnits = $OnTimeUnits
    onTimeMs = $OnTimeUnits * 2
    offTimeUnits = $OffTimeUnits
    offTimeMs = $OffTimeUnits * 2
    attemptCount = $attemptCount
    automaticRetryPerformed = $false
    sendStarted = $sendStarted
    bytesAcceptedByStream = $bytesAcceptedByStream
    transportStatus = $status
    drawerOpenedConfirmed = $false
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
    TestType = 'DrawerPulseOnly'
    TransportStatus = $status
    DrawerOpenedConfirmed = $false
    PrinterIp = $parsedIp.ToString()
    PrinterPort = $printerPort
    DrawerPin = $DrawerPin
    OnTimeMs = $OnTimeUnits * 2
    OffTimeMs = $OffTimeUnits * 2
    CommandBytes = $pulseCommand.Length
    BytesAcceptedByStream = $bytesAcceptedByStream
    AttemptCount = $attemptCount
    AutomaticRetryPerformed = $false
    PrintDataIncluded = $false
    CutCommandIncluded = $false
    EvidencePath = $evidencePath
    Failure = $failure
}
