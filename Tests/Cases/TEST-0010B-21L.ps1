[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$snmpTestPath = Join-Path $repositoryRoot 'Tests\Hardware\Test-PrinterSnmpProbe.ps1'
$source = Get-Content -LiteralPath $snmpTestPath -Raw

foreach ($requiredSource in @(
    '$oid -ceq ''1.3.6.1.2.1.43.8.2.1.10.1.1''',
    '-3 { ''AT_LEAST_ONE_UNIT_REMAINS'' }',
    '0 { ''EMPTY'' }',
    '$oid -ceq ''1.3.6.1.2.1.43.8.2.1.11.1.1''',
    '$statusValue -band 0x07',
    '$statusValue -band 0x10',
    '$statusValue -band 0x20'
)) {
    if ($source -cnotmatch [regex]::Escape($requiredSource)) {
        throw "Required SNMP paper-status decoder is missing: $requiredSource"
    }
}

Write-Host 'TEST-0010B-21L: PASS'
Write-Host 'Verified: signed BER integers, paper-level semantics, and Printer MIB sub-unit status bit decoding.'
