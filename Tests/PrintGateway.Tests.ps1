[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$caseDirectory = Join-Path $PSScriptRoot 'Cases'
$testCases = @(
    'TEST-0010B-18BO.ps1',
    'TEST-0010B-19A.ps1',
    'TEST-0010B-19B.ps1',
    'TEST-0010B-19C.ps1',
    'TEST-0010B-19D.ps1',
    'TEST-0010B-19E.ps1',
    'TEST-0010B-19E-HARDENING.ps1',
    'TEST-0010B-20A.ps1'
)

$results = [System.Collections.Generic.List[object]]::new()

foreach ($testCase in $testCases) {
    $testPath = Join-Path $caseDirectory $testCase

    if (-not (Test-Path -LiteralPath $testPath -PathType Leaf)) {
        throw "Test case not found: $testPath"
    }

    Write-Host "[RUN] $testCase"
    $output = @(& (Join-Path $PSHOME 'pwsh.exe') `
        -NoLogo `
        -NoProfile `
        -NonInteractive `
        -File $testPath 2>&1)
    $exitCode = $LASTEXITCODE

    foreach ($line in $output) {
        Write-Host "$line"
    }

    $results.Add([PSCustomObject]@{
        Test     = $testCase
        Passed   = ($exitCode -eq 0)
        ExitCode = $exitCode
    })

    if ($exitCode -ne 0) {
        throw "Safe regression test failed: $testCase (exit code $exitCode)"
    }
}

Write-Host ''
Write-Host 'PrintGateway safe regression summary'
$results | Format-Table -AutoSize
Write-Host "PASS: $($results.Count)/$($testCases.Count)"

return @($results)

