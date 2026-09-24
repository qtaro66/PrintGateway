Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$managerPath = 'C:\PrintGateway\Lib\PrintJobManager.ps1'
$schemaPath = 'C:\PrintGateway\Data\schema.sql'
$sqlitePath = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\sqlite3.exe'
$workDirectory = 'C:\PrintGateway\Tests\work'
$databasePath = Join-Path $workDirectory ("B19C-{0}.db" -f [Guid]::NewGuid().ToString('N'))

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

function Invoke-ChildPowerShell {
    param(
        [Parameter(Mandatory)]
        [string]$Script
    )

    $encoded = [Convert]::ToBase64String(
        [Text.Encoding]::Unicode.GetBytes($Script)
    )

    $output = @(
        & pwsh `
            -NoProfile `
            -NonInteractive `
            -OutputFormat Text `
            -EncodedCommand $encoded 2>&1
    )

    if ($LASTEXITCODE -ne 0) {
        throw "Child PowerShell failed: $($output -join [Environment]::NewLine)"
    }

    return @($output | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_)
    })
}

foreach ($requiredPath in @($managerPath, $schemaPath, $sqlitePath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Required file not found: $requiredPath"
    }
}

if ($null -eq (Get-Command pwsh -ErrorAction SilentlyContinue)) {
    throw 'pwsh executable was not found.'
}

New-Item -ItemType Directory -Path $workDirectory -Force | Out-Null
New-Item -ItemType File -Path $databasePath -Force | Out-Null

try {
    Invoke-TestSql -Sql (Get-Content -LiteralPath $schemaPath -Raw) | Out-Null

    $jobId = 'B19C-RESTART-001'
    $processId = '6401'
    $fingerprint = 'e' * 64

    $firstProcessOutput = @(
        Invoke-ChildPowerShell -Script @"
`$ErrorActionPreference = 'Stop'
. '$managerPath'
Initialize-PrintGatewayJobManager -DatabasePath '$databasePath' -SqlitePath '$sqlitePath' | Out-Null
New-PrintGatewayJob -JobId '$jobId' -ProcessId '$processId' -PayloadFingerprint '$fingerprint' | Out-Null
`$job = Start-PrintGatewayJobAttempt -JobId '$jobId'
Write-Output "FIRST|`$(`$job.Status)|`$(`$job.Attempt)"
"@
    )

    Assert-Equal -Name 'first process output count' -Expected 1 -Actual $firstProcessOutput.Count
    Assert-Equal -Name 'first process left SENDING' -Expected 'FIRST|SENDING|1' -Actual $firstProcessOutput[0]

    $persistedBeforeRestart = @(
        Invoke-TestSql -Sql "SELECT Status, Attempt FROM print_jobs WHERE JobId = '$jobId';"
    )[-1]

    Assert-Equal -Name 'SENDING persisted after first process exit' -Expected "SENDING`t1" -Actual $persistedBeforeRestart

    $secondProcessOutput = @(
        Invoke-ChildPowerShell -Script @"
`$ErrorActionPreference = 'Stop'
. '$managerPath'
Initialize-PrintGatewayJobManager -DatabasePath '$databasePath' -SqlitePath '$sqlitePath' | Out-Null
`$recovered = Recover-PrintGatewaySendingJobs
`$job = Get-PrintGatewayJob -JobId '$jobId'
`$submission = Test-PrintGatewayJobSubmission -JobId '$jobId' -ProcessId '$processId' -PayloadFingerprint '$fingerprint'
Write-Output "SECOND|`$recovered|`$(`$job.Status)|`$(`$job.Attempt)|`$(`$submission.Allowed)|`$(`$submission.Reason)"
"@
    )

    Assert-Equal -Name 'second process output count' -Expected 1 -Actual $secondProcessOutput.Count
    Assert-Equal `
        -Name 'restart recovery result' `
        -Expected 'SECOND|1|UNKNOWN|1|False|UNKNOWN' `
        -Actual $secondProcessOutput[0]

    $thirdProcessOutput = @(
        Invoke-ChildPowerShell -Script @"
`$ErrorActionPreference = 'Stop'
. '$managerPath'
Initialize-PrintGatewayJobManager -DatabasePath '$databasePath' -SqlitePath '$sqlitePath' | Out-Null
`$recovered = Recover-PrintGatewaySendingJobs
`$job = Get-PrintGatewayJob -JobId '$jobId'
Write-Output "THIRD|`$recovered|`$(`$job.Status)|`$(`$job.Attempt)"
"@
    )

    Assert-Equal -Name 'third process output count' -Expected 1 -Actual $thirdProcessOutput.Count
    Assert-Equal -Name 'repeated restart is idempotent' -Expected 'THIRD|0|UNKNOWN|1' -Actual $thirdProcessOutput[0]

    $events = @(
        Invoke-TestSql -Sql @"
SELECT EventType, IFNULL(FromStatus, ''), ToStatus, Attempt
FROM job_events
WHERE JobId = '$jobId'
ORDER BY EventId;
"@
    )

    Assert-Equal -Name 'restart audit event count' -Expected 3 -Actual $events.Count
    Assert-Equal -Name 'created event' -Expected "CREATED`t`tQUEUED`t0" -Actual $events[0]
    Assert-Equal -Name 'started event' -Expected "STARTED`tQUEUED`tSENDING`t1" -Actual $events[1]
    Assert-Equal `
        -Name 'recovered event' `
        -Expected "RECOVERED_STALE_SENDING`tSENDING`tUNKNOWN`t1" `
        -Actual $events[2]

    Write-Output 'TEST-0010B-19C: PASS'
    Write-Output 'Verified: cross-process restart recovery, UNKNOWN blocking, and idempotent startup.'
}
finally {
    if (Test-Path -LiteralPath $databasePath) {
        Remove-Item -LiteralPath $databasePath -Force
    }
}
