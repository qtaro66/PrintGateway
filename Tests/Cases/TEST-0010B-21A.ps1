Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$commissioningPath = Join-Path $repositoryRoot 'Tests\Hardware\Invoke-PrinterCommissioning.ps1'
$profilePath = Join-Path $repositoryRoot 'Tests\Hardware\Profiles\epson-tm-t82x-m352a-v1.test.json'
$schemaPath = Join-Path $repositoryRoot 'Tests\Hardware\Schemas\printer-test-profile-v1.schema.json'

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

function Assert-Match {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$Pattern,

        [AllowNull()]
        [string]$Actual
    )

    if ($Actual -notmatch $Pattern) {
        throw "Assertion failed for ${Name}: '$Actual' does not match '$Pattern'."
    }
}

foreach ($requiredPath in @($commissioningPath, $profilePath, $schemaPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Required file not found: $requiredPath"
    }
}

$profileJson = Get-Content -LiteralPath $profilePath -Raw
Assert-Equal `
    -Name 'profile schema validation' `
    -Expected $true `
    -Actual ($profileJson | Test-Json -SchemaFile $schemaPath)

$plan = & $commissioningPath `
    -ProfilePath $profilePath `
    -PrinterIp '10.255.255.254' `
    -PlanOnly

Assert-Equal -Name 'plan mode' -Expected 'PlanOnly' -Actual $plan.Mode
Assert-Equal -Name 'no network access' -Expected $true -Actual $plan.NoNetworkAccess
Assert-Equal -Name 'no database access' -Expected $true -Actual $plan.NoDatabaseAccess
Assert-Equal -Name 'no printer bytes sent' -Expected $true -Actual $plan.NoPrinterBytesSent
Assert-Equal -Name 'automatic completed disabled' -Expected $false -Actual $plan.AutomaticCompleted
Assert-Equal -Name 'automatic retry after send disabled' -Expected $false -Actual $plan.AutomaticRetryAfterSend
Assert-Equal -Name 'profile default port' -Expected 9100 -Actual $plan.PrinterPort
Assert-Match `
    -Name 'Gregorian UTC test run ID' `
    -Pattern '^COMM-20\d{6}T\d{6}Z-[0-9a-f]{8}$' `
    -Actual $plan.TestRunId

$noPlanWasBlocked = $false

try {
    & $commissioningPath `
        -ProfilePath $profilePath `
        -PrinterIp '10.255.255.254' | Out-Null
}
catch {
    $noPlanWasBlocked = $_.Exception.Message -like '*Re-run with -PlanOnly*'
}

Assert-Equal -Name 'execution without PlanOnly blocked' -Expected $true -Actual $noPlanWasBlocked

$confirmationWasBlocked = $false

try {
    & $commissioningPath `
        -ProfilePath $profilePath `
        -PrinterIp '10.255.255.254' `
        -PlanOnly `
        -ConfirmHardwarePrint | Out-Null
}
catch {
    $confirmationWasBlocked = $_.Exception.Message -like '*blocked in PlanOnly mode*'
}

Assert-Equal -Name 'hardware confirmation blocked' -Expected $true -Actual $confirmationWasBlocked

$publicIpWasBlocked = $false

try {
    & $commissioningPath `
        -ProfilePath $profilePath `
        -PrinterIp '192.0.2.10' `
        -PlanOnly | Out-Null
}
catch {
    $publicIpWasBlocked = $_.Exception.Message -like '*RFC1918 private IPv4*'
}

Assert-Equal -Name 'public or documentation address blocked' -Expected $true -Actual $publicIpWasBlocked

$outsideProfileWasBlocked = $false

try {
    & $commissioningPath `
        -ProfilePath $schemaPath `
        -PrinterIp '10.255.255.254' `
        -PlanOnly | Out-Null
}
catch {
    $outsideProfileWasBlocked = $_.Exception.Message -like '*inside the hardware Profiles directory*'
}

Assert-Equal -Name 'profile outside approved directory blocked' -Expected $true -Actual $outsideProfileWasBlocked

$forbiddenPatterns = @(
    'TcpClient',
    'UdpClient',
    'System\.Net\.Sockets\.Socket',
    'Invoke-WebRequest',
    'Invoke-RestMethod',
    'Test-NetConnection',
    'EpsonTransport',
    'PrintJobManager',
    'sqlite3'
)

$commissioningSource = Get-Content -LiteralPath $commissioningPath -Raw

foreach ($pattern in $forbiddenPatterns) {
    if ($commissioningSource -match $pattern) {
        throw "Plan-only entry point contains forbidden API or dependency: $pattern"
    }
}

Write-Output 'TEST-0010B-21A: PASS'
Write-Output 'Verified: schema validation, plan-only behavior, private IPv4 policy, and hardware/network/database safety gates.'
