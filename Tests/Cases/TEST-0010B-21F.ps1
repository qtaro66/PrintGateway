[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$senderPath = Join-Path $repositoryRoot 'Tests\Hardware\Send-PrinterCommissioningPayload.ps1'
$senderSource = Get-Content -LiteralPath $senderPath -Raw

$blocked = $false
try {
    & $senderPath `
        -ProfilePath (Join-Path $repositoryRoot 'Tests\Hardware\Profiles\epson-tm-t82x-m352a-v1.test.json') `
        -PreviewPath (Join-Path $repositoryRoot 'Tests\Hardware\Output\does-not-matter.png') `
        -PrinterIp '192.168.2.3' | Out-Null
}
catch {
    $blocked = $_.Exception.Message -cmatch 'Physical printer output was not confirmed'
}
if (-not $blocked) {
    throw 'Unconfirmed physical print was not blocked before file or network access.'
}

foreach ($requiredSource in @(
    'if (-not $ConfirmHardwarePrint)',
    '$attemptCount = 1',
    '$status = ''UNKNOWN''',
    '$status = ''SENT''',
    'automaticRetryPerformed = $false',
    'completionConfirmed = $false',
    'drawerPulseIncluded = $false',
    'processIdIncluded = $false',
    'Test-OfflineRasterArtifacts.ps1'
)) {
    if ($senderSource -cnotmatch [regex]::Escape($requiredSource)) {
        throw "Required hardware-print safeguard is missing: $requiredSource"
    }
}

foreach ($forbidden in @('Start-Sleep', 'while (', 'for (')) {
    if ($senderSource -cmatch [regex]::Escape($forbidden)) {
        throw "Hardware sender contains a retry-capable control structure: $forbidden"
    }
}

Write-Host 'TEST-0010B-21F: PASS'
Write-Host 'Verified: explicit physical-print confirmation, single attempt, UNKNOWN-on-send-error, no automatic retry, and no false completion.'
