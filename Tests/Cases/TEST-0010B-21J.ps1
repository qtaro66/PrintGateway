[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$snmpTestPath = Join-Path $repositoryRoot 'Tests\Hardware\Test-PrinterSnmpProbe.ps1'
$source = Get-Content -LiteralPath $snmpTestPath -Raw

$blocked = $false
try {
    & $snmpTestPath `
        -ProfilePath (Join-Path $repositoryRoot 'Tests\Hardware\Profiles\epson-tm-t82x-m352a-v1.test.json') `
        -PrinterIp '192.168.2.3' | Out-Null
}
catch {
    $blocked = $_.Exception.Message -cmatch 'Physical printer SNMP probe was not confirmed'
}
if (-not $blocked) {
    throw 'Unconfirmed SNMP probe was not blocked before network access.'
}

foreach ($requiredSource in @(
    '[System.Net.Sockets.UdpClient]::new()',
    '$udp.Connect($parsedIp, 161)',
    '$requestPdu = ConvertTo-BerTlv 0xA0',
    '[string]$Oid = ''1.3.6.1.2.1.1.1.0''',
    '[int64]$value = if (($Bytes[$Tlv.ContentOffset] -band 0x80) -ne 0) { -1 } else { 0 }',
    '$attemptCount = 1',
    '$receiveTask.Wait($ResponseTimeoutMs)',
    'SNMP response community does not match the request.',
    'SNMP response OID does not match the request.',
    'automaticRetryPerformed = $false',
    'readOnly = $true',
    'printPortContacted = $false',
    'printDataIncluded = $false'
)) {
    if ($source -cnotmatch [regex]::Escape($requiredSource)) {
        throw "Required SNMP safeguard is missing: $requiredSource"
    }
}

foreach ($forbidden in @('0xA3', 'SetRequest', 'Start-Sleep')) {
    if ($source -cmatch [regex]::Escape($forbidden)) {
        throw "SNMP probe contains a write or retry indicator: $forbidden"
    }
}

Write-Host 'TEST-0010B-21J: PASS'
Write-Host 'Verified: explicit opt-in, SNMPv1 GET only, one bounded attempt, no SET, and no print-port contact.'
