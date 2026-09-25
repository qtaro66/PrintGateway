Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$managerPath = 'C:\PrintGateway\Lib\PrintJobManager.ps1'
$schemaPath = 'C:\PrintGateway\Data\schema.sql'
$explicitSqlitePath = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\sqlite3.exe'
$workDirectory = 'C:\PrintGateway\Tests\work'
$databasePath = Join-Path $workDirectory ("B19E-HARDENING-{0}.db" -f [Guid]::NewGuid().ToString('N'))
$mutexName = "Global\PrintGateway_Hardening_{0}" -f [Guid]::NewGuid().ToString('N')
$child = $null

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

foreach ($requiredPath in @($managerPath, $schemaPath, $explicitSqlitePath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Required file not found: $requiredPath"
    }
}

New-Item -ItemType Directory -Path $workDirectory -Force | Out-Null
New-Item -ItemType File -Path $databasePath -Force | Out-Null

try {
    $schemaSql = Get-Content -LiteralPath $schemaPath -Raw
    $schemaOutput = & $explicitSqlitePath -batch $databasePath $schemaSql 2>&1

    if ($LASTEXITCODE -ne 0) {
        throw "Schema initialization failed: $($schemaOutput -join [Environment]::NewLine)"
    }

    . $managerPath

    $resolvedExplicit = Resolve-PrintGatewaySqlitePath -SqlitePath $explicitSqlitePath
    $resolvedAutomatic = Resolve-PrintGatewaySqlitePath

    Assert-Equal `
        -Name 'explicit SQLite resolution' `
        -Expected ([System.IO.Path]::GetFullPath($explicitSqlitePath)) `
        -Actual $resolvedExplicit

    $bundledSqlitePath = 'C:\PrintGateway\Bin\sqlite3.exe'

$pathSqliteCommand = Get-Command `
    sqlite3.exe `
    -CommandType Application `
    -ErrorAction SilentlyContinue |
        Select-Object -First 1

$expectedAutomaticSqlitePath = if (
    Test-Path -LiteralPath $bundledSqlitePath -PathType Leaf
) {
    [System.IO.Path]::GetFullPath($bundledSqlitePath)
}
elseif ($null -ne $pathSqliteCommand) {
    [System.IO.Path]::GetFullPath($pathSqliteCommand.Source)
}
else {
    [System.IO.Path]::GetFullPath($explicitSqlitePath)
}

Assert-Equal `
    -Name 'automatic SQLite resolution follows documented priority' `
    -Expected $expectedAutomaticSqlitePath `
    -Actual $resolvedAutomatic

    $invalidPathWasBlocked = $false

    try {
        Resolve-PrintGatewaySqlitePath `
            -SqlitePath 'C:\PrintGateway\Tests\work\missing-sqlite3.exe' | Out-Null
    }
    catch {
        $invalidPathWasBlocked = $_.Exception.Message -like '*sqlite3.exe not found*'
    }

    Assert-Equal -Name 'invalid explicit SQLite path blocked' -Expected $true -Actual $invalidPathWasBlocked

    $childScript = @"
`$ErrorActionPreference = 'Stop'
. '$managerPath'
Initialize-PrintGatewayJobManager -DatabasePath '$databasePath' -SqlitePath '$explicitSqlitePath' -WorkerMutexName '$mutexName' | Out-Null
[Console]::Out.WriteLine('READY')
[Console]::Out.Flush()
[Console]::In.ReadLine() | Out-Null
Close-PrintGatewayJobManager
"@

    $encodedCommand = [Convert]::ToBase64String(
        [Text.Encoding]::Unicode.GetBytes($childScript)
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $pwshCommand = Get-Command pwsh -CommandType Application -All |
        Select-Object -First 1

    $startInfo.FileName = $pwshCommand.Source
    $startInfo.Arguments = "-NoProfile -NonInteractive -OutputFormat Text -EncodedCommand $encodedCommand"
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true

    $child = [System.Diagnostics.Process]::new()
    $child.StartInfo = $startInfo

    if (-not $child.Start()) {
        throw 'Failed to start mutex-holder process.'
    }

    $ready = $child.StandardOutput.ReadLine()
    Assert-Equal -Name 'mutex holder ready' -Expected 'READY' -Actual $ready

    $secondInstanceWasBlocked = $false

    try {
        Initialize-PrintGatewayJobManager `
            -DatabasePath $databasePath `
            -SqlitePath $explicitSqlitePath `
            -WorkerMutexName $mutexName | Out-Null
    }
    catch {
        $secondInstanceWasBlocked = $_.Exception.Message -like '*Another PrintGateway worker owns mutex*'
    }

    Assert-Equal -Name 'second worker blocked' -Expected $true -Actual $secondInstanceWasBlocked

    $child.StandardInput.WriteLine('EXIT')
    $child.StandardInput.Flush()

    if (-not $child.WaitForExit(10000)) {
        throw 'Mutex-holder process did not exit.'
    }

    if ($child.ExitCode -ne 0) {
        throw "Mutex-holder process failed: $($child.StandardError.ReadToEnd())"
    }

    $child.Dispose()
    $child = $null

    $configuration = Initialize-PrintGatewayJobManager `
        -DatabasePath $databasePath `
        -SqlitePath $explicitSqlitePath `
        -WorkerMutexName $mutexName

    Assert-Equal -Name 'mutex acquired after owner exit' -Expected $mutexName -Actual $configuration.WorkerMutex

    Close-PrintGatewayJobManager

    Write-Output 'TEST-0010B-19E-HARDENING: PASS'
    Write-Output 'Verified: SQLite path resolution and fail-closed single-instance mutex.'
}
finally {
    if ($null -ne $child) {
        try {
            if (-not $child.HasExited) {
                $child.Kill($true)
                $child.WaitForExit()
            }
        }
        catch [System.InvalidOperationException] {
            # The process object was created but no process remained attached.
        }

        $child.Dispose()
    }

    if ($null -ne (Get-Command Close-PrintGatewayJobManager -ErrorAction SilentlyContinue)) {
        Close-PrintGatewayJobManager
    }

    if (Test-Path -LiteralPath $databasePath) {
        Remove-Item -LiteralPath $databasePath -Force
    }
}
