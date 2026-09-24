[CmdletBinding()]
param(
    [string[]]$LocalAccount = @($env:USERNAME),

    [string]$RuntimeGroup = 'PrintGatewayLocalUsers',

    [string]$DatabasePath = 'C:\PrintGateway\Data\printgateway.db',

    [string]$SchemaPath = 'C:\PrintGateway\Data\schema.sql',

    [AllowNull()]
    [string]$SqlitePath = $null
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$accessTool = 'C:\PrintGateway\Tools\Set-PrintGatewayLocalAccess.ps1'
$databaseTool = 'C:\PrintGateway\Tools\Initialize-PrintGatewayDatabase.ps1'
$preflightTool = 'C:\PrintGateway\Tools\Test-PrintGatewayDeployment.ps1'

$principal = [Security.Principal.WindowsPrincipal]::new(
    [Security.Principal.WindowsIdentity]::GetCurrent()
)

if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Administrator elevation is required. Open PowerShell with Run as administrator and run this script again.'
}

foreach ($tool in @($accessTool, $databaseTool, $preflightTool)) {
    if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) {
        throw "Required deployment tool not found: $tool"
    }
}

$accessResult = & $accessTool `
    -GroupName $RuntimeGroup `
    -LocalAccount $LocalAccount `
    -DataPath ([System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($DatabasePath))) `
    -Apply

$databaseResult = if (Test-Path -LiteralPath $DatabasePath -PathType Leaf) {
    & $databaseTool `
        -DatabasePath $DatabasePath `
        -SchemaPath $SchemaPath `
        -SqlitePath $SqlitePath `
        -ValidateExisting
}
else {
    & $databaseTool `
        -DatabasePath $DatabasePath `
        -SchemaPath $SchemaPath `
        -SqlitePath $SqlitePath
}

$qualifiedPrimaryAccount = if ($LocalAccount[0].Contains('\')) {
    $LocalAccount[0]
}
else {
    "$env:COMPUTERNAME\$($LocalAccount[0])"
}

$preflight = & $preflightTool `
    -DatabasePath $DatabasePath `
    -SchemaPath $SchemaPath `
    -SqlitePath $SqlitePath `
    -ServiceAccount $qualifiedPrimaryAccount `
    -RuntimeGroup $RuntimeGroup

if (-not $preflight.Ready) {
    $failedDetails = @(
        $preflight.Checks |
            Where-Object Status -eq 'FAIL' |
            ForEach-Object { '{0}: {1}' -f $_.Name, $_.Detail }
    ) -join [Environment]::NewLine

    throw "Deployment preflight failed after configuration:$([Environment]::NewLine)$failedDetails"
}

[PSCustomObject]@{
    Ready          = $true
    RuntimeGroup   = $accessResult.Group
    LocalAccounts  = $accessResult.Accounts
    DatabasePath   = $databaseResult.DatabasePath
    DatabaseCreated = $databaseResult.Created
    SqlitePath     = $databaseResult.SqlitePath
    WarningChecks  = $preflight.WarningChecks
    Checks         = $preflight.Checks
}
