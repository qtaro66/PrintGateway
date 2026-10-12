[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ProfilePath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$PrinterIp,

    [int]$PrinterPort = 0,

    [switch]$PlanOnly,

    [switch]$ConfirmHardwarePrint,

    [switch]$ConfirmDrawerPulse
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $PlanOnly) {
    throw 'Hardware execution is not implemented. Re-run with -PlanOnly.'
}

if ($ConfirmHardwarePrint -or $ConfirmDrawerPulse) {
    throw 'Confirmation switches are blocked in PlanOnly mode.'
}

$resolvedProfilePath = (Resolve-Path -LiteralPath $ProfilePath -ErrorAction Stop).Path

if ([System.IO.Path]::GetExtension($resolvedProfilePath) -ne '.json') {
    throw 'ProfilePath must reference a JSON file.'
}

$profilesRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot 'Profiles')).Path
$profilesRootPrefix = $profilesRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar

if (-not $resolvedProfilePath.StartsWith($profilesRootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "ProfilePath must be inside the hardware Profiles directory: $profilesRoot"
}

$schemaPath = Join-Path $PSScriptRoot 'Schemas\printer-test-profile-v1.schema.json'

if (-not (Test-Path -LiteralPath $schemaPath -PathType Leaf)) {
    throw "Profile schema was not found: $schemaPath"
}

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
    throw 'Only IPv4 printer addresses are supported in the Phase 0 commissioning plan.'
}

$ipBytes = $parsedIp.GetAddressBytes()
$isPrivateIpv4 =
    ($ipBytes[0] -eq 10) -or
    ($ipBytes[0] -eq 172 -and $ipBytes[1] -ge 16 -and $ipBytes[1] -le 31) -or
    ($ipBytes[0] -eq 192 -and $ipBytes[1] -eq 168)

if (-not $isPrivateIpv4) {
    throw 'PrinterIp must be an RFC1918 private IPv4 address.'
}

if ($PrinterPort -lt 0 -or $PrinterPort -gt 65535) {
    throw 'PrinterPort must be 0 (use the profile default) or a value from 1 through 65535.'
}

if ($PrinterPort -eq 0) {
    $PrinterPort = [int]$printerProfile.transport.defaultPort
}

if ($printerProfile.certification.containsRealDeviceIdentifiers -ne $false) {
    throw 'Public test profiles must not contain real device identifiers.'
}

if ($printerProfile.statusPolicy.automaticCompletedAllowed -ne $false) {
    throw 'This commissioning workflow requires automaticCompletedAllowed=false until job-specific evidence is certified.'
}

$testRunId = 'COMM-{0}-{1}' -f (
    [DateTime]::UtcNow.ToString(
        'yyyyMMddTHHmmssZ',
        [System.Globalization.CultureInfo]::InvariantCulture
    ),
    [Guid]::NewGuid().ToString('N').Substring(0, 8)
)

$steps = @(
    'ValidateProfile',
    'InspectSelfTest',
    'VerifyNetworkConfiguration',
    'TestConnectivity',
    'TestPrinterStatus',
    'TestRasterRendering',
    'TestPaperCut',
    'TestOfflineAndRestartRecovery',
    'RunReliabilitySequence',
    'TestCashDrawerSeparatelyIfApplicable',
    'ReviewAndApproveCommissioningReport'
)

[PSCustomObject]@{
    TestRunId              = $testRunId
    Mode                   = 'PlanOnly'
    ProfileId              = $printerProfile.profileId
    CertificationStatus    = $printerProfile.certification.status
    PrinterIp              = $parsedIp.ToString()
    PrinterPort            = $PrinterPort
    NoNetworkAccess        = $true
    NoDatabaseAccess       = $true
    NoPrinterBytesSent     = $true
    AutomaticCompleted     = $false
    AutomaticRetryAfterSend = $false
    PlannedSteps           = $steps
}
