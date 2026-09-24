PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS print_jobs (
    JobId               TEXT PRIMARY KEY,
    ProcessId           TEXT NOT NULL,
    PayloadFingerprint  TEXT NOT NULL,

    Status              TEXT NOT NULL
                        CHECK (
                            Status IN (
                                'QUEUED',
                                'SENDING',
                                'FAILED',
                                'UNKNOWN',
                                'COMPLETED'
                            )
                        ),

    Attempt             INTEGER NOT NULL DEFAULT 0
                        CHECK (Attempt >= 0),

    SendStarted         INTEGER NOT NULL DEFAULT 0
                        CHECK (SendStarted IN (0,1)),

    AckReceived         INTEGER NOT NULL DEFAULT 0
                        CHECK (AckReceived IN (0,1)),

    AckValid            INTEGER NOT NULL DEFAULT 0
                        CHECK (AckValid IN (0,1)),

    ReturnedProcessId   TEXT,
    AckBytesHex         TEXT,
    AckElapsedMs        INTEGER
                        CHECK (
                            AckElapsedMs IS NULL
                            OR AckElapsedMs >= 0
                        ),

    LastError           TEXT,

    CreatedAtUtc        TEXT NOT NULL,
    UpdatedAtUtc        TEXT NOT NULL,
    CompletedAtUtc      TEXT,

    CHECK (length(JobId) > 0),

    CHECK (
        length(ProcessId) = 4
        AND ProcessId NOT GLOB '*[^0-9]*'
    ),

    CHECK (length(PayloadFingerprint) = 64),

    CHECK (
        ReturnedProcessId IS NULL
        OR (
            length(ReturnedProcessId) = 4
            AND ReturnedProcessId NOT GLOB '*[^0-9]*'
        )
    ),

    CHECK (
        Status <> 'COMPLETED'
        OR (
            SendStarted = 1
            AND AckReceived = 1
            AND AckValid = 1
            AND ReturnedProcessId = ProcessId
            AND CompletedAtUtc IS NOT NULL
        )
    ),

    CHECK (
        Status <> 'FAILED'
        OR SendStarted = 0
    )
);

CREATE INDEX IF NOT EXISTS idx_print_jobs_status
    ON print_jobs(Status);

CREATE INDEX IF NOT EXISTS idx_print_jobs_process_id
    ON print_jobs(ProcessId);

CREATE INDEX IF NOT EXISTS idx_print_jobs_payload_fingerprint
    ON print_jobs(PayloadFingerprint);

CREATE INDEX IF NOT EXISTS idx_print_jobs_updated_at
    ON print_jobs(UpdatedAtUtc);
    CREATE TABLE IF NOT EXISTS job_events (
    EventId         INTEGER PRIMARY KEY AUTOINCREMENT,
    JobId           TEXT NOT NULL,
    EventType       TEXT NOT NULL,
    FromStatus      TEXT,
    ToStatus        TEXT,
    Attempt         INTEGER NOT NULL,
    Message         TEXT,
    CreatedAtUtc    TEXT NOT NULL,

    FOREIGN KEY (JobId)
        REFERENCES print_jobs(JobId),

    CHECK (length(EventType) > 0),

    CHECK (
        FromStatus IS NULL
        OR FromStatus IN (
            'QUEUED',
            'SENDING',
            'FAILED',
            'UNKNOWN',
            'COMPLETED'
        )
    ),

    CHECK (
        ToStatus IS NULL
        OR ToStatus IN (
            'QUEUED',
            'SENDING',
            'FAILED',
            'UNKNOWN',
            'COMPLETED'
        )
    ),

    CHECK (Attempt >= 0)
);

CREATE INDEX IF NOT EXISTS idx_job_events_job_id
    ON job_events(JobId);

CREATE INDEX IF NOT EXISTS idx_job_events_created_at
    ON job_events(CreatedAtUtc);