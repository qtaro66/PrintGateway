Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$integrationPath = 'C:\PrintGateway\Tests\Cases\Invoke-PrintGatewayIntegrationScenario.ps1'
$schemaPath = 'C:\PrintGateway\Data\schema.sql'
$sqlitePath = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\sqlite3.exe'
$workDirectory = 'C:\PrintGateway\Tests\work'
$databasePath = Join-Path $workDirectory ("B19D-{0}.db" -f [Guid]::NewGuid().ToString('N'))

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

function Invoke-TestSql {
    param(
        [Parameter(Mandatory)]
        [string]$Sql
    )

    $output = & $sqlitePath -batch -noheader -separator "`t" $databasePath $Sql 2>&1

    if ($LASTEXITCODE -ne 0) {
        throw "Test SQLite failed: $($output -join [Environment]::NewLine)"
    }

    return @($output)
}

function Invoke-IntegrationSimulation {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('FailedBeforeSend', 'UnknownAfterSend', 'Completed')]
        [string]$Mode
    )

    $output = @(
        & pwsh `
            -NoProfile `
            -NonInteractive `
            -File $integrationPath `
            -DatabasePath $databasePath `
            -SqlitePath $sqlitePath `
            -TransportMode $Mode 2>&1
    )

    if ($LASTEXITCODE -ne 0) {
        throw "Integration simulation '$Mode' failed: $($output -join [Environment]::NewLine)"
    }

    return @($output | ForEach-Object { [string]$_ })
}

foreach ($requiredPath in @($integrationPath, $schemaPath, $sqlitePath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Required file not found: $requiredPath"
    }
}

New-Item -ItemType Directory -Path $workDirectory -Force | Out-Null
New-Item -ItemType File -Path $databasePath -Force | Out-Null

try {
    Invoke-TestSql -Sql (Get-Content -LiteralPath $schemaPath -Raw) | Out-Null

    $firstRun = @(
        Invoke-IntegrationSimulation -Mode 'FailedBeforeSend'
    )

    Assert-Equal `
        -Name 'first simulation reports safe failure' `
        -Expected $true `
        -Actual ([bool]($firstRun -match 'RESULT: FAILED BEFORE SEND'))

    $afterFirstRun = @(
        Invoke-TestSql -Sql @"
SELECT Status, Attempt, SendStarted, AckReceived, AckValid
FROM print_jobs
WHERE JobId = 'ORDER-B17-004';
"@
    )[-1]

    Assert-Equal -Name 'first simulation durable state' -Expected "FAILED`t1`t0`t0`t0" -Actual $afterFirstRun

    $secondRun = @(
        Invoke-IntegrationSimulation -Mode 'UnknownAfterSend'
    )

    Assert-Equal `
        -Name 'second simulation reports unknown' `
        -Expected $true `
        -Actual ([bool]($secondRun -match 'RESULT: UNKNOWN'))

    $afterSecondRun = @(
        Invoke-TestSql -Sql @"
SELECT
    Status,
    Attempt,
    SendStarted,
    AckReceived,
    AckValid,
    AckBytesHex,
    AckElapsedMs
FROM print_jobs
WHERE JobId = 'ORDER-B17-004';
"@
    )[-1]

    Assert-Equal `
        -Name 'second simulation durable state and evidence' `
        -Expected "UNKNOWN`t2`t1`t0`t0`t1D4931`t5000" `
        -Actual $afterSecondRun

    $thirdRun = @(
        Invoke-IntegrationSimulation -Mode 'UnknownAfterSend'
    )

    Assert-Equal `
        -Name 'third simulation is blocked before transport' `
        -Expected $true `
        -Actual ([bool]($thirdRun -match 'JOB BLOCKED'))

    $events = @(
        Invoke-TestSql -Sql @"
SELECT EventType, IFNULL(FromStatus, ''), ToStatus, Attempt
FROM job_events
WHERE JobId = 'ORDER-B17-004'
ORDER BY EventId;
"@
    )

    $expectedEvents = @(
        "CREATED`t`tQUEUED`t0",
        "STARTED`tQUEUED`tSENDING`t1",
        "FAILED`tSENDING`tFAILED`t1",
        "RETRY_STARTED`tFAILED`tSENDING`t2",
        "UNKNOWN`tSENDING`tUNKNOWN`t2"
    )

    Assert-Equal -Name 'integration audit event count' -Expected $expectedEvents.Count -Actual $events.Count

    for ($index = 0; $index -lt $expectedEvents.Count; $index++) {
        Assert-Equal `
            -Name "integration audit event $index" `
            -Expected $expectedEvents[$index] `
            -Actual $events[$index]
    }

    $identity = @(
        Invoke-TestSql -Sql @"
SELECT
    length(PayloadFingerprint),
    COUNT(DISTINCT PayloadFingerprint)
FROM print_jobs
WHERE JobId = 'ORDER-B17-004';
"@
    )[-1]

    Assert-Equal -Name 'stable SHA-256 payload identity' -Expected "64`t1" -Actual $identity

    Write-Output 'TEST-0010B-19D: PASS'
    Write-Output 'Verified: migrated integration flow with no printer connection.'
}
finally {
    if (Test-Path -LiteralPath $databasePath) {
        Remove-Item -LiteralPath $databasePath -Force
    }
}
