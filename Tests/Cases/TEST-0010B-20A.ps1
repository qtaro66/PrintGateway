Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$provisioningPath = 'C:\PrintGateway\Tools\Initialize-PrintGatewayDatabase.ps1'
$schemaPath = 'C:\PrintGateway\Data\schema.sql'
$sqlitePath = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\sqlite3.exe'
$workDirectory = 'C:\PrintGateway\Tests\work'
$databasePath = Join-Path $workDirectory ("B20A-{0}.db" -f [Guid]::NewGuid().ToString('N'))
$invalidDatabasePath = Join-Path $workDirectory ("B20A-INVALID-{0}.db" -f [Guid]::NewGuid().ToString('N'))

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

foreach ($requiredPath in @($provisioningPath, $schemaPath, $sqlitePath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Required file not found: $requiredPath"
    }
}

New-Item -ItemType Directory -Path $workDirectory -Force | Out-Null

try {
    $created = & $provisioningPath `
        -DatabasePath $databasePath `
        -SchemaPath $schemaPath `
        -SqlitePath $sqlitePath

    Assert-Equal -Name 'database created' -Expected $true -Actual $created.Created
    Assert-Equal -Name 'created database valid' -Expected $true -Actual $created.Valid
    Assert-Equal -Name 'created database exists' -Expected $true -Actual (Test-Path -LiteralPath $databasePath -PathType Leaf)

    $overwriteWasBlocked = $false

    try {
        & $provisioningPath `
            -DatabasePath $databasePath `
            -SchemaPath $schemaPath `
            -SqlitePath $sqlitePath | Out-Null
    }
    catch {
        $overwriteWasBlocked = $_.Exception.Message -like '*refusing to overwrite*'
    }

    Assert-Equal -Name 'existing database overwrite blocked' -Expected $true -Actual $overwriteWasBlocked

    $validated = & $provisioningPath `
        -DatabasePath $databasePath `
        -SchemaPath $schemaPath `
        -SqlitePath $sqlitePath `
        -ValidateExisting

    Assert-Equal -Name 'existing database not recreated' -Expected $false -Actual $validated.Created
    Assert-Equal -Name 'existing database validation' -Expected $true -Actual $validated.Valid

    New-Item -ItemType File -Path $invalidDatabasePath -Force | Out-Null

    $invalidDatabaseWasBlocked = $false

    try {
        & $provisioningPath `
            -DatabasePath $invalidDatabasePath `
            -SchemaPath $schemaPath `
            -SqlitePath $sqlitePath `
            -ValidateExisting | Out-Null
    }
    catch {
        $invalidDatabaseWasBlocked = $_.Exception.Message -like '*schema validation failed*'
    }

    Assert-Equal -Name 'invalid existing database blocked' -Expected $true -Actual $invalidDatabaseWasBlocked

    $temporaryFiles = @(
        Get-ChildItem `
            -LiteralPath $workDirectory `
            -Filter '.B20A-*.provisioning-*.tmp' `
            -File `
            -ErrorAction SilentlyContinue
    )

    Assert-Equal -Name 'no provisioning temporary files' -Expected 0 -Actual $temporaryFiles.Count

    Write-Output 'TEST-0010B-20A: PASS'
    Write-Output 'Verified: atomic database provisioning, validation, and overwrite protection.'
}
finally {
    foreach ($path in @($databasePath, $invalidDatabasePath)) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Remove-Item -LiteralPath $path -Force
        }
    }
}
