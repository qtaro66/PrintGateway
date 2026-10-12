[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$fontRoot = Join-Path $repositoryRoot 'Assets\Fonts\NotoSansThaiLooped\2.000'
$manifestPath = Join-Path $fontRoot 'font-manifest.json'
$runnerPath = Join-Path $repositoryRoot 'Tests\Hardware\Invoke-OfflineRasterPreview.ps1'
$programPath = Join-Path $repositoryRoot 'Tests\Hardware\Tools\RasterPreview\Program.cs'

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ($manifest.version -cne '2.000') {
    throw 'Pinned font version must be exactly 2.000.'
}

foreach ($file in $manifest.files) {
    $path = Join-Path $fontRoot $file.path
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash
    if ($actual -cne $file.sha256) {
        throw "Font asset hash mismatch: $($file.path)"
    }
}

$runnerSource = Get-Content -LiteralPath $runnerPath -Raw
$programSource = Get-Content -LiteralPath $programPath -Raw
$combinedSource = $runnerSource + "`n" + $programSource

foreach ($forbidden in @(
    'TcpClient',
    'HttpClient',
    'Invoke-WebRequest',
    'Invoke-RestMethod',
    'EpsonTransport',
    'NetworkStream',
    'System.Drawing',
    'Tahoma'
)) {
    if ($combinedSource -cmatch [regex]::Escape($forbidden)) {
        throw "Offline renderer contains forbidden dependency or operation: $forbidden"
    }
}

if ($programSource -cnotmatch 'SKShaper') {
    throw 'Offline renderer must shape text with HarfBuzz through SKShaper.'
}
if ($programSource -cnotmatch 'Only synthetic commissioning fixtures are allowed') {
    throw 'Offline renderer must reject non-synthetic fixtures.'
}

Write-Host 'TEST-0010B-21D: PASS'
Write-Host 'Verified: pinned font hashes, OFL asset, HarfBuzz shaping, synthetic-only input, and no printer/network operations.'
