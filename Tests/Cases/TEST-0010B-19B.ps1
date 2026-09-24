Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$managerPath = 'C:\PrintGateway\Lib\PrintJobManager.ps1'
$schemaPath = 'C:\PrintGateway\Data\schema.sql'
$sqlitePath = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\sqlite3.exe'
$workDirectory = 'C:\PrintGateway\Tests\work'
$databasePath = Join-Path $workDirectory ("B19B-{0}.db" -f [Guid]::NewGuid().ToString('N'))

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

foreach ($requiredPath in @($managerPath, $schemaPath, $sqlitePath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Required file not found: $requiredPath"
    }
}

New-Item -ItemType Directory -Path $workDirectory -Force | Out-Null
New-Item -ItemType File -Path $databasePath -Force | Out-Null

try {
    Invoke-TestSql -Sql (Get-Content -LiteralPath $schemaPath -Raw) | Out-Null

    . $managerPath

    Initialize-PrintGatewayJobManager `
        -DatabasePath $databasePath `
        -SqlitePath $sqlitePath | Out-Null

    $fingerprintA = 'a' * 64
    $fingerprintB = 'b' * 64
    $fingerprintQueued = 'c' * 64

    New-PrintGatewayJob `
        -JobId 'B19B-SENDING-001' `
        -ProcessId '6201' `
        -PayloadFingerprint $fingerprintA | Out-Null

    Start-PrintGatewayJobAttempt -JobId 'B19B-SENDING-001' | Out-Null

    New-PrintGatewayJob `
        -JobId 'B19B-SENDING-002' `
        -ProcessId '6202' `
        -PayloadFingerprint $fingerprintB | Out-Null

    Start-PrintGatewayJobAttempt -JobId 'B19B-SENDING-002' | Out-Null

    New-PrintGatewayJob `
        -JobId 'B19B-QUEUED-001' `
        -ProcessId '6203' `
        -PayloadFingerprint $fingerprintQueued | Out-Null

    Invoke-TestSql -Sql @"
UPDATE print_jobs
SET
    SendStarted = 1,
    AckReceived = 1,
    AckValid = 0,
    ReturnedProcessId = '6201',
    AckBytesHex = '1D4931',
    AckElapsedMs = 123
WHERE JobId = 'B19B-SENDING-001';
"@ | Out-Null

    $reason = "Startup recovery test: printer's outcome is unknown."
    $recoveredCount = Recover-PrintGatewaySendingJobs -Reason $reason

    Assert-Equal -Name 'startup recovered count' -Expected 2 -Actual $recoveredCount

    $first = Get-PrintGatewayJob -JobId 'B19B-SENDING-001'
    $second = Get-PrintGatewayJob -JobId 'B19B-SENDING-002'
    $queued = Get-PrintGatewayJob -JobId 'B19B-QUEUED-001'

    Assert-Equal -Name 'first recovered status' -Expected 'UNKNOWN' -Actual $first.Status
    Assert-Equal -Name 'first preserved Attempt' -Expected 1 -Actual $first.Attempt
    Assert-Equal -Name 'first preserved SendStarted' -Expected $true -Actual $first.SendStarted
    Assert-Equal -Name 'first preserved AckReceived' -Expected $true -Actual $first.AckReceived
    Assert-Equal -Name 'first preserved AckValid' -Expected $false -Actual $first.AckValid
    Assert-Equal -Name 'first preserved ReturnedProcessId' -Expected '6201' -Actual $first.ReturnedProcessId
    Assert-Equal -Name 'first preserved AckBytesHex' -Expected '1D4931' -Actual $first.AckBytesHex
    Assert-Equal -Name 'first preserved AckElapsedMs' -Expected 123 -Actual $first.AckElapsedMs
    Assert-Equal -Name 'first recovery reason' -Expected $reason -Actual $first.LastError

    Assert-Equal -Name 'second recovered status' -Expected 'UNKNOWN' -Actual $second.Status
    Assert-Equal -Name 'second preserved Attempt' -Expected 1 -Actual $second.Attempt
    Assert-Equal -Name 'second preserved SendStarted' -Expected $false -Actual $second.SendStarted
    Assert-Equal -Name 'queued job unchanged' -Expected 'QUEUED' -Actual $queued.Status

    $recoveryEventCount = [int]@(
        Invoke-TestSql -Sql "SELECT COUNT(*) FROM job_events WHERE EventType = 'RECOVERED_STALE_SENDING';"
    )[-1]

    Assert-Equal -Name 'startup recovery event count' -Expected 2 -Actual $recoveryEventCount

    $secondRunCount = Recover-PrintGatewaySendingJobs -Reason $reason

    Assert-Equal -Name 'repeated startup recovery count' -Expected 0 -Actual $secondRunCount

    $recoveryEventCountAfterRepeat = [int]@(
        Invoke-TestSql -Sql "SELECT COUNT(*) FROM job_events WHERE EventType = 'RECOVERED_STALE_SENDING';"
    )[-1]

    Assert-Equal `
        -Name 'no duplicate startup recovery events' `
        -Expected 2 `
        -Actual $recoveryEventCountAfterRepeat

    foreach ($suffix in @('001', '002')) {
        New-PrintGatewayJob `
            -JobId "B19B-ROLLBACK-$suffix" `
            -ProcessId ("630{0}" -f $suffix[-1]) `
            -PayloadFingerprint ('d' * 64) | Out-Null

        Start-PrintGatewayJobAttempt -JobId "B19B-ROLLBACK-$suffix" | Out-Null
    }

    Invoke-TestSql -Sql @"
CREATE TRIGGER block_b19b_recovery_audit
BEFORE INSERT ON job_events
WHEN NEW.EventType = 'RECOVERED_STALE_SENDING'
BEGIN
    SELECT RAISE(ABORT, 'forced bulk recovery audit failure');
END;
"@ | Out-Null

    $auditFailureWasRaised = $false

    try {
        Recover-PrintGatewaySendingJobs | Out-Null
    }
    catch {
        $auditFailureWasRaised = $_.Exception.Message -like '*forced bulk recovery audit failure*'
    }

    Assert-Equal -Name 'bulk audit failure raised' -Expected $true -Actual $auditFailureWasRaised

    $rollbackRows = @(
        Invoke-TestSql -Sql @"
SELECT JobId, Status, Attempt
FROM print_jobs
WHERE JobId LIKE 'B19B-ROLLBACK-%'
ORDER BY JobId;
"@
    )

    Assert-Equal -Name 'rollback job count' -Expected 2 -Actual $rollbackRows.Count
    Assert-Equal -Name 'first rollback state' -Expected "B19B-ROLLBACK-001`tSENDING`t1" -Actual $rollbackRows[0]
    Assert-Equal -Name 'second rollback state' -Expected "B19B-ROLLBACK-002`tSENDING`t1" -Actual $rollbackRows[1]

    $rollbackRecoveryEvents = [int]@(
        Invoke-TestSql -Sql @"
SELECT COUNT(*)
FROM job_events
WHERE JobId LIKE 'B19B-ROLLBACK-%'
  AND EventType = 'RECOVERED_STALE_SENDING';
"@
    )[-1]

    Assert-Equal -Name 'no events after bulk rollback' -Expected 0 -Actual $rollbackRecoveryEvents

    Write-Output 'TEST-0010B-19B: PASS'
    Write-Output 'Verified: atomic startup recovery, evidence preservation, repeat safety, and rollback.'
}
finally {
    if ($null -ne (Get-Command Close-PrintGatewayJobManager -ErrorAction SilentlyContinue)) {
        Close-PrintGatewayJobManager
    }

    if (Test-Path -LiteralPath $databasePath) {
        Remove-Item -LiteralPath $databasePath -Force
    }
}
