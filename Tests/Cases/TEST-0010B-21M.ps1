[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$profilePath = Join-Path $repositoryRoot 'Tests\Hardware\Profiles\epson-tm-t82x-m352a-v1.test.json'
$schemaPath = Join-Path $repositoryRoot 'Tests\Hardware\Schemas\printer-test-profile-v1.schema.json'

$profileJson = Get-Content -LiteralPath $profilePath -Raw
if (-not ($profileJson | Test-Json -SchemaFile $schemaPath)) {
    throw 'Printer profile failed schema validation after adding SNMP paper monitoring.'
}
$monitoring = ($profileJson | ConvertFrom-Json).capabilities.statusMonitoring
if ([string]$monitoring.paperCurrentLevelOid -cne '1.3.6.1.2.1.43.8.2.1.10.1.1' -or
    [string]$monitoring.paperStatusOid -cne '1.3.6.1.2.1.43.8.2.1.11.1.1' -or
    [int]$monitoring.paperOutCurrentLevelValue -ne 0 -or
    [int]$monitoring.paperPresentCurrentLevelValue -ne -3 -or
    [int]$monitoring.paperOutStatusValue -ne 19 -or
    [int]$monitoring.paperPresentStatusValue -ne 0 -or
    -not [bool]$monitoring.paperStatusVerified) {
    throw 'Verified SNMP paper-state mapping is not preserved in the printer profile.'
}

Write-Host 'TEST-0010B-21M: PASS'
Write-Host 'Verified: profile records physical two-state SNMP paper mapping (OUT=level 0/status 19; PRESENT=level -3/status 0).'
