[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$PrinterIp,

    [int]$PrinterPort = 9100,

    [string]$DatabasePath = 'C:\PrintGateway\Data\printgateway.db',

    [AllowNull()]
    [string]$SqlitePath = $null,

    [switch]$ConfirmHardwarePrint
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $ConfirmHardwarePrint) {
    throw 'A real print was not confirmed. Re-run with -ConfirmHardwarePrint after checking printer readiness.'
}

if ([string]::IsNullOrWhiteSpace($PrinterIp) -or $PrinterIp -eq '192.0.2.10') {
    throw 'Supply the real printer address with -PrinterIp. The documentation address 192.0.2.10 is blocked.'
}

$scenarioPath = Join-Path $PSScriptRoot 'Cases\Invoke-PrintGatewayIntegrationScenario.ps1'

if (-not (Test-Path -LiteralPath $scenarioPath -PathType Leaf)) {
    throw "Integration scenario not found: $scenarioPath"
}

$scenarioParameters = @{
    DatabasePath            = $DatabasePath
    PrinterIp               = $PrinterIp
    PrinterPort             = $PrinterPort
    TransportMode           = 'Printer'
    AllowPrinterConnection  = $true
}

if (-not [string]::IsNullOrWhiteSpace($SqlitePath)) {
    $scenarioParameters.SqlitePath = $SqlitePath
}

& $scenarioPath @scenarioParameters

