Set-StrictMode -Version Latest

function Resolve-PrintGatewaySqlitePath {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$SqlitePath
    )

    if (-not [string]::IsNullOrWhiteSpace($SqlitePath)) {
        if (-not (Test-Path -LiteralPath $SqlitePath -PathType Leaf)) {
            throw "sqlite3.exe not found: $SqlitePath"
        }

        return [System.IO.Path]::GetFullPath($SqlitePath)
    }

    $bundledPath = 'C:\PrintGateway\Bin\sqlite3.exe'

    if (Test-Path -LiteralPath $bundledPath -PathType Leaf) {
        return $bundledPath
    }

    $pathCommand = Get-Command sqlite3.exe -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if ($null -ne $pathCommand) {
        return [System.IO.Path]::GetFullPath($pathCommand.Source)
    }

    $developerPath = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\sqlite3.exe'

    if (Test-Path -LiteralPath $developerPath -PathType Leaf) {
        return $developerPath
    }

    throw 'sqlite3.exe was not found. Supply -SqlitePath or install it at C:\PrintGateway\Bin\sqlite3.exe.'
}

function Invoke-PrintJobStoreSqlite {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DatabasePath,

        [Parameter(Mandatory)]
        [string]$Sql,

        [AllowNull()]
        [string]$SqlitePath = $null
    )

    $SqlitePath = Resolve-PrintGatewaySqlitePath -SqlitePath $SqlitePath

    if (-not (Test-Path -LiteralPath $DatabasePath)) {
        throw "Database not found: $DatabasePath"
    }

    # รัน sqlite3 โดยใช้ Tab (`t) เป็นตัวคั่น เพื่อไม่ให้ชนกับ | ในข้อความ Error
    $output = & $SqlitePath -batch -noheader -separator "`t" $DatabasePath $Sql 2>&1

    if ($LASTEXITCODE -ne 0) {
        throw "SQLite failed: $($output -join [Environment]::NewLine)"
    }

    return $output
}


function Get-PrintJobStoreJob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DatabasePath,

        [Parameter(Mandatory)]
        [string]$JobId,

        [AllowNull()]
        [string]$SqlitePath = $null
    )

    if ([string]::IsNullOrWhiteSpace($JobId)) {
        throw "JobId cannot be empty."
    }

    $safeJobId = $JobId.Replace("'", "''")

    $sql = @"
SELECT
    JobId,
    ProcessId,
    PayloadFingerprint,
    Status,
    Attempt,
    SendStarted,
    AckReceived,
    AckValid,
    IFNULL(ReturnedProcessId, ''),
    IFNULL(AckBytesHex, ''),
    IFNULL(AckElapsedMs, ''),
    IFNULL(LastError, ''),
    CreatedAtUtc,
    UpdatedAtUtc,
    IFNULL(CompletedAtUtc, '')
FROM print_jobs
WHERE JobId = '$safeJobId'
LIMIT 1;
"@

    $rawOutput = Invoke-PrintJobStoreSqlite `
        -DatabasePath $DatabasePath `
        -Sql $sql `
        -SqlitePath $SqlitePath

    # กรองเฉพาะแถวที่มีข้อความ ไม่นับสตริงว่างหรือ $null
    $rows = @($rawOutput | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    if ($rows.Count -eq 0) {
        return $null
    }

    if ($rows.Count -ne 1) {
        throw "Unexpected SQLite result count for JobId '$JobId': $($rows.Count)"
    }

    $columns = $rows[0] -split "`t"

    if ($columns.Count -ne 15) {
        throw "Unexpected column count for JobId '$JobId': $($columns.Count)"
    }

    [PSCustomObject]@{
        JobId              = $columns[0]
        ProcessId          = $columns[1]
        PayloadFingerprint = $columns[2]
        Status             = $columns[3]
        Attempt            = [int]$columns[4]
        SendStarted        = ([int]$columns[5] -eq 1)
        AckReceived        = ([int]$columns[6] -eq 1)
        AckValid           = ([int]$columns[7] -eq 1)
        ReturnedProcessId  = if ($columns[8] -eq '') { $null } else { $columns[8] }
        AckBytesHex        = if ($columns[9] -eq '') { $null } else { $columns[9] }
        AckElapsedMs       = if ($columns[10] -eq '') { $null } else { [int]$columns[10] }
        LastError          = if ($columns[11] -eq '') { $null } else { $columns[11] }
        CreatedAtUtc       = $columns[12]
        UpdatedAtUtc       = $columns[13]
        CompletedAtUtc     = if ($columns[14] -eq '') { $null } else { $columns[14] }
    }
}

function Test-PrintJobStoreSubmission {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DatabasePath,

        [Parameter(Mandatory)]
        [string]$JobId,

        [Parameter(Mandatory)]
        [string]$ProcessId,

        [Parameter(Mandatory)]
        [string]$PayloadFingerprint,

        [AllowNull()]
        [string]$SqlitePath = $null
    )

    if ([string]::IsNullOrWhiteSpace($JobId)) {
        throw "JobId cannot be empty."
    }

    if ($ProcessId -notmatch '^\d{4}$') {
        throw "ProcessId must contain exactly 4 digits."
    }

    if ($PayloadFingerprint -notmatch '^[0-9A-Fa-f]{64}$') {
        throw "PayloadFingerprint must be a 64-character SHA-256 hexadecimal string."
    }

    $job = Get-PrintJobStoreJob `
        -DatabasePath $DatabasePath `
        -JobId $JobId `
        -SqlitePath $SqlitePath

    if ($null -eq $job) {
        return [PSCustomObject]@{
            Allowed = $true
            Action  = 'NEW'
            Reason  = 'Job ID not found.'
            Status  = $null
        }
    }

    if ($job.ProcessId -ne $ProcessId) {
        return [PSCustomObject]@{
            Allowed = $false
            Action  = 'BLOCK'
            Reason  = 'PROCESS_ID_MISMATCH'
            Status  = $job.Status
        }
    }

    if ($job.PayloadFingerprint -ne $PayloadFingerprint) {
        return [PSCustomObject]@{
            Allowed = $false
            Action  = 'BLOCK'
            Reason  = 'PAYLOAD_MISMATCH'
            Status  = $job.Status
        }
    }

    switch ($job.Status) {
        'FAILED' {
    if ($job.SendStarted) {
        return [PSCustomObject]@{
            Allowed = $false
            Action  = 'BLOCK'
            Reason  = 'FAILED_WITH_SEND_STARTED'
            Status  = $job.Status
        }
    }

    return [PSCustomObject]@{
        Allowed = $true
        Action  = 'RETRY'
        Reason  = 'Previous attempt failed before send started.'
        Status  = $job.Status
    }
}

        'UNKNOWN' {
            return [PSCustomObject]@{
                Allowed = $false
                Action  = 'BLOCK'
                Reason  = 'UNKNOWN'
                Status  = $job.Status
            }
        }

        'COMPLETED' {
            return [PSCustomObject]@{
                Allowed = $false
                Action  = 'BLOCK'
                Reason  = 'COMPLETED'
                Status  = $job.Status
            }
        }

        'SENDING' {
            return [PSCustomObject]@{
                Allowed = $false
                Action  = 'BLOCK'
                Reason  = 'SENDING'
                Status  = $job.Status
            }
        }

        'QUEUED' {
            return [PSCustomObject]@{
                Allowed = $false
                Action  = 'BLOCK'
                Reason  = 'QUEUED'
                Status  = $job.Status
            }
        }

        default {
            return [PSCustomObject]@{
                Allowed = $false
                Action  = 'BLOCK'
                Reason  = "UNEXPECTED_STATUS:$($job.Status)"
                Status  = $job.Status
            }
        }
    }
}

function New-PrintJobStoreJob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DatabasePath,

        [Parameter(Mandatory)]
        [string]$JobId,

        [Parameter(Mandatory)]
        [string]$ProcessId,

        [Parameter(Mandatory)]
        [string]$PayloadFingerprint,

        [AllowNull()]
        [string]$SqlitePath = $null
    )

    if ([string]::IsNullOrWhiteSpace($JobId)) {
        throw "JobId cannot be empty."
    }

    if ($ProcessId -notmatch '^\d{4}$') {
        throw "ProcessId must contain exactly 4 digits."
    }

    if ($PayloadFingerprint -notmatch '^[0-9A-Fa-f]{64}$') {
        throw "PayloadFingerprint must be a 64-character SHA-256 hexadecimal string."
    }

    $safeJobId = $JobId.Replace("'", "''")
    $safeProcessId = $ProcessId.Replace("'", "''")
    $safeFingerprint = $PayloadFingerprint.ToLowerInvariant()

    $nowUtc = [DateTime]::UtcNow.ToString(
        "yyyy-MM-ddTHH:mm:ss.fffZ",
        [System.Globalization.CultureInfo]::InvariantCulture
    )

    $sql = @"
PRAGMA foreign_keys = ON;
PRAGMA busy_timeout = 5000;

BEGIN IMMEDIATE;

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
    '$safeJobId',
    '$safeProcessId',
    '$safeFingerprint',
    'QUEUED',
    0,
    0,
    0,
    0,
    '$nowUtc',
    '$nowUtc'
);

INSERT INTO job_events (
    JobId,
    EventType,
    FromStatus,
    ToStatus,
    Attempt,
    Message,
    CreatedAtUtc
)
VALUES (
    '$safeJobId',
    'CREATED',
    NULL,
    'QUEUED',
    0,
    'Job created',
    '$nowUtc'
);

COMMIT;
"@

    Invoke-PrintJobStoreSqlite `
        -DatabasePath $DatabasePath `
        -Sql $sql `
        -SqlitePath $SqlitePath | Out-Null

    return Get-PrintJobStoreJob `
        -DatabasePath $DatabasePath `
        -JobId $JobId `
        -SqlitePath $SqlitePath
}

function Start-PrintJobStoreAttempt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DatabasePath,

        [Parameter(Mandatory)]
        [string]$JobId,

        [AllowNull()]
        [string]$SqlitePath = $null
    )

    if ([string]::IsNullOrWhiteSpace($JobId)) {
        throw "JobId cannot be empty."
    }

    $safeJobId = $JobId.Replace("'", "''")

    $nowUtc = [DateTime]::UtcNow.ToString(
        "yyyy-MM-ddTHH:mm:ss.fffZ",
        [System.Globalization.CultureInfo]::InvariantCulture
    )

    $sql = @"
PRAGMA foreign_keys = ON;
PRAGMA busy_timeout = 5000;

BEGIN IMMEDIATE;

CREATE TEMP TABLE IF NOT EXISTS _pg_changes (
    Changed INTEGER NOT NULL
);

DELETE FROM _pg_changes;

UPDATE print_jobs
SET
    Status = 'SENDING',
    Attempt = Attempt + 1,
    SendStarted = 0,
    AckReceived = 0,
    AckValid = 0,
    ReturnedProcessId = NULL,
    AckBytesHex = NULL,
    AckElapsedMs = NULL,
    LastError = NULL,
    CompletedAtUtc = NULL,
    UpdatedAtUtc = '$nowUtc'
WHERE
    JobId = '$safeJobId'
    AND Status = 'QUEUED';

INSERT INTO _pg_changes (Changed)
VALUES (changes());

INSERT INTO job_events (
    JobId,
    EventType,
    FromStatus,
    ToStatus,
    Attempt,
    Message,
    CreatedAtUtc
)
SELECT
    JobId,
    'STARTED',
    'QUEUED',
    'SENDING',
    Attempt,
    'Print attempt started',
    '$nowUtc'
FROM print_jobs
WHERE
    JobId = '$safeJobId'
    AND (SELECT Changed FROM _pg_changes) = 1;

SELECT Changed FROM _pg_changes;

COMMIT;
"@

    $result = @(
        Invoke-PrintJobStoreSqlite `
            -DatabasePath $DatabasePath `
            -Sql $sql `
            -SqlitePath $SqlitePath
    )

    # PRAGMA busy_timeout may output 5000.
    # SELECT Changed FROM _pg_changes must therefore be the last non-empty output row.
    $rows = @($result | Where-Object { $_ -ne $null -and "$_".Trim().Length -gt 0 })

    if ($rows.Count -eq 0) {
        throw "SQLite returned no result for Start-PrintJobStoreAttempt."
    }

    $changed = 0
    if (-not [int]::TryParse("$($rows[-1])", [ref]$changed)) {
        throw "Unable to parse SQLite changes() result: $($rows[-1])"
    }

    if ($changed -ne 1) {
        throw "Job '$JobId' could not transition from QUEUED to SENDING."
    }

    return Get-PrintJobStoreJob `
        -DatabasePath $DatabasePath `
        -JobId $JobId `
        -SqlitePath $SqlitePath
}

function Complete-PrintJobStoreAttempt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DatabasePath,

        [Parameter(Mandatory)]
        [string]$JobId,

        [Parameter(Mandatory)]
        [ValidateSet('FAILED','UNKNOWN','COMPLETED')]
        [string]$TransportStatus,

        [bool]$SendStarted = $false,
        [bool]$AckReceived = $false,
        [bool]$AckValid = $false,

        [AllowNull()]
        [string]$ReturnedProcessId,

        [AllowNull()]
        [string]$AckBytesHex,

        [Nullable[int]]$AckElapsedMs,

        [AllowNull()]
        [string]$ErrorMessage,

        [AllowNull()]
        [string]$SqlitePath = $null
    )

    if ([string]::IsNullOrWhiteSpace($JobId)) {
        throw "JobId cannot be empty."
    }

    # Fail-safe normalization:
    # FAILED is valid only when no send has started.
    if ($TransportStatus -eq 'FAILED' -and $SendStarted) {
        $TransportStatus = 'UNKNOWN'
    }

    # COMPLETED requires a valid ACK whose Process ID matches this job.
if ($TransportStatus -eq 'COMPLETED') {
    if (-not $SendStarted -or -not $AckReceived -or -not $AckValid) {
        $TransportStatus = 'UNKNOWN'
    }
    elseif ($ReturnedProcessId -notmatch '^\d{4}$') {
        $TransportStatus = 'UNKNOWN'
    }
    else {
        $currentJob = Get-PrintJobStoreJob `
            -DatabasePath $DatabasePath `
            -JobId $JobId `
            -SqlitePath $SqlitePath

        if ($null -eq $currentJob) {
            throw "Job '$JobId' was not found."
        }

        if ($ReturnedProcessId -ne $currentJob.ProcessId) {
            $TransportStatus = 'UNKNOWN'

            if ([string]::IsNullOrWhiteSpace($ErrorMessage)) {
                $ErrorMessage = "Process ID ACK mismatch. Expected $($currentJob.ProcessId), received $ReturnedProcessId."
            }
        }
    }
}

    if ($null -ne $ReturnedProcessId -and
        $ReturnedProcessId -ne '' -and
        $ReturnedProcessId -notmatch '^\d{4}$') {
        throw "ReturnedProcessId must contain exactly 4 digits when supplied."
    }

    if ($null -ne $AckElapsedMs -and $AckElapsedMs -lt 0) {
        throw "AckElapsedMs cannot be negative."
    }

    $safeJobId = $JobId.Replace("'", "''")

    function ConvertTo-SqlNullableText {
        param([AllowNull()][string]$Value)

        if ($null -eq $Value -or $Value -eq '') {
            return "NULL"
        }

        return "'" + $Value.Replace("'", "''") + "'"
    }

    $sqlReturnedProcessId = ConvertTo-SqlNullableText $ReturnedProcessId
    $sqlAckBytesHex       = ConvertTo-SqlNullableText $AckBytesHex
    $sqlError             = ConvertTo-SqlNullableText $ErrorMessage

    $sqlAckElapsed = if ($null -eq $AckElapsedMs) {
    "NULL"
}
else {
    [Convert]::ToString(
        [int]$AckElapsedMs,
        [System.Globalization.CultureInfo]::InvariantCulture
    )
}

    $sendStartedInt = if ($SendStarted) { 1 } else { 0 }
    $ackReceivedInt = if ($AckReceived) { 1 } else { 0 }
    $ackValidInt    = if ($AckValid) { 1 } else { 0 }

    $nowUtc = [DateTime]::UtcNow.ToString(
        "yyyy-MM-ddTHH:mm:ss.fffZ",
        [System.Globalization.CultureInfo]::InvariantCulture
    )

    $completedAtSql = if ($TransportStatus -eq 'COMPLETED') {
        "'$nowUtc'"
    }
    else {
        "NULL"
    }

    $sql = @"
PRAGMA foreign_keys = ON;
PRAGMA busy_timeout = 5000;

BEGIN IMMEDIATE;

CREATE TEMP TABLE IF NOT EXISTS _pg_changes (
    Changed INTEGER NOT NULL
);

DELETE FROM _pg_changes;

UPDATE print_jobs
SET
    Status = '$TransportStatus',
    SendStarted = $sendStartedInt,
    AckReceived = $ackReceivedInt,
    AckValid = $ackValidInt,
    ReturnedProcessId = $sqlReturnedProcessId,
    AckBytesHex = $sqlAckBytesHex,
    AckElapsedMs = $sqlAckElapsed,
    LastError = $sqlError,
    UpdatedAtUtc = '$nowUtc',
    CompletedAtUtc = $completedAtSql
WHERE
    JobId = '$safeJobId'
    AND Status = 'SENDING';

INSERT INTO _pg_changes (Changed)
VALUES (changes());

INSERT INTO job_events (
    JobId,
    EventType,
    FromStatus,
    ToStatus,
    Attempt,
    Message,
    CreatedAtUtc
)
SELECT
    JobId,
    '$TransportStatus',
    'SENDING',
    '$TransportStatus',
    Attempt,
    CASE
        WHEN '$TransportStatus' = 'COMPLETED' THEN 'Print attempt completed'
        WHEN '$TransportStatus' = 'FAILED' THEN 'Print attempt failed before send'
        ELSE 'Print attempt outcome unknown'
    END,
    '$nowUtc'
FROM print_jobs
WHERE
    JobId = '$safeJobId'
    AND (SELECT Changed FROM _pg_changes) = 1;

SELECT Changed FROM _pg_changes;

COMMIT;
"@

    $result = @(
        Invoke-PrintJobStoreSqlite `
            -DatabasePath $DatabasePath `
            -Sql $sql `
            -SqlitePath $SqlitePath
    )

    $rows = @(
        $result | Where-Object {
            $_ -ne $null -and "$_".Trim().Length -gt 0
        }
    )

    if ($rows.Count -eq 0) {
        throw "SQLite returned no result for Complete-PrintJobStoreAttempt."
    }

    $changed = 0

    if (-not [int]::TryParse("$($rows[-1])", [ref]$changed)) {
        throw "Unable to parse SQLite changes() result: $($rows[-1])"
    }

    if ($changed -ne 1) {
        throw "Job '$JobId' could not transition from SENDING."
    }

    return Get-PrintJobStoreJob `
        -DatabasePath $DatabasePath `
        -JobId $JobId `
        -SqlitePath $SqlitePath
}

function Start-PrintJobStoreRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DatabasePath,

        [Parameter(Mandatory)]
        [string]$JobId,

        [AllowNull()]
        [string]$SqlitePath = $null
    )

    if ([string]::IsNullOrWhiteSpace($JobId)) {
        throw "JobId cannot be empty."
    }

    $safeJobId = $JobId.Replace("'", "''")

    $nowUtc = [DateTime]::UtcNow.ToString(
        "yyyy-MM-ddTHH:mm:ss.fffZ",
        [System.Globalization.CultureInfo]::InvariantCulture
    )

    $sql = @"
PRAGMA foreign_keys = ON;
PRAGMA busy_timeout = 5000;

BEGIN IMMEDIATE;

CREATE TEMP TABLE IF NOT EXISTS _pg_changes (
    Changed INTEGER NOT NULL
);

DELETE FROM _pg_changes;

UPDATE print_jobs
SET
    Status = 'SENDING',
    Attempt = Attempt + 1,
    SendStarted = 0,
    AckReceived = 0,
    AckValid = 0,
    ReturnedProcessId = NULL,
    AckBytesHex = NULL,
    AckElapsedMs = NULL,
    LastError = NULL,
    CompletedAtUtc = NULL,
    UpdatedAtUtc = '$nowUtc'
WHERE
    JobId = '$safeJobId'
    AND Status = 'FAILED'
    AND SendStarted = 0;

INSERT INTO _pg_changes (Changed)
VALUES (changes());

INSERT INTO job_events (
    JobId,
    EventType,
    FromStatus,
    ToStatus,
    Attempt,
    Message,
    CreatedAtUtc
)
SELECT
    JobId,
    'RETRY_STARTED',
    'FAILED',
    'SENDING',
    Attempt,
    'Safe retry started',
    '$nowUtc'
FROM print_jobs
WHERE
    JobId = '$safeJobId'
    AND (SELECT Changed FROM _pg_changes) = 1;

SELECT Changed FROM _pg_changes;

COMMIT;
"@

    $result = @(
        Invoke-PrintJobStoreSqlite `
            -DatabasePath $DatabasePath `
            -Sql $sql `
            -SqlitePath $SqlitePath
    )

    $rows = @(
        $result | Where-Object {
            $_ -ne $null -and "$_".Trim().Length -gt 0
        }
    )

    if ($rows.Count -eq 0) {
        throw "SQLite returned no result for Start-PrintJobStoreRetry."
    }

    $changed = 0

    if (-not [int]::TryParse("$($rows[-1])", [ref]$changed)) {
        throw "Unable to parse SQLite changes() result: $($rows[-1])"
    }

    if ($changed -ne 1) {
        throw "Job '$JobId' is not eligible for safe retry."
    }

    return Get-PrintJobStoreJob `
        -DatabasePath $DatabasePath `
        -JobId $JobId `
        -SqlitePath $SqlitePath
}

function Recover-PrintJobStoreSendingJob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DatabasePath,

        [Parameter(Mandatory)]
        [string]$JobId,

        [string]$Reason = 'Recovered stale SENDING after service restart; delivery outcome unknown.',

        [AllowNull()]
        [string]$SqlitePath = $null
    )

    if ([string]::IsNullOrWhiteSpace($JobId)) {
        throw 'JobId must not be empty.'
    }

    if ([string]::IsNullOrWhiteSpace($Reason)) {
        throw 'Reason must not be empty.'
    }

    $escapedJobId = $JobId.Replace("'", "''")
    $escapedReason = $Reason.Replace("'", "''")
    $nowUtc = [DateTime]::UtcNow.ToString(
        'yyyy-MM-ddTHH:mm:ss.fffZ',
        [System.Globalization.CultureInfo]::InvariantCulture
    )

    $sql = @"
PRAGMA foreign_keys = ON;
PRAGMA busy_timeout = 5000;

BEGIN IMMEDIATE;

CREATE TEMP TABLE IF NOT EXISTS _pg_changes (
    Changed INTEGER NOT NULL
);

DELETE FROM _pg_changes;

UPDATE print_jobs
SET
    Status = 'UNKNOWN',
    LastError = '$escapedReason',
    CompletedAtUtc = NULL,
    UpdatedAtUtc = '$nowUtc'
WHERE
    JobId = '$escapedJobId'
    AND Status = 'SENDING';

INSERT INTO _pg_changes (Changed)
VALUES (changes());

INSERT INTO job_events (
    JobId,
    EventType,
    FromStatus,
    ToStatus,
    Attempt,
    Message,
    CreatedAtUtc
)
SELECT
    JobId,
    'RECOVERED_STALE_SENDING',
    'SENDING',
    'UNKNOWN',
    Attempt,
    '$escapedReason',
    '$nowUtc'
FROM print_jobs
WHERE
    JobId = '$escapedJobId'
    AND (SELECT Changed FROM _pg_changes) = 1;

SELECT Changed FROM _pg_changes;

COMMIT;
"@

    $output = @(
        Invoke-PrintJobStoreSqlite `
            -DatabasePath $DatabasePath `
            -Sql $sql `
            -SqlitePath $SqlitePath
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }

    $changed = 0

    if (
        $output.Count -eq 0 -or
        -not [int]::TryParse(
            [string]$output[-1],
            [ref]$changed
        )
    ) {
        throw "Could not determine recovery result for Job '$JobId'."
    }

    if ($changed -ne 1) {
        throw "Job '$JobId' is not eligible for SENDING recovery."
    }

    return Get-PrintJobStoreJob `
        -DatabasePath $DatabasePath `
        -JobId $JobId `
        -SqlitePath $SqlitePath
}

function Recover-PrintJobStoreSendingJobs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DatabasePath,

        [string]$Reason = 'Recovered stale SENDING after service restart; delivery outcome unknown.',

        [AllowNull()]
        [string]$SqlitePath = $null
    )

    if ([string]::IsNullOrWhiteSpace($Reason)) {
        throw 'Reason must not be empty.'
    }

    $escapedReason = $Reason.Replace("'", "''")
    $nowUtc = [DateTime]::UtcNow.ToString(
        'yyyy-MM-ddTHH:mm:ss.fffZ',
        [System.Globalization.CultureInfo]::InvariantCulture
    )

    $sql = @"
PRAGMA foreign_keys = ON;
PRAGMA busy_timeout = 5000;

BEGIN IMMEDIATE;

CREATE TEMP TABLE IF NOT EXISTS _pg_recovery_candidates (
    JobId TEXT PRIMARY KEY
);

CREATE TEMP TABLE IF NOT EXISTS _pg_changes (
    Changed INTEGER NOT NULL
);

DELETE FROM _pg_recovery_candidates;
DELETE FROM _pg_changes;

INSERT INTO _pg_recovery_candidates (JobId)
SELECT JobId
FROM print_jobs
WHERE Status = 'SENDING';

UPDATE print_jobs
SET
    Status = 'UNKNOWN',
    LastError = '$escapedReason',
    CompletedAtUtc = NULL,
    UpdatedAtUtc = '$nowUtc'
WHERE
    Status = 'SENDING'
    AND JobId IN (
        SELECT JobId FROM _pg_recovery_candidates
    );

INSERT INTO _pg_changes (Changed)
VALUES (changes());

INSERT INTO job_events (
    JobId,
    EventType,
    FromStatus,
    ToStatus,
    Attempt,
    Message,
    CreatedAtUtc
)
SELECT
    print_jobs.JobId,
    'RECOVERED_STALE_SENDING',
    'SENDING',
    'UNKNOWN',
    print_jobs.Attempt,
    '$escapedReason',
    '$nowUtc'
FROM print_jobs
INNER JOIN _pg_recovery_candidates
    ON _pg_recovery_candidates.JobId = print_jobs.JobId;

SELECT Changed FROM _pg_changes;

COMMIT;
"@

    $result = @(
        Invoke-PrintJobStoreSqlite `
            -DatabasePath $DatabasePath `
            -Sql $sql `
            -SqlitePath $SqlitePath
    )

    $rows = @(
        $result | Where-Object {
            $_ -ne $null -and "$_".Trim().Length -gt 0
        }
    )

    if ($rows.Count -eq 0) {
        throw 'SQLite returned no result for Recover-PrintJobStoreSendingJobs.'
    }

    $changed = 0

    if (-not [int]::TryParse("$($rows[-1])", [ref]$changed)) {
        throw "Unable to parse SQLite changes() result: $($rows[-1])"
    }

    return $changed
}
