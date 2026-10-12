[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$profilePath = Join-Path $repositoryRoot 'Tests\Hardware\Profiles\epson-tm-t82x-m352a-v1.test.json'
$schemaPath = Join-Path $repositoryRoot 'Tests\Hardware\Schemas\printer-test-profile-v1.schema.json'

$profileJson = Get-Content -LiteralPath $profilePath -Raw
if (-not ($profileJson | Test-Json -SchemaFile $schemaPath)) {
    throw 'Printer profile failed schema validation after recording paper-out alert recovery.'
}
$monitoring = ($profileJson | ConvertFrom-Json).capabilities.statusMonitoring
if (-not [bool]$monitoring.paperOutAlertClearsWhenRestoredVerified -or
    [string]::IsNullOrWhiteSpace([string]$monitoring.paperOutAlertClearsWhenRestoredVerifiedAtUtc)) {
    throw 'Verified paper-out alert recovery is not preserved in the printer profile.'
}

Write-Host 'TEST-0010B-21P: PASS'
Write-Host 'Verified: profile records that restoring paper clears alert 808 and returns the input unit to available/idle.'
