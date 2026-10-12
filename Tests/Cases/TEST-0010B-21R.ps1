[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$license = Get-Content -LiteralPath (Join-Path $repositoryRoot 'LICENSE') -Raw
$readme = Get-Content -LiteralPath (Join-Path $repositoryRoot 'README.md') -Raw
$handoff = Get-Content -LiteralPath (Join-Path $repositoryRoot 'Docs\GIT_REPOSITORY_HANDOFF.md') -Raw
$fontLicense = Join-Path $repositoryRoot 'Assets\Fonts\NotoSansThaiLooped\2.000\OFL.txt'

if (-not $license.Contains('Mozilla Public License Version 2.0', [System.StringComparison]::Ordinal) -or
    -not $license.Contains('https://mozilla.org/MPL/2.0/', [System.StringComparison]::Ordinal)) {
    throw 'Root LICENSE does not contain the MPL 2.0 notice and official license location.'
}
if (-not $readme.Contains('Mozilla Public License 2.0', [System.StringComparison]::Ordinal) -or
    -not $handoff.Contains('Mozilla Public License 2.0', [System.StringComparison]::Ordinal)) {
    throw 'Repository documentation does not consistently identify MPL 2.0.'
}
if ($readme.Contains('No open-source license has been assigned', [System.StringComparison]::Ordinal) -or
    $handoff.Contains('no license has been chosen', [System.StringComparison]::Ordinal)) {
    throw 'Obsolete no-license guidance remains in repository documentation.'
}
if (-not (Test-Path -LiteralPath $fontLicense -PathType Leaf)) {
    throw 'Vendored font license is missing.'
}

Write-Host 'TEST-0010B-21R: PASS'
Write-Host 'Verified: MPL 2.0 project notice and separate SIL OFL font notice are present and documentation is consistent.'
