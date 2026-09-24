Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$storePath = 'C:\PrintGateway\Lib\PrintJobStore.ps1'
$schemaPath = 'C:\PrintGateway\Data\schema.sql'
$sqlitePath = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\sqlite3.exe'
$workDirectory = 'C:\PrintGateway\Tests\work'
$databasePath = Join-Path $workDirectory ("B18BO-{0}.db" -f [Guid]::NewGuid().ToString('N'))

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

foreach ($requiredPath in @($storePath, $schemaPath, $sqlitePath)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
        throw "Required file not found: $requiredPath"
    }
}

New-Item -ItemType Directory -Path $workDirectory -Force | Out-Null
New-Item -ItemType File -Path $databasePath -Force | Out-Null

try {
    $schemaSql = Get-Content -LiteralPath $schemaPath -Raw
    Invoke-TestSql -Sql $schemaSql | Out-Null

    . $storePath

    $jobId = 'B18BO-PRESERVE-EVIDENCE'
    $reason = "Service restart test: printer's outcome is unknown."

    Invoke-TestSql -Sql @"
INSERT INTO print_jobs (
    JobId,
    ProcessId,
    PayloadFingerprint,
    Status,
    Attempt,
    SendStarted,
    AckReceived,
    AckValid,
    ReturnedProcessId,
    AckBytesHex,
    AckElapsedMs,
    LastError,
    CreatedAtUtc,
    UpdatedAtUtc,
    CompletedAtUtc
)
VALUES (
    '$jobId',
    '1234',
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    'SENDING',
    4,
    1,
    1,
    1,
    '1234',
    '1D4931313131323334',
    87,
    'Evidence recorded before restart',
    '2026-09-24T01:00:00.000Z',
    '2026-09-24T01:01:00.000Z',
    NULL
);
"@ | Out-Null

    $recovered = Recover-PrintJobStoreSendingJob `
        -DatabasePath $databasePath `
        -JobId $jobId `
        -Reason $reason `
        -SqlitePath $sqlitePath

    Assert-Equal -Name 'recovered Status' -Expected 'UNKNOWN' -Actual $recovered.Status
    Assert-Equal -Name 'preserved Attempt' -Expected 4 -Actual $recovered.Attempt
    Assert-Equal -Name 'preserved SendStarted' -Expected $true -Actual $recovered.SendStarted
    Assert-Equal -Name 'preserved AckReceived' -Expected $true -Actual $recovered.AckReceived
    Assert-Equal -Name 'preserved AckValid' -Expected $true -Actual $recovered.AckValid
    Assert-Equal -Name 'preserved ReturnedProcessId' -Expected '1234' -Actual $recovered.ReturnedProcessId
    Assert-Equal -Name 'preserved AckBytesHex' -Expected '1D4931313131323334' -Actual $recovered.AckBytesHex
    Assert-Equal -Name 'preserved AckElapsedMs' -Expected 87 -Actual $recovered.AckElapsedMs
    Assert-Equal -Name 'recovery LastError' -Expected $reason -Actual $recovered.LastError
    Assert-Equal -Name 'recovery CompletedAtUtc' -Expected $null -Actual $recovered.CompletedAtUtc

    $eventRow = @(
        Invoke-TestSql -Sql @"
SELECT
    EventType,
    FromStatus,
    ToStatus,
    Attempt,
    Message
FROM job_events
WHERE JobId = '$jobId'
ORDER BY EventId;
"@
    )

    Assert-Equal -Name 'audit event count after recovery' -Expected 1 -Actual $eventRow.Count

    $eventColumns = $eventRow[0] -split "`t"
    Assert-Equal -Name 'audit EventType' -Expected 'RECOVERED_STALE_SENDING' -Actual $eventColumns[0]
    Assert-Equal -Name 'audit FromStatus' -Expected 'SENDING' -Actual $eventColumns[1]
    Assert-Equal -Name 'audit ToStatus' -Expected 'UNKNOWN' -Actual $eventColumns[2]
    Assert-Equal -Name 'audit Attempt' -Expected '4' -Actual $eventColumns[3]
    Assert-Equal -Name 'audit Message' -Expected $reason -Actual $eventColumns[4]

    $repeatWasBlocked = $false

    try {
        Recover-PrintJobStoreSendingJob `
            -DatabasePath $databasePath `
            -JobId $jobId `
            -Reason $reason `
            -SqlitePath $sqlitePath | Out-Null
    }
    catch {
        $repeatWasBlocked = $_.Exception.Message -like '*not eligible for SENDING recovery*'
    }

    Assert-Equal -Name 'repeated recovery blocked' -Expected $true -Actual $repeatWasBlocked

    $eventCountAfterRepeat = @(
        Invoke-TestSql -Sql "SELECT COUNT(*) FROM job_events WHERE JobId = '$jobId';"
    )[-1]

    Assert-Equal -Name 'audit event count after repeated recovery' -Expected '1' -Actual $eventCountAfterRepeat

    $atomicJobId = 'B18BO-ATOMIC-ROLLBACK'

    Invoke-TestSql -Sql @"
INSERT INTO print_jobs (
    JobId,
    ProcessId,
    PayloadFingerprint,
    Status,
    Attempt,
    SendStarted,
    AckReceived,
    AckValid,
    CreatedAtUtc,
    UpdatedAtUtc
)
VALUES (
    '$atomicJobId',
    '5678',
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
    'SENDING',
    7,
    0,
    0,
    0,
    '2026-09-24T02:00:00.000Z',
    '2026-09-24T02:01:00.000Z'
);

CREATE TRIGGER block_b18bo_audit
BEFORE INSERT ON job_events
WHEN NEW.EventType = 'RECOVERED_STALE_SENDING'
BEGIN
    SELECT RAISE(ABORT, 'forced audit failure');
END;
"@ | Out-Null

    $auditFailureWasRaised = $false

    try {
        Recover-PrintJobStoreSendingJob `
            -DatabasePath $databasePath `
            -JobId $atomicJobId `
            -SqlitePath $sqlitePath | Out-Null
    }
    catch {
        $auditFailureWasRaised = $_.Exception.Message -like '*forced audit failure*'
    }

    Assert-Equal -Name 'forced audit failure raised' -Expected $true -Actual $auditFailureWasRaised

    $atomicState = @(
        Invoke-TestSql -Sql @"
SELECT
    print_jobs.Status,
    print_jobs.Attempt,
    print_jobs.SendStarted,
    print_jobs.AckReceived,
    print_jobs.AckValid,
    COUNT(job_events.EventId)
FROM print_jobs
LEFT JOIN job_events USING (JobId)
WHERE print_jobs.JobId = '$atomicJobId'
GROUP BY print_jobs.JobId;
"@
    )[-1] -split "`t"

    Assert-Equal -Name 'status rolled back after audit failure' -Expected 'SENDING' -Actual $atomicState[0]
    Assert-Equal -Name 'attempt retained after audit failure' -Expected '7' -Actual $atomicState[1]
    Assert-Equal -Name 'SendStarted retained after audit failure' -Expected '0' -Actual $atomicState[2]
    Assert-Equal -Name 'AckReceived retained after audit failure' -Expected '0' -Actual $atomicState[3]
    Assert-Equal -Name 'AckValid retained after audit failure' -Expected '0' -Actual $atomicState[4]
    Assert-Equal -Name 'no audit event after audit failure' -Expected '0' -Actual $atomicState[5]

    Write-Output 'TEST-0010B-18BO: PASS'
    Write-Output 'Verified: atomic audit, evidence preservation, and repeated-recovery blocking.'
}
finally {
    if (Test-Path -LiteralPath $databasePath) {
        Remove-Item -LiteralPath $databasePath -Force
    }
}
