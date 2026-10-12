Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$connectivityPath = Join-Path $repositoryRoot 'Tests\Hardware\Cases\Test-PrinterConnectivity.ps1'
$profilePath = Join-Path $repositoryRoot 'Tests\Hardware\Profiles\epson-tm-t82x-m352a-v1.test.json'

function Assert-Equal {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        $Expected,

        $Actual
    )

    if ($Expected -ne $Actual) {
        throw "Assertion failed for ${Name}: expected '$Expected', actual '$Actual'."
    }
}

foreach ($requiredPath in @($connectivityPath, $profilePath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Required file not found: $requiredPath"
    }
}

$unconfirmedWasBlocked = $false

try {
    & $connectivityPath `
        -ProfilePath $profilePath `
        -PrinterIp '10.255.255.254' | Out-Null
}
catch {
    $unconfirmedWasBlocked = $_.Exception.Message -like '*Re-run with -ConfirmNetworkProbe*'
}

Assert-Equal -Name 'unconfirmed network probe blocked' -Expected $true -Actual $unconfirmedWasBlocked

$connectivitySource = Get-Content -LiteralPath $connectivityPath -Raw
$forbiddenDataOperations = @(
    '\.GetStream\s*\(',
    '\.Write\s*\(',
    '\.WriteAsync\s*\(',
    '\.Read\s*\(',
    '\.ReadAsync\s*\(',
    '\.Send\s*\(',
    '\.SendAsync\s*\('
)

foreach ($pattern in $forbiddenDataOperations) {
    if ($connectivitySource -match $pattern) {
        throw "Connectivity-only test contains a forbidden data operation: $pattern"
    }
}

Assert-Equal `
    -Name 'result declares zero bytes sent' `
    -Expected $true `
    -Actual ([bool]($connectivitySource -match 'BytesSent\s*=\s*0'))

Assert-Equal `
    -Name 'result declares zero bytes received' `
    -Expected $true `
    -Actual ([bool]($connectivitySource -match 'BytesReceived\s*=\s*0'))

Write-Output 'TEST-0010B-21B: PASS'
Write-Output 'Verified: explicit network-probe confirmation and TCP-connect-only behavior with no data operations.'
