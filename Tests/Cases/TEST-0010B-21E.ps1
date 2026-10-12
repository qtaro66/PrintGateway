[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$runnerPath = Join-Path $repositoryRoot 'Tests\Hardware\Invoke-OfflineRasterPreview.ps1'
$validatorPath = Join-Path $repositoryRoot 'Tests\Hardware\Cases\Test-OfflineRasterArtifacts.ps1'
$programPath = Join-Path $repositoryRoot 'Tests\Hardware\Tools\RasterPreview\Program.cs'
$runnerSource = Get-Content -LiteralPath $runnerPath -Raw
$validatorSource = Get-Content -LiteralPath $validatorPath -Raw
$programSource = Get-Content -LiteralPath $programPath -Raw
$combinedSource = $runnerSource + "`n" + $validatorSource + "`n" + $programSource

foreach ($forbidden in @(
    'TcpClient',
    'UdpClient',
    'HttpClient',
    'Invoke-WebRequest',
    'Invoke-RestMethod',
    'NetworkStream',
    'Socket',
    'EpsonTransport'
)) {
    if ($combinedSource -cmatch [regex]::Escape($forbidden)) {
        throw "Offline payload generator contains forbidden network operation: $forbidden"
    }
}

foreach ($requiredSource in @(
    '[Parameter(Mandatory)]',
    '[ValidateRange(1,254)]',
    'payloadIncludesDrawerPulse = false',
    'payloadIncludesProcessId = false',
    'payloadTransmitted = false',
    'Test-OfflineRasterArtifacts.ps1',
    '0x1D, 0x28, 0x4C',
    '0x30, 0x70',
    '0x30, 0x32',
    '0x1D, 0x56, 0x01'
)) {
    if ($combinedSource -cnotmatch [regex]::Escape($requiredSource)) {
        throw "Required offline payload safeguard or command is missing: $requiredSource"
    }
}

if ($programSource -cnotmatch 'raster\[byteIndex\] \|= \(byte\)\(1 << bit\)') {
    throw 'Expected MSB-first 1-bit raster packing was not found.'
}

Write-Host 'TEST-0010B-21E: PASS'
Write-Host 'Verified: explicit threshold, MSB-first raster, bounded GS ( L payload, no drawer/process ID, and no network operations.'
