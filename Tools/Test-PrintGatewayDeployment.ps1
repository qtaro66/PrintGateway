[CmdletBinding()]
param(
    [string]$DatabasePath = 'C:\PrintGateway\Data\printgateway.db',

    [string]$SchemaPath = 'C:\PrintGateway\Data\schema.sql',

    [AllowNull()]
    [string]$SqlitePath = $null,

    [AllowNull()]
    [string]$ServiceAccount = $null,

    [string]$RuntimeGroup = 'PrintGatewayLocalUsers'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$storePath = 'C:\PrintGateway\Lib\PrintJobStore.ps1'
$managerPath = 'C:\PrintGateway\Lib\PrintJobManager.ps1'
$integrationPath = 'C:\PrintGateway\Tests\Cases\Invoke-PrintGatewayIntegrationScenario.ps1'
$provisioningPath = 'C:\PrintGateway\Tools\Initialize-PrintGatewayDatabase.ps1'
$checks = [System.Collections.Generic.List[object]]::new()

function Add-DeploymentCheck {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [ValidateSet('PASS', 'FAIL', 'WARN')]
        [string]$Status,

        [Parameter(Mandatory)]
        [string]$Detail
    )

    $checks.Add([PSCustomObject]@{
        Name   = $Name
        Status = $Status
        Detail = $Detail
    })
}

if (-not (Test-Path -LiteralPath $storePath -PathType Leaf)) {
    Add-DeploymentCheck -Name 'Job store library' -Status 'FAIL' -Detail "Missing: $storePath"
}
else {
    . $storePath
    Add-DeploymentCheck -Name 'Job store library' -Status 'PASS' -Detail $storePath
}

if (Test-Path -LiteralPath $managerPath -PathType Leaf) {
    $managerText = Get-Content -LiteralPath $managerPath -Raw

    if ($managerText -match "Global\\PrintGateway_ExclusiveWorker") {
        Add-DeploymentCheck -Name 'Single-instance mutex' -Status 'PASS' -Detail 'Global worker mutex is configured.'
    }
    else {
        Add-DeploymentCheck -Name 'Single-instance mutex' -Status 'FAIL' -Detail 'Global worker mutex was not found.'
    }
}
else {
    Add-DeploymentCheck -Name 'Durable manager library' -Status 'FAIL' -Detail "Missing: $managerPath"
}

if (Test-Path -LiteralPath $integrationPath -PathType Leaf) {
    $integrationText = Get-Content -LiteralPath $integrationPath -Raw

    if ($integrationText -match "\[string\]\`$TransportMode = 'NoSend'") {
        Add-DeploymentCheck -Name 'Default transport safety' -Status 'PASS' -Detail 'TransportMode defaults to NoSend.'
    }
    else {
        Add-DeploymentCheck -Name 'Default transport safety' -Status 'FAIL' -Detail 'NoSend default was not confirmed.'
    }
}
else {
    Add-DeploymentCheck -Name 'Integration script' -Status 'FAIL' -Detail "Missing: $integrationPath"
}

if (-not (Test-Path -LiteralPath $SchemaPath -PathType Leaf)) {
    Add-DeploymentCheck -Name 'Schema file' -Status 'FAIL' -Detail "Missing: $SchemaPath"
}
else {
    Add-DeploymentCheck -Name 'Schema file' -Status 'PASS' -Detail ([System.IO.Path]::GetFullPath($SchemaPath))
}

$resolvedSqlitePath = $null

try {
    $resolvedSqlitePath = Resolve-PrintGatewaySqlitePath -SqlitePath $SqlitePath
    Add-DeploymentCheck -Name 'SQLite executable' -Status 'PASS' -Detail $resolvedSqlitePath

    if (-not $resolvedSqlitePath.StartsWith('C:\PrintGateway\Bin\', [System.StringComparison]::OrdinalIgnoreCase)) {
        Add-DeploymentCheck `
            -Name 'Controlled SQLite location' `
            -Status 'WARN' `
            -Detail 'SQLite is not deployed under C:\PrintGateway\Bin.'
    }
    else {
        Add-DeploymentCheck -Name 'Controlled SQLite location' -Status 'PASS' -Detail $resolvedSqlitePath
    }
}
catch {
    Add-DeploymentCheck -Name 'SQLite executable' -Status 'FAIL' -Detail $_.Exception.Message
}

if (-not (Test-Path -LiteralPath $DatabasePath -PathType Leaf)) {
    Add-DeploymentCheck -Name 'Production database' -Status 'FAIL' -Detail "Missing: $DatabasePath"
}
elseif ($null -eq $resolvedSqlitePath -or
    -not (Test-Path -LiteralPath $provisioningPath -PathType Leaf)) {
    Add-DeploymentCheck -Name 'Production database' -Status 'FAIL' -Detail 'Database could not be validated.'
}
else {
    try {
        & $provisioningPath `
            -DatabasePath $DatabasePath `
            -SchemaPath $SchemaPath `
            -SqlitePath $resolvedSqlitePath `
            -ValidateExisting | Out-Null

        Add-DeploymentCheck -Name 'Production database' -Status 'PASS' -Detail 'Schema and integrity validation passed.'
    }
    catch {
        Add-DeploymentCheck -Name 'Production database' -Status 'FAIL' -Detail $_.Exception.Message
    }
}

$databaseDirectory = [System.IO.Path]::GetDirectoryName(
    [System.IO.Path]::GetFullPath($DatabasePath)
)

if (-not (Test-Path -LiteralPath $databaseDirectory -PathType Container)) {
    Add-DeploymentCheck -Name 'Database directory ACL' -Status 'FAIL' -Detail "Missing: $databaseDirectory"
}
else {
    $acl = Get-Acl -LiteralPath $databaseDirectory
    $writeMask = (
        [System.Security.AccessControl.FileSystemRights]::WriteData -bor
        [System.Security.AccessControl.FileSystemRights]::AppendData -bor
        [System.Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
        [System.Security.AccessControl.FileSystemRights]::Delete -bor
        [System.Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [System.Security.AccessControl.FileSystemRights]::TakeOwnership
    )

    $broadWriteRules = @(
        $acl.Access | Where-Object {
            $_.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Allow -and
            $_.IdentityReference.Value -match '(Authenticated Users|BUILTIN\\Users|Everyone)$' -and
            ($_.FileSystemRights -band $writeMask) -ne 0
        }
    )

    if ($broadWriteRules.Count -gt 0) {
        $identities = @($broadWriteRules.IdentityReference.Value | Sort-Object -Unique) -join ', '
        Add-DeploymentCheck `
            -Name 'Database directory ACL' `
            -Status 'FAIL' `
            -Detail "Broad write access detected: $identities"
    }
    else {
        Add-DeploymentCheck -Name 'Database directory ACL' -Status 'PASS' -Detail 'No broad write rule was detected.'
    }

    $qualifiedRuntimeGroup = "$env:COMPUTERNAME\$RuntimeGroup"
    $runtimeAclRules = @(
        $acl.Access | Where-Object {
            $_.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Allow -and
            $_.IdentityReference.Value -eq $qualifiedRuntimeGroup -and
            ($_.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::Modify) -ne 0
        }
    )

    if ($runtimeAclRules.Count -eq 0) {
        Add-DeploymentCheck `
            -Name 'Runtime group ACL' `
            -Status 'FAIL' `
            -Detail "Modify access not found for $qualifiedRuntimeGroup."
    }
    else {
        Add-DeploymentCheck -Name 'Runtime group ACL' -Status 'PASS' -Detail $qualifiedRuntimeGroup
    }

    if ([string]::IsNullOrWhiteSpace($ServiceAccount)) {
        Add-DeploymentCheck `
            -Name 'Runtime account membership' `
            -Status 'FAIL' `
            -Detail 'ServiceAccount was not supplied; runtime-group membership cannot be verified.'
    }
    else {
        $shortServiceAccount = if ($ServiceAccount.Contains('\')) {
            $ServiceAccount.Split('\', 2)[1]
        }
        else {
            $ServiceAccount
        }

        $runtimeGroupObject = Get-LocalGroup -Name $RuntimeGroup -ErrorAction SilentlyContinue
        $runtimeMembers = if ($null -eq $runtimeGroupObject) {
            @()
        }
        else {
            @(
                Get-LocalGroupMember -Group $RuntimeGroup -ErrorAction SilentlyContinue |
                    ForEach-Object { $_.Name }
            )
        }

        $qualifiedServiceAccount = "$env:COMPUTERNAME\$shortServiceAccount"

        if ($qualifiedServiceAccount -notin $runtimeMembers) {
            Add-DeploymentCheck -Name 'Runtime account membership' -Status 'FAIL' -Detail "$qualifiedServiceAccount is not in $qualifiedRuntimeGroup."
        }
        else {
            Add-DeploymentCheck -Name 'Runtime account membership' -Status 'PASS' -Detail $qualifiedServiceAccount
        }
    }
}

$failed = @($checks | Where-Object Status -eq 'FAIL').Count
$warnings = @($checks | Where-Object Status -eq 'WARN').Count

[PSCustomObject]@{
    Ready         = ($failed -eq 0)
    FailedChecks  = $failed
    WarningChecks = $warnings
    Checks        = @($checks)
}
