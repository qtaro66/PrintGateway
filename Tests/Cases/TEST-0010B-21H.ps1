[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$statusTestPath = Join-Path $repositoryRoot 'Tests\Hardware\Test-PrinterDrawerStatus.ps1'
$source = Get-Content -LiteralPath $statusTestPath -Raw

$blocked = $false
try {
    & $statusTestPath `
        -ProfilePath (Join-Path $repositoryRoot 'Tests\Hardware\Profiles\epson-tm-t82x-m352a-v1.test.json') `
        -PrinterIp '192.168.2.3' | Out-Null
}
catch {
    $blocked = $_.Exception.Message -cmatch 'Physical printer status query was not confirmed'
}
if (-not $blocked) {
    throw 'Unconfirmed drawer status query was not blocked before network access.'
}

foreach ($requiredSource in @(
    '[byte[]]$queryCommand = 0x1D,0x72,0x02',
    '$attemptCount = 1',
    '$stream.ReadTimeout = $ResponseTimeoutMs',
    '$stream.ReadByte()',
    '$responseByte -band 0x01',
    'physicalDrawerState = ''UNMAPPED''',
    'automaticRetryPerformed = $false',
    'drawerPulseIncluded = $false',
    'printDataIncluded = $false',
    'cutCommandIncluded = $false'
)) {
    if ($source -cnotmatch [regex]::Escape($requiredSource)) {
        throw "Required drawer-status safeguard is missing: $requiredSource"
    }
}

foreach ($forbidden in @('Start-Sleep', 'while (', 'for (')) {
    if ($source -cmatch [regex]::Escape($forbidden)) {
        throw "Drawer status query contains a retry-capable control structure: $forbidden"
    }
}

$profilePath = Join-Path $repositoryRoot 'Tests\Hardware\Profiles\epson-tm-t82x-m352a-v1.test.json'
$printerProfile = Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json
$drawerControl = $printerProfile.capabilities.drawerControl
if (-not [bool]$drawerControl.openCommandVerified -or
    -not [bool]$drawerControl.statusResponseVerified -or
    [int]$drawerControl.drivePin -ne 2 -or
    [int]$drawerControl.onTimeMs -ne 50 -or
    [int]$drawerControl.offTimeMs -ne 500 -or
    [string]$drawerControl.pin3HighState -cne 'CLOSED' -or
    [string]$drawerControl.pin3LowState -cne 'OPEN') {
    throw 'Verified drawer control and pin-3 mapping are not preserved in the printer profile.'
}

Write-Host 'TEST-0010B-21H: PASS'
Write-Host 'Verified: explicit GS r 2 query, bounded read, no print/pulse/cut, and preserved HIGH=CLOSED / LOW=OPEN mapping.'
