[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$profilePath = Join-Path $repositoryRoot 'Tests\Hardware\Profiles\epson-tm-t82x-m352a-v1.test.json'
$schemaPath = Join-Path $repositoryRoot 'Tests\Hardware\Schemas\printer-test-profile-v1.schema.json'
$snmpTestPath = Join-Path $repositoryRoot 'Tests\Hardware\Test-PrinterSnmpProbe.ps1'

$profileJson = Get-Content -LiteralPath $profilePath -Raw
if (-not ($profileJson | Test-Json -SchemaFile $schemaPath)) {
    throw 'Printer profile failed schema validation after adding SNMP cover monitoring.'
}
$printerProfile = $profileJson | ConvertFrom-Json
$monitoring = $printerProfile.capabilities.statusMonitoring
if ([string]$monitoring.preferredCoverMethod -cne 'SNMP' -or
    [string]$monitoring.snmpVersion -cne 'v1' -or
    [int]$monitoring.snmpPort -ne 161 -or
    [string]$monitoring.coverStatusOid -cne '1.3.6.1.2.1.43.6.1.1.3.1.1' -or
    [int]$monitoring.coverOpenValue -ne 3 -or
    [int]$monitoring.coverClosedValue -ne 4 -or
    -not [bool]$monitoring.coverStatusVerified -or
    [string]$monitoring.dleEotCoverOpenResult -cne 'no-response') {
    throw 'Verified SNMP cover-state mapping or DLE EOT limitation is not preserved in the printer profile.'
}

$source = Get-Content -LiteralPath $snmpTestPath -Raw
foreach ($requiredSource in @(
    '$oid -ceq ''1.3.6.1.2.1.43.6.1.1.3.1.1''',
    '3 { ''COVER_OPEN'' }',
    '4 { ''COVER_CLOSED'' }'
)) {
    if ($source -cnotmatch [regex]::Escape($requiredSource)) {
        throw "Required SNMP cover decoder is missing: $requiredSource"
    }
}

Write-Host 'TEST-0010B-21K: PASS'
Write-Host 'Verified: profile records SNMP cover OID, OPEN=3, CLOSED=4, physical two-state verification, and DLE EOT open-state limitation.'
