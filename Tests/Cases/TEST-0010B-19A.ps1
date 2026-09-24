Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$managerPath = 'C:\PrintGateway\Lib\PrintJobManager.ps1'
$schemaPath = 'C:\PrintGateway\Data\schema.sql'
$sqlitePath = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\sqlite3.exe'
$workDirectory = 'C:\PrintGateway\Tests\work'
$databasePath = Join-Path $workDirectory ("B19A-{0}.db" -f [Guid]::NewGuid().ToString('N'))

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

    $configuration = Initialize-PrintGatewayJobManager `
        -DatabasePath $databasePath `
        -SqlitePath $sqlitePath

    Assert-Equal -Name 'manager store' -Expected 'SQLite' -Actual $configuration.Store
    Assert-Equal -Name 'manager database path' -Expected $databasePath -Actual $configuration.DatabasePath

    $payload = [byte[]](0, 1, 2, 3, 4, 5, 250, 251, 252, 253, 254, 255)
    $payloadFingerprint = Get-PrintGatewayPayloadFingerprint -Bytes $payload
    $expectedFingerprint = 'cd09beaf9925fce70d6943827d7ab043fdd33dd2fbed38940bb92929c9dfb1b3'

    Assert-Equal -Name 'payload SHA-256' -Expected $expectedFingerprint -Actual $payloadFingerprint

    $jobId = 'B19A-DURABLE-MANAGER-001'
    $processId = '6101'

    $submission = Test-PrintGatewayJobSubmission `
        -JobId $jobId `
        -ProcessId $processId `
        -PayloadFingerprint $payloadFingerprint

    Assert-Equal -Name 'new submission allowed' -Expected $true -Actual $submission.Allowed
    Assert-Equal -Name 'new submission action' -Expected 'NEW' -Actual $submission.Action

    $job = New-PrintGatewayJob `
        -JobId $jobId `
        -ProcessId $processId `
        -PayloadFingerprint $payloadFingerprint

    Assert-Equal -Name 'new job status' -Expected 'QUEUED' -Actual $job.Status
    Assert-Equal -Name 'new job attempt' -Expected 0 -Actual $job.Attempt

    $processMismatch = Test-PrintGatewayJobSubmission `
        -JobId $jobId `
        -ProcessId '6102' `
        -PayloadFingerprint $payloadFingerprint

    Assert-Equal -Name 'process mismatch blocked' -Expected $false -Actual $processMismatch.Allowed
    Assert-Equal -Name 'process mismatch reason' -Expected 'PROCESS_ID_MISMATCH' -Actual $processMismatch.Reason

    $payloadMismatch = Test-PrintGatewayJobSubmission `
        -JobId $jobId `
        -ProcessId $processId `
        -PayloadFingerprint ('f' * 64)

    Assert-Equal -Name 'payload mismatch blocked' -Expected $false -Actual $payloadMismatch.Allowed
    Assert-Equal -Name 'payload mismatch reason' -Expected 'PAYLOAD_MISMATCH' -Actual $payloadMismatch.Reason

    $job = Start-PrintGatewayJobAttempt -JobId $jobId

    Assert-Equal -Name 'first attempt status' -Expected 'SENDING' -Actual $job.Status
    Assert-Equal -Name 'first attempt number' -Expected 1 -Actual $job.Attempt

    $job = Complete-PrintGatewayJobAttempt `
        -JobId $jobId `
        -TransportStatus 'FAILED' `
        -SendStarted:$false `
        -ErrorMessage 'Connection failed before send.'

    Assert-Equal -Name 'failed status' -Expected 'FAILED' -Actual $job.Status
    Assert-Equal -Name 'failed SendStarted' -Expected $false -Actual $job.SendStarted

    $submission = Test-PrintGatewayJobSubmission `
        -JobId $jobId `
        -ProcessId $processId `
        -PayloadFingerprint $payloadFingerprint

    Assert-Equal -Name 'safe retry allowed' -Expected $true -Actual $submission.Allowed
    Assert-Equal -Name 'safe retry action' -Expected 'RETRY' -Actual $submission.Action

    $job = Start-PrintGatewayJobAttempt -JobId $jobId

    Assert-Equal -Name 'retry status' -Expected 'SENDING' -Actual $job.Status
    Assert-Equal -Name 'retry attempt number' -Expected 2 -Actual $job.Attempt

    $job = Complete-PrintGatewayJobAttempt `
        -JobId $jobId `
        -TransportStatus 'UNKNOWN' `
        -SendStarted:$true `
        -AckReceived:$false `
        -AckValid:$false `
        -AckBytesHex '1D4931' `
        -AckElapsedMs 5000 `
        -ErrorMessage 'ACK timeout after send.'

    Assert-Equal -Name 'unknown status' -Expected 'UNKNOWN' -Actual $job.Status
    Assert-Equal -Name 'unknown SendStarted' -Expected $true -Actual $job.SendStarted
    Assert-Equal -Name 'unknown ACK bytes' -Expected '1D4931' -Actual $job.AckBytesHex
    Assert-Equal -Name 'unknown ACK elapsed' -Expected 5000 -Actual $job.AckElapsedMs

    $submission = Test-PrintGatewayJobSubmission `
        -JobId $jobId `
        -ProcessId $processId `
        -PayloadFingerprint $payloadFingerprint

    Assert-Equal -Name 'unknown submission blocked' -Expected $false -Actual $submission.Allowed
    Assert-Equal -Name 'unknown submission reason' -Expected 'UNKNOWN' -Actual $submission.Reason

    $events = @(
        Invoke-TestSql -Sql @"
SELECT EventType, IFNULL(FromStatus, ''), ToStatus, Attempt
FROM job_events
WHERE JobId = '$jobId'
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

    Assert-Equal -Name 'audit event count' -Expected $expectedEvents.Count -Actual $events.Count

    for ($index = 0; $index -lt $expectedEvents.Count; $index++) {
        Assert-Equal `
            -Name "audit event $index" `
            -Expected $expectedEvents[$index] `
            -Actual $events[$index]
    }

    $legacyGlobal = Get-Variable `
        -Scope Global `
        -Name PrintGatewayJobs `
        -ErrorAction SilentlyContinue

    Assert-Equal -Name 'legacy global in-memory store removed' -Expected $null -Actual $legacyGlobal

    . $managerPath

    $notInitializedWasBlocked = $false

    try {
        Get-PrintGatewayJob -JobId $jobId | Out-Null
    }
    catch {
        $notInitializedWasBlocked = $_.Exception.Message -like '*not initialized*'
    }

    Assert-Equal -Name 'reload requires explicit initialization' -Expected $true -Actual $notInitializedWasBlocked

    Initialize-PrintGatewayJobManager `
        -DatabasePath $databasePath `
        -SqlitePath $sqlitePath | Out-Null

    $reloadedJob = Get-PrintGatewayJob -JobId $jobId

    Assert-Equal -Name 'reloaded durable status' -Expected 'UNKNOWN' -Actual $reloadedJob.Status
    Assert-Equal -Name 'reloaded durable attempt' -Expected 2 -Actual $reloadedJob.Attempt
    Assert-Equal -Name 'reloaded durable fingerprint' -Expected $payloadFingerprint -Actual $reloadedJob.PayloadFingerprint

    Write-Output 'TEST-0010B-19A: PASS'
    Write-Output 'Verified: SQLite-only manager, payload identity, durable reload, transitions, and audit trail.'
}
finally {
    if ($null -ne (Get-Command Close-PrintGatewayJobManager -ErrorAction SilentlyContinue)) {
        Close-PrintGatewayJobManager
    }

    if (Test-Path -LiteralPath $databasePath) {
        Remove-Item -LiteralPath $databasePath -Force
    }
}
