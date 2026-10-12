[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$profilePath = Join-Path $repositoryRoot 'Tests\Hardware\Profiles\epson-tm-t82x-m352a-v1.test.json'
$schemaPath = Join-Path $repositoryRoot 'Tests\Hardware\Schemas\printer-test-profile-v1.schema.json'

$profileJson = Get-Content -LiteralPath $profilePath -Raw
if (-not ($profileJson | Test-Json -SchemaFile $schemaPath)) {
    throw 'Printer profile failed schema validation after adding the verified SNMP paper-out alert mapping.'
}
$monitoring = ($profileJson | ConvertFrom-Json).capabilities.statusMonitoring
if ([string]$monitoring.alertTableOid -cne '1.3.6.1.2.1.43.18.1.1' -or
    [int]$monitoring.paperOutAlertCode -ne 808 -or
    [string]$monitoring.paperOutAlertDescription -cne 'Roll Paper End' -or
    [int]$monitoring.paperOutAlertGroup -ne 8 -or
    [int]$monitoring.paperOutAlertSeverity -ne 3 -or
    -not [bool]$monitoring.alertTablePaperOutVerified -or
    [bool]$monitoring.cutterErrorAlertVerified) {
    throw 'Verified SNMP paper-out alert mapping or provisional cutter-error state is not preserved in the printer profile.'
}

Write-Host 'TEST-0010B-21O: PASS'
Write-Host 'Verified: paper-out alert is code 808 / Roll Paper End; cutter-error alert remains explicitly unverified.'
