[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$reportPath = Join-Path $repositoryRoot 'Tests\Hardware\Reports\epson-tm-t82x-m352a-v1-commissioning.md'
$report = Get-Content -LiteralPath $reportPath -Raw

foreach ($requiredStatement in @(
    'Overall status: **PROVISIONAL**',
    'A successful socket write means `SENT`; it does not mean `COMPLETED`.',
    'automatic completion is disabled',
    'recorded as `UNKNOWN` and must not be retried automatically',
    'Cutter-error status and alert mapping | Unverified',
    'Windows production service path | Unverified',
    'Linux production service path | Unverified',
    'Job-specific print completion | Unsupported by current evidence'
)) {
    if (-not $report.Contains($requiredStatement, [System.StringComparison]::Ordinal)) {
        throw "Required evidence boundary is missing from commissioning report: $requiredStatement"
    }
}

foreach ($sensitivePattern in @(
    '(?<!\d)(?:10|172|192)\.\d{1,3}\.\d{1,3}\.\d{1,3}(?!\d)',
    '(?i)serial\s*(?:number|no\.?)[\s:]+[A-Z0-9-]{5,}',
    '(?i)(?:[0-9A-F]{2}[:-]){5}[0-9A-F]{2}',
    '(?i)community\s*=\s*[^\s]+'
)) {
    if ($report -match $sensitivePattern) {
        throw "Commissioning report contains a potentially sensitive identifier: $sensitivePattern"
    }
}

Write-Host 'TEST-0010B-21Q: PASS'
Write-Host 'Verified: public report preserves evidence boundaries, UNKNOWN/no-retry safety, provisional status, and identifier sanitization.'
