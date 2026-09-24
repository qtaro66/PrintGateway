Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$integrationPath = 'C:\PrintGateway\Tests\Cases\Invoke-PrintGatewayIntegrationScenario.ps1'
$schemaPath = 'C:\PrintGateway\Data\schema.sql'
$sqlitePath = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\sqlite3.exe'
$workDirectory = 'C:\PrintGateway\Tests\work'
$noSendDatabasePath = Join-Path $workDirectory ("B19E-NOSEND-{0}.db" -f [Guid]::NewGuid().ToString('N'))
$completedDatabasePath = Join-Path $workDirectory ("B19E-COMPLETED-{0}.db" -f [Guid]::NewGuid().ToString('N'))

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

function Initialize-TestDatabase {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    New-Item -ItemType File -Path $Path -Force | Out-Null
    $schemaSql = Get-Content -LiteralPath $schemaPath -Raw
    $output = & $sqlitePath -batch $Path $schemaSql 2>&1

    if ($LASTEXITCODE -ne 0) {
        throw "Schema initialization failed: $($output -join [Environment]::NewLine)"
    }
}

function Invoke-TestSql {
    param(
        [Parameter(Mandatory)]
        [string]$DatabasePath,

        [Parameter(Mandatory)]
        [string]$Sql
    )

    $output = & $sqlitePath -batch -noheader -separator "`t" $DatabasePath $Sql 2>&1

    if ($LASTEXITCODE -ne 0) {
        throw "Test SQLite failed: $($output -join [Environment]::NewLine)"
    }

    return @($output)
}

function Invoke-Integration {
    param(
        [Parameter(Mandatory)]
        [string]$DatabasePath,

        [AllowNull()]
        [string]$Mode
    )

    $arguments = @(
        '-NoProfile',
        '-NonInteractive',
        '-File',
        $integrationPath,
        '-DatabasePath',
        $DatabasePath,
        '-SqlitePath',
        $sqlitePath
    )

    if (-not [string]::IsNullOrWhiteSpace($Mode)) {
        $arguments += @('-TransportMode', $Mode)
    }

    $output = @(& pwsh @arguments 2>&1)

    if ($LASTEXITCODE -ne 0) {
        throw "Integration preflight failed: $($output -join [Environment]::NewLine)"
    }

    return @($output | ForEach-Object { [string]$_ })
}

foreach ($requiredPath in @($integrationPath, $schemaPath, $sqlitePath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Required file not found: $requiredPath"
    }
}

New-Item -ItemType Directory -Path $workDirectory -Force | Out-Null

try {
    Initialize-TestDatabase -Path $noSendDatabasePath
    Initialize-TestDatabase -Path $completedDatabasePath

    $noSendOutput = @(
        Invoke-Integration `
            -DatabasePath $noSendDatabasePath `
            -Mode $null
    )

    Assert-Equal `
        -Name 'default mode is NoSend' `
        -Expected $true `
        -Actual ([bool]($noSendOutput -match 'NO-SEND VALIDATION PASS'))

    Assert-Equal `
        -Name 'NoSend did not connect to printer' `
        -Expected $false `
        -Actual ([bool]($noSendOutput -match '\[TRANSPORT\] Connecting'))

    $noSendCounts = @(
        Invoke-TestSql `
            -DatabasePath $noSendDatabasePath `
            -Sql 'SELECT (SELECT COUNT(*) FROM print_jobs), (SELECT COUNT(*) FROM job_events);'
    )[-1]

    Assert-Equal -Name 'NoSend created no durable records' -Expected "0`t0" -Actual $noSendCounts

    $completedOutput = @(
        Invoke-Integration `
            -DatabasePath $completedDatabasePath `
            -Mode 'Completed'
    )

    Assert-Equal `
        -Name 'completed simulation reports completed' `
        -Expected $true `
        -Actual ([bool]($completedOutput -match 'TEST-0010B-17A PASS'))

    Assert-Equal `
        -Name 'completed simulation did not connect to printer' `
        -Expected $false `
        -Actual ([bool]($completedOutput -match '\[TRANSPORT\] Connecting'))

    $completedState = @(
        Invoke-TestSql `
            -DatabasePath $completedDatabasePath `
            -Sql @"
SELECT
    Status,
    Attempt,
    SendStarted,
    AckReceived,
    AckValid,
    ReturnedProcessId,
    AckBytesHex,
    AckElapsedMs,
    CASE WHEN CompletedAtUtc IS NULL THEN 0 ELSE 1 END,
    length(PayloadFingerprint)
FROM print_jobs
WHERE JobId = 'ORDER-B17-004';
"@
    )[-1]

    Assert-Equal `
        -Name 'completed durable state and ACK evidence' `
        -Expected "COMPLETED`t1`t1`t1`t1`t0020`t1D4931`t25`t1`t64" `
        -Actual $completedState

    $duplicateOutput = @(
        Invoke-Integration `
            -DatabasePath $completedDatabasePath `
            -Mode 'Completed'
    )

    Assert-Equal `
        -Name 'completed duplicate blocked' `
        -Expected $true `
        -Actual ([bool]($duplicateOutput -match 'JOB BLOCKED'))

    Assert-Equal `
        -Name 'duplicate did not connect to printer' `
        -Expected $false `
        -Actual ([bool]($duplicateOutput -match '\[TRANSPORT\] Connecting'))

    $events = @(
        Invoke-TestSql `
            -DatabasePath $completedDatabasePath `
            -Sql @"
SELECT EventType, IFNULL(FromStatus, ''), ToStatus, Attempt
FROM job_events
WHERE JobId = 'ORDER-B17-004'
ORDER BY EventId;
"@
    )

    Assert-Equal -Name 'completed audit count' -Expected 3 -Actual $events.Count
    Assert-Equal -Name 'completed created event' -Expected "CREATED`t`tQUEUED`t0" -Actual $events[0]
    Assert-Equal -Name 'completed started event' -Expected "STARTED`tQUEUED`tSENDING`t1" -Actual $events[1]
    Assert-Equal -Name 'completed terminal event' -Expected "COMPLETED`tSENDING`tCOMPLETED`t1" -Actual $events[2]

    Write-Output 'TEST-0010B-19E: PASS'
    Write-Output 'Verified: explicit printer opt-in, NoSend default, completed ACK evidence, and terminal blocking.'
}
finally {
    foreach ($path in @($noSendDatabasePath, $completedDatabasePath)) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force
        }
    }
}
