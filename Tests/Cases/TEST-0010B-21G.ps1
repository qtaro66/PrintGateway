[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$drawerTestPath = Join-Path $repositoryRoot 'Tests\Hardware\Test-PrinterDrawerPulse.ps1'
$source = Get-Content -LiteralPath $drawerTestPath -Raw

$blocked = $false
try {
    & $drawerTestPath `
        -ProfilePath (Join-Path $repositoryRoot 'Tests\Hardware\Profiles\epson-tm-t82x-m352a-v1.test.json') `
        -PrinterIp '192.168.2.3' | Out-Null
}
catch {
    $blocked = $_.Exception.Message -cmatch 'Physical drawer pulse was not confirmed'
}
if (-not $blocked) {
    throw 'Unconfirmed drawer pulse was not blocked before network access.'
}

foreach ($requiredSource in @(
    '[ValidateSet(2,5)]',
    '[int]$DrawerPin = 2',
    '[int]$OnTimeUnits = 25',
    '[int]$OffTimeUnits = 250',
    '[byte[]]$pulseCommand = 0x1B,0x70',
    '$attemptCount = 1',
    '$status = ''UNKNOWN''',
    '$status = ''SENT''',
    'automaticRetryPerformed = $false',
    'drawerOpenedConfirmed = $false',
    'printDataIncluded = $false',
    'cutCommandIncluded = $false'
)) {
    if ($source -cnotmatch [regex]::Escape($requiredSource)) {
        throw "Required drawer-test safeguard is missing: $requiredSource"
    }
}

foreach ($forbidden in @('Start-Sleep', 'while (', 'for (')) {
    if ($source -cmatch [regex]::Escape($forbidden)) {
        throw "Drawer sender contains a retry-capable control structure: $forbidden"
    }
}

Write-Host 'TEST-0010B-21G: PASS'
Write-Host 'Verified: explicit drawer confirmation, pin 2 default, bounded pulse, single attempt, no print/cut, and no automatic retry.'
