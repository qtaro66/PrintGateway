Set-StrictMode -Version Latest

# PrintGateway durable job manager.
# SQLite is the only source of truth; all transitions remain in PrintJobStore.ps1.

$storeLibraryPath = Join-Path $PSScriptRoot 'PrintJobStore.ps1'

if (-not (Test-Path -LiteralPath $storeLibraryPath)) {
    throw "Print job store library not found: $storeLibraryPath"
}

. $storeLibraryPath

$existingMutex = Get-Variable `
    -Scope Script `
    -Name PrintGatewayWorkerMutex `
    -ErrorAction SilentlyContinue

$existingMutexOwned = Get-Variable `
    -Scope Script `
    -Name PrintGatewayWorkerMutexOwned `
    -ErrorAction SilentlyContinue

if ($null -ne $existingMutex -and $null -ne $existingMutex.Value) {
    if ($null -ne $existingMutexOwned -and $existingMutexOwned.Value) {
        try {
            $existingMutex.Value.ReleaseMutex()
        }
        catch [System.ApplicationException] {
            # The current thread did not own this stale handle.
        }
    }

    $existingMutex.Value.Dispose()
}

$script:PrintGatewayJobDatabasePath = $null
$script:PrintGatewaySqlitePath = $null
$script:PrintGatewayWorkerMutex = $null
$script:PrintGatewayWorkerMutexOwned = $false
$script:PrintGatewayWorkerMutexName = $null

function Initialize-PrintGatewayJobManager {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DatabasePath,

        [AllowNull()]
        [string]$SqlitePath = $null,

        [string]$WorkerMutexName = 'Global\PrintGateway_ExclusiveWorker'
    )

    if (-not (Test-Path -LiteralPath $DatabasePath -PathType Leaf)) {
        throw "PrintGateway database not found: $DatabasePath"
    }

    if ([string]::IsNullOrWhiteSpace($WorkerMutexName)) {
        throw 'WorkerMutexName must not be empty.'
    }

    $SqlitePath = Resolve-PrintGatewaySqlitePath -SqlitePath $SqlitePath

    $schemaCheck = @(
        Invoke-PrintJobStoreSqlite `
            -DatabasePath $DatabasePath `
            -Sql @"
SELECT
    CASE
        WHEN EXISTS (
            SELECT 1 FROM sqlite_master
            WHERE type = 'table' AND name = 'print_jobs'
        )
        AND EXISTS (
            SELECT 1 FROM sqlite_master
            WHERE type = 'table' AND name = 'job_events'
        )
        THEN 1
        ELSE 0
    END;
"@ `
            -SqlitePath $SqlitePath |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
    )

    if ($schemaCheck.Count -eq 0 -or [string]$schemaCheck[-1] -ne '1') {
        throw "Database does not contain the required PrintGateway schema: $DatabasePath"
    }

    $createdNew = $false
    $workerMutex = [System.Threading.Mutex]::new(
        $true,
        $WorkerMutexName,
        [ref]$createdNew
    )

    $mutexAcquired = $createdNew

    if (-not $createdNew) {
        try {
            $mutexAcquired = $workerMutex.WaitOne(0)
        }
        catch [System.Threading.AbandonedMutexException] {
            $mutexAcquired = $true
        }
    }

    if (-not $mutexAcquired) {
        $workerMutex.Dispose()
        throw "Another PrintGateway worker owns mutex '$WorkerMutexName'. Startup and recovery were blocked."
    }

    $script:PrintGatewayJobDatabasePath = [System.IO.Path]::GetFullPath($DatabasePath)
    $script:PrintGatewaySqlitePath = [System.IO.Path]::GetFullPath($SqlitePath)
    $script:PrintGatewayWorkerMutex = $workerMutex
    $script:PrintGatewayWorkerMutexOwned = $true
    $script:PrintGatewayWorkerMutexName = $WorkerMutexName

    return [PSCustomObject]@{
        DatabasePath = $script:PrintGatewayJobDatabasePath
        SqlitePath   = $script:PrintGatewaySqlitePath
        Store        = 'SQLite'
        WorkerMutex  = $script:PrintGatewayWorkerMutexName
    }
}

function Close-PrintGatewayJobManager {
    [CmdletBinding()]
    param()

    if ($null -ne $script:PrintGatewayWorkerMutex) {
        if ($script:PrintGatewayWorkerMutexOwned) {
            try {
                $script:PrintGatewayWorkerMutex.ReleaseMutex()
            }
            catch [System.ApplicationException] {
                # The mutex was not owned by the current thread.
            }
        }

        $script:PrintGatewayWorkerMutex.Dispose()
    }

    $script:PrintGatewayJobDatabasePath = $null
    $script:PrintGatewaySqlitePath = $null
    $script:PrintGatewayWorkerMutex = $null
    $script:PrintGatewayWorkerMutexOwned = $false
    $script:PrintGatewayWorkerMutexName = $null
}

function Get-PrintGatewayJobManagerConnection {
    [CmdletBinding()]
    param()

    if ([string]::IsNullOrWhiteSpace($script:PrintGatewayJobDatabasePath) -or
        [string]::IsNullOrWhiteSpace($script:PrintGatewaySqlitePath)) {
        throw 'PrintGateway job manager is not initialized. Call Initialize-PrintGatewayJobManager first.'
    }

    return [PSCustomObject]@{
        DatabasePath = $script:PrintGatewayJobDatabasePath
        SqlitePath   = $script:PrintGatewaySqlitePath
    }
}

function Get-PrintGatewayPayloadFingerprint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [byte[]]$Bytes
    )

    $sha256 = [System.Security.Cryptography.SHA256]::Create()

    try {
        $hash = $sha256.ComputeHash($Bytes)
        return ([System.BitConverter]::ToString($hash)).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

function Get-PrintGatewayJob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$JobId
    )

    $connection = Get-PrintGatewayJobManagerConnection

    return Get-PrintJobStoreJob `
        -DatabasePath $connection.DatabasePath `
        -JobId $JobId `
        -SqlitePath $connection.SqlitePath
}

function Test-PrintGatewayJobSubmission {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$JobId,

        [Parameter(Mandatory)]
        [string]$ProcessId,

        [Parameter(Mandatory)]
        [string]$PayloadFingerprint
    )

    $connection = Get-PrintGatewayJobManagerConnection

    return Test-PrintJobStoreSubmission `
        -DatabasePath $connection.DatabasePath `
        -JobId $JobId `
        -ProcessId $ProcessId `
        -PayloadFingerprint $PayloadFingerprint `
        -SqlitePath $connection.SqlitePath
}

function New-PrintGatewayJob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$JobId,

        [Parameter(Mandatory)]
        [string]$ProcessId,

        [Parameter(Mandatory)]
        [string]$PayloadFingerprint
    )

    $connection = Get-PrintGatewayJobManagerConnection

    return New-PrintJobStoreJob `
        -DatabasePath $connection.DatabasePath `
        -JobId $JobId `
        -ProcessId $ProcessId `
        -PayloadFingerprint $PayloadFingerprint `
        -SqlitePath $connection.SqlitePath
}

function Start-PrintGatewayJobAttempt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$JobId
    )

    $connection = Get-PrintGatewayJobManagerConnection
    $job = Get-PrintJobStoreJob `
        -DatabasePath $connection.DatabasePath `
        -JobId $JobId `
        -SqlitePath $connection.SqlitePath

    if ($null -eq $job) {
        throw "Job not found: $JobId"
    }

    switch ($job.Status) {
        'QUEUED' {
            return Start-PrintJobStoreAttempt `
                -DatabasePath $connection.DatabasePath `
                -JobId $JobId `
                -SqlitePath $connection.SqlitePath
        }

        'FAILED' {
            return Start-PrintJobStoreRetry `
                -DatabasePath $connection.DatabasePath `
                -JobId $JobId `
                -SqlitePath $connection.SqlitePath
        }

        default {
            throw "Job '$JobId' cannot start from status '$($job.Status)'."
        }
    }
}

function Complete-PrintGatewayJobAttempt {
    [CmdletBinding()]
    param(
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
        [string]$ErrorMessage
    )

    $connection = Get-PrintGatewayJobManagerConnection

    return Complete-PrintJobStoreAttempt `
        -DatabasePath $connection.DatabasePath `
        -JobId $JobId `
        -TransportStatus $TransportStatus `
        -SendStarted:$SendStarted `
        -AckReceived:$AckReceived `
        -AckValid:$AckValid `
        -ReturnedProcessId $ReturnedProcessId `
        -AckBytesHex $AckBytesHex `
        -AckElapsedMs $AckElapsedMs `
        -ErrorMessage $ErrorMessage `
        -SqlitePath $connection.SqlitePath
}

function Complete-PrintGatewayJobFromTransportResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$JobId,

        [Parameter(Mandatory)]
        [psobject]$TransportResult
    )

    $propertyNames = @($TransportResult.PSObject.Properties.Name)

    foreach ($requiredProperty in @(
        'TransportStatus',
        'SendStarted',
        'AckReceived',
        'AckValid'
    )) {
        if ($requiredProperty -notin $propertyNames) {
            throw "Transport result is missing required property '$requiredProperty'."
        }
    }

    $transportStatus = [string]$TransportResult.TransportStatus
    $errorMessage = if ('Error' -in $propertyNames) {
        [string]$TransportResult.Error
    }
    else {
        $null
    }

    if ($transportStatus -notin @('FAILED', 'UNKNOWN', 'COMPLETED')) {
        $errorMessage = "Unexpected TransportStatus: $transportStatus"
        $transportStatus = 'UNKNOWN'
    }

    $returnedProcessId = if ('ReturnedProcessId' -in $propertyNames) {
        $TransportResult.ReturnedProcessId
    }
    else {
        $null
    }

    $ackElapsedMs = if ('AckElapsedMs' -in $propertyNames) {
        $TransportResult.AckElapsedMs
    }
    else {
        $null
    }

    $ackBytesHex = $null

    if ('AckBytes' -in $propertyNames -and $null -ne $TransportResult.AckBytes) {
        $ackBytesHex = @(
            [byte[]]$TransportResult.AckBytes |
                ForEach-Object { '{0:X2}' -f $_ }
        ) -join ''

        if ($ackBytesHex.Length -eq 0) {
            $ackBytesHex = $null
        }
    }

    return Complete-PrintGatewayJobAttempt `
        -JobId $JobId `
        -TransportStatus $transportStatus `
        -SendStarted:([bool]$TransportResult.SendStarted) `
        -AckReceived:([bool]$TransportResult.AckReceived) `
        -AckValid:([bool]$TransportResult.AckValid) `
        -ReturnedProcessId $returnedProcessId `
        -AckBytesHex $ackBytesHex `
        -AckElapsedMs $ackElapsedMs `
        -ErrorMessage $errorMessage
}

function Recover-PrintGatewaySendingJob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$JobId,

        [string]$Reason = 'Recovered stale SENDING after service restart; delivery outcome unknown.'
    )

    $connection = Get-PrintGatewayJobManagerConnection

    return Recover-PrintJobStoreSendingJob `
        -DatabasePath $connection.DatabasePath `
        -JobId $JobId `
        -Reason $Reason `
        -SqlitePath $connection.SqlitePath
}

function Recover-PrintGatewaySendingJobs {
    [CmdletBinding()]
    param(
        [string]$Reason = 'Recovered stale SENDING after service restart; delivery outcome unknown.'
    )

    $connection = Get-PrintGatewayJobManagerConnection

    return Recover-PrintJobStoreSendingJobs `
        -DatabasePath $connection.DatabasePath `
        -Reason $Reason `
        -SqlitePath $connection.SqlitePath
}

Write-Verbose 'Durable PrintJobManager library loaded.'
