[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ProfilePath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$PrinterIp,

    [switch]$ConfirmNetworkProbe
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $ConfirmNetworkProbe) {
    throw 'TCP connectivity probe was not confirmed. Re-run with -ConfirmNetworkProbe.'
}

$hardwareRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
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
$printerPort = [int]$printerProfile.transport.defaultPort
$connectTimeoutMs = [int]$printerProfile.transport.connectTimeoutMs
$parsedIp = $null

if (-not [System.Net.IPAddress]::TryParse($PrinterIp, [ref]$parsedIp)) {
    throw "PrinterIp is not a valid IP address: $PrinterIp"
}

if ($parsedIp.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
    throw 'Only IPv4 printer addresses are supported in the Phase 0 connectivity test.'
}

$ipBytes = $parsedIp.GetAddressBytes()
$isPrivateIpv4 =
    ($ipBytes[0] -eq 10) -or
    ($ipBytes[0] -eq 172 -and $ipBytes[1] -ge 16 -and $ipBytes[1] -le 31) -or
    ($ipBytes[0] -eq 192 -and $ipBytes[1] -eq 168)

if (-not $isPrivateIpv4) {
    throw 'PrinterIp must be an RFC1918 private IPv4 address.'
}

$client = [System.Net.Sockets.TcpClient]::new()
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$reachable = $false
$failure = $null

try {
    $connectTask = $client.ConnectAsync($parsedIp, $printerPort)

    if (-not $connectTask.Wait($connectTimeoutMs)) {
        $failure = "TCP connect timed out after $connectTimeoutMs ms."
    }
    elseif ($client.Connected) {
        $reachable = $true
    }
    else {
        $failure = 'TCP connect completed without establishing a connection.'
    }
}
catch {
    $failure = $_.Exception.GetBaseException().Message
}
finally {
    $stopwatch.Stop()
    $client.Dispose()
}

[PSCustomObject]@{
    TestName      = 'PrinterConnectivity'
    ProfileId     = $printerProfile.profileId
    ProbeType     = 'TcpConnectOnly'
    PrinterIp     = $parsedIp.ToString()
    PrinterPort   = $printerPort
    Reachable     = $reachable
    ElapsedMs     = $stopwatch.ElapsedMilliseconds
    BytesSent     = 0
    BytesReceived = 0
    Failure       = $failure
}
