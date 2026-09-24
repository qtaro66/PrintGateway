[CmdletBinding()]
param(
    [string]$DatabasePath = 'C:\PrintGateway\Data\printgateway.db',

    [string]$SchemaPath = 'C:\PrintGateway\Data\schema.sql',

    [AllowNull()]
    [string]$SqlitePath = $null,

    [switch]$ValidateExisting
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$storePath = 'C:\PrintGateway\Lib\PrintJobStore.ps1'
$temporaryDatabasePath = $null

function Test-PrintGatewayDatabaseSchema {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$ResolvedSqlitePath
    )

    $validationSql = @"
PRAGMA foreign_keys = ON;

SELECT
    (SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name IN ('print_jobs', 'job_events')),
    (SELECT COUNT(*) FROM pragma_table_info('print_jobs') WHERE name IN (
        'JobId', 'ProcessId', 'PayloadFingerprint', 'Status', 'Attempt',
        'SendStarted', 'AckReceived', 'AckValid', 'ReturnedProcessId',
        'AckBytesHex', 'AckElapsedMs', 'LastError', 'CreatedAtUtc',
        'UpdatedAtUtc', 'CompletedAtUtc'
    )),
    (SELECT COUNT(*) FROM pragma_table_info('job_events') WHERE name IN (
        'EventId', 'JobId', 'EventType', 'FromStatus', 'ToStatus',
        'Attempt', 'Message', 'CreatedAtUtc'
    )),
    (SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name IN (
        'idx_print_jobs_status',
        'idx_print_jobs_process_id',
        'idx_print_jobs_payload_fingerprint',
        'idx_print_jobs_updated_at',
        'idx_job_events_job_id',
        'idx_job_events_created_at'
    )),
    (SELECT COUNT(*) FROM pragma_foreign_key_list('job_events')
        WHERE "table" = 'print_jobs' AND "from" = 'JobId' AND "to" = 'JobId'),
    (SELECT integrity_check FROM pragma_integrity_check LIMIT 1);

PRAGMA foreign_key_check;
"@

    $output = @(
        & $ResolvedSqlitePath `
            -batch `
            -noheader `
            -separator "`t" `
            $Path `
            $validationSql 2>&1
    )

    if ($LASTEXITCODE -ne 0) {
        throw "Database validation failed: $($output -join [Environment]::NewLine)"
    }

    $rows = @($output | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_)
    })

    if ($rows.Count -ne 1) {
        throw "Database validation returned unexpected output: $($rows -join [Environment]::NewLine)"
    }

    $columns = $rows[0] -split "`t"

    if ($columns.Count -ne 6 -or
        $columns[0] -ne '2' -or
        $columns[1] -ne '15' -or
        $columns[2] -ne '8' -or
        $columns[3] -ne '6' -or
        $columns[4] -ne '1' -or
        $columns[5] -ne 'ok') {
        throw "Database schema validation failed: $($rows[0])"
    }

    return $true
}

if (-not (Test-Path -LiteralPath $storePath -PathType Leaf)) {
    throw "Print job store library not found: $storePath"
}

if (-not (Test-Path -LiteralPath $SchemaPath -PathType Leaf)) {
    throw "Schema file not found: $SchemaPath"
}

. $storePath

$resolvedDatabasePath = [System.IO.Path]::GetFullPath($DatabasePath)
$resolvedSchemaPath = [System.IO.Path]::GetFullPath($SchemaPath)
$resolvedSqlitePath = Resolve-PrintGatewaySqlitePath -SqlitePath $SqlitePath
$databaseDirectory = [System.IO.Path]::GetDirectoryName($resolvedDatabasePath)

if (-not (Test-Path -LiteralPath $databaseDirectory -PathType Container)) {
    throw "Database directory not found: $databaseDirectory"
}

if (Test-Path -LiteralPath $resolvedDatabasePath) {
    if (-not $ValidateExisting) {
        throw "Database already exists; refusing to overwrite: $resolvedDatabasePath"
    }

    Test-PrintGatewayDatabaseSchema `
        -Path $resolvedDatabasePath `
        -ResolvedSqlitePath $resolvedSqlitePath | Out-Null

    return [PSCustomObject]@{
        DatabasePath = $resolvedDatabasePath
        SchemaPath   = $resolvedSchemaPath
        SqlitePath   = $resolvedSqlitePath
        Created      = $false
        Valid        = $true
    }
}

$temporaryDatabasePath = Join-Path `
    $databaseDirectory `
    ('.{0}.provisioning-{1}.tmp' -f
        [System.IO.Path]::GetFileName($resolvedDatabasePath),
        [Guid]::NewGuid().ToString('N'))

try {
    New-Item -ItemType File -Path $temporaryDatabasePath -ErrorAction Stop | Out-Null

    $schemaSql = Get-Content -LiteralPath $resolvedSchemaPath -Raw
    $schemaOutput = @(
        & $resolvedSqlitePath `
            -batch `
            $temporaryDatabasePath `
            $schemaSql 2>&1
    )

    if ($LASTEXITCODE -ne 0) {
        throw "Schema application failed: $($schemaOutput -join [Environment]::NewLine)"
    }

    Test-PrintGatewayDatabaseSchema `
        -Path $temporaryDatabasePath `
        -ResolvedSqlitePath $resolvedSqlitePath | Out-Null

    if (Test-Path -LiteralPath $resolvedDatabasePath) {
        throw "Database appeared during provisioning; refusing to overwrite: $resolvedDatabasePath"
    }

    [System.IO.File]::Move(
        $temporaryDatabasePath,
        $resolvedDatabasePath,
        $false
    )

    $temporaryDatabasePath = $null

    return [PSCustomObject]@{
        DatabasePath = $resolvedDatabasePath
        SchemaPath   = $resolvedSchemaPath
        SqlitePath   = $resolvedSqlitePath
        Created      = $true
        Valid        = $true
    }
}
finally {
    if ($null -ne $temporaryDatabasePath -and
        (Test-Path -LiteralPath $temporaryDatabasePath -PathType Leaf)) {
        Remove-Item -LiteralPath $temporaryDatabasePath -Force
    }
}
