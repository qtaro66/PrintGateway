[CmdletBinding()]
param(
    [string]$FixturePath = (Join-Path $PSScriptRoot 'Fixtures\thai-raster-commissioning-v1.json'),
    [string]$FontRoot = (Join-Path $PSScriptRoot '..\..\Assets\Fonts\NotoSansThaiLooped\2.000'),
    [string]$OutputPath = (Join-Path $PSScriptRoot 'Output\thai-raster-commissioning-v1.png'),
    [Parameter(Mandatory)]
    [ValidateRange(1,254)]
    [int]$Threshold,
    [switch]$NoRestore
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$toolProject = Join-Path $PSScriptRoot 'Tools\RasterPreview\RasterPreview.csproj'
foreach ($requiredPath in @($FixturePath, $FontRoot, $toolProject)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
        throw "Required path not found: $requiredPath"
    }
}

$arguments = @('run', '--project', $toolProject, '--configuration', 'Release')
if ($NoRestore) {
    $arguments += '--no-restore'
}
$arguments += @(
    '--',
    '--fixture', $FixturePath,
    '--font-root', $FontRoot,
    '--output', $OutputPath,
    '--threshold', $Threshold.ToString([System.Globalization.CultureInfo]::InvariantCulture)
)

& dotnet @arguments
if ($LASTEXITCODE -ne 0) {
    throw "Offline raster preview failed with exit code $LASTEXITCODE."
}

$validatorPath = Join-Path $PSScriptRoot 'Cases\Test-OfflineRasterArtifacts.ps1'
& $validatorPath -PreviewPath $OutputPath
