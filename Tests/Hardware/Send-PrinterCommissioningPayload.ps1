[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ProfilePath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$PreviewPath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$PrinterIp,

    [switch]$ConfirmHardwarePrint
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $ConfirmHardwarePrint) {
    throw 'Physical printer output was not confirmed. Re-run with -ConfirmHardwarePrint.'
}

$hardwareRoot = (Resolve-Path -LiteralPath $PSScriptRoot).Path
$profilesRoot = (Resolve-Path -LiteralPath (Join-Path $hardwareRoot 'Profiles')).Path
$profilesRootPrefix = $profilesRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
$resolvedProfilePath = (Resolve-Path -LiteralPath $ProfilePath -ErrorAction Stop).Path
if (-not $resolvedProfilePath.StartsWith($profilesRootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "ProfilePath must be inside the hardware Profiles directory: $profilesRoot"
}

$profileSchemaPath = Join-Path $hardwareRoot 'Schemas\printer-test-profile-v1.schema.json'
$profileJson = Get-Content -LiteralPath $resolvedProfilePath -Raw
if (-not ($profileJson | Test-Json -SchemaFile $profileSchemaPath)) {
    throw 'Printer test profile does not satisfy the profile schema.'
}
$printerProfile = $profileJson | ConvertFrom-Json

$resolvedPreviewPath = (Resolve-Path -LiteralPath $PreviewPath -ErrorAction Stop).Path
$outputRoot = (Resolve-Path -LiteralPath (Join-Path $hardwareRoot 'Output')).Path
$outputRootPrefix = $outputRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
if (-not $resolvedPreviewPath.StartsWith($outputRootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "PreviewPath must be inside the hardware Output directory: $outputRoot"
}

$validatorPath = Join-Path $hardwareRoot 'Cases\Test-OfflineRasterArtifacts.ps1'
$validation = & $validatorPath -PreviewPath $resolvedPreviewPath
if (-not $validation.Valid) {
    throw 'Offline payload validation did not return Valid = true.'
}

$baseName = [System.IO.Path]::GetFileNameWithoutExtension($resolvedPreviewPath)
$payloadPath = Join-Path $outputRoot ($baseName + '.escpos.bin')
$payload = [System.IO.File]::ReadAllBytes($payloadPath)
$payloadHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $payloadPath).Hash
if ($payloadHash -cne [string]$validation.PayloadSha256) {
    throw 'Payload changed after offline artifact validation.'
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
$testRunId = 'HWPRINT-{0}-{1}' -f (
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

    # Once Write begins, any error is delivery-uncertain and must remain UNKNOWN.
    $sendStarted = $true
    $status = 'UNKNOWN'
    $stream.Write($payload, 0, $payload.Length)
    $stream.Flush()
    $bytesAcceptedByStream = $payload.Length
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

$evidence = [ordered]@{
    schemaVersion = '1.0'
    testRunId = $testRunId
    profileId = [string]$printerProfile.profileId
    printerIp = $parsedIp.ToString()
    printerPort = $printerPort
    payloadSha256 = $payloadHash
    payloadBytes = $payload.Length
    attemptCount = $attemptCount
    automaticRetryPerformed = $false
    sendStarted = $sendStarted
    bytesAcceptedByStream = $bytesAcceptedByStream
    transportStatus = $status
    completionConfirmed = $false
    completionEvidence = 'none'
    drawerPulseIncluded = $false
    processIdIncluded = $false
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
    TransportStatus = $status
    CompletionConfirmed = $false
    PrinterIp = $parsedIp.ToString()
    PrinterPort = $printerPort
    PayloadBytes = $payload.Length
    BytesAcceptedByStream = $bytesAcceptedByStream
    AttemptCount = $attemptCount
    AutomaticRetryPerformed = $false
    DrawerPulseIncluded = $false
    EvidencePath = $evidencePath
    Failure = $failure
}
