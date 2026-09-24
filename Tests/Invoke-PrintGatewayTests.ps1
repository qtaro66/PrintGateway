[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$suitePath = Join-Path $PSScriptRoot 'PrintGateway.Tests.ps1'

if (-not (Test-Path -LiteralPath $suitePath -PathType Leaf)) {
    throw "Safe test suite not found: $suitePath"
}

& $suitePath

