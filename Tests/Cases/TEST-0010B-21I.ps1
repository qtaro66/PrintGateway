[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$statusTestPath = Join-Path $repositoryRoot 'Tests\Hardware\Test-PrinterCoverStatus.ps1'
$source = Get-Content -LiteralPath $statusTestPath -Raw

$blocked = $false
try {
    & $statusTestPath `
        -ProfilePath (Join-Path $repositoryRoot 'Tests\Hardware\Profiles\epson-tm-t82x-m352a-v1.test.json') `
        -PrinterIp '192.168.2.3' | Out-Null
}
catch {
    $blocked = $_.Exception.Message -cmatch 'Physical printer cover status query was not confirmed'
}
if (-not $blocked) {
    throw 'Unconfirmed cover status query was not blocked before network access.'
}

foreach ($requiredSource in @(
    '[byte[]]$queryCommand = 0x10,0x04,0x02',
    '$attemptCount = 1',
    '$stream.ReadTimeout = $ResponseTimeoutMs',
    '$stream.ReadByte()',
    '$responseByte -band 0x93',
    '$responseByte -band 0x04',
    '$responseByte -band 0x20',
    '$responseByte -band 0x40',
    'automaticRetryPerformed = $false',
    'drawerPulseIncluded = $false',
    'printDataIncluded = $false',
    'cutCommandIncluded = $false',
    'establishesPrintCompletion = $false'
)) {
    if ($source -cnotmatch [regex]::Escape($requiredSource)) {
        throw "Required cover-status safeguard is missing: $requiredSource"
    }
}

foreach ($forbidden in @('Start-Sleep', 'while (', 'for (')) {
    if ($source -cmatch [regex]::Escape($forbidden)) {
        throw "Cover status query contains a retry-capable control structure: $forbidden"
    }
}

Write-Host 'TEST-0010B-21I: PASS'
Write-Host 'Verified: explicit DLE EOT 2 query, fixed-bit validation, bounded one-byte read, no print/pulse/cut, and no completion claim.'
