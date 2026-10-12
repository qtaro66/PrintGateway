[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$alertTestPath = Join-Path $repositoryRoot 'Tests\Hardware\Test-PrinterSnmpAlertTable.ps1'
$source = Get-Content -LiteralPath $alertTestPath -Raw

$blocked = $false
try {
    & $alertTestPath `
        -ProfilePath (Join-Path $repositoryRoot 'Tests\Hardware\Profiles\epson-tm-t82x-m352a-v1.test.json') `
        -PrinterIp '192.168.2.3' | Out-Null
}
catch {
    $blocked = $_.Exception.Message -cmatch 'Physical printer SNMP alert-table walk was not confirmed'
}
if (-not $blocked) { throw 'Unconfirmed SNMP alert walk was not blocked before network access.' }

foreach ($requiredSource in @(
    '[ValidateRange(1,64)]',
    '[int]$MaxRows = 64',
    '$subtreeOid = ''1.3.6.1.2.1.43.18.1.1''',
    '$pdu = ConvertTo-BerTlv 0xA1',
    '$udp.Connect($parsedIp, 161)',
    'SNMP response community does not match the request.',
    '$response.Oid.StartsWith($subtreeOid + ''.'', [System.StringComparison]::Ordinal)',
    'automaticRetryPerformed = $false',
    'readOnly = $true',
    'printPortContacted = $false'
)) {
    if ($source -cnotmatch [regex]::Escape($requiredSource)) { throw "Required SNMP alert-walk safeguard is missing: $requiredSource" }
}
foreach ($forbidden in @('0xA3', 'SetRequest', 'Start-Sleep')) {
    if ($source -cmatch [regex]::Escape($forbidden)) { throw "SNMP alert walk contains a write or retry indicator: $forbidden" }
}

Write-Host 'TEST-0010B-21N: PASS'
Write-Host 'Verified: explicit opt-in, bounded Printer MIB alert subtree, GETNEXT only, no SET/retry, and no print-port contact.'
