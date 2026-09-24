[CmdletBinding()]
param(
    [string]$GroupName = 'PrintGatewayLocalUsers',

    [string[]]$LocalAccount = @($env:USERNAME),

    [string]$DataPath = 'C:\PrintGateway\Data',

    [switch]$Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($GroupName)) {
    throw 'GroupName must not be empty.'
}

if (-not (Test-Path -LiteralPath $DataPath -PathType Container)) {
    throw "Data directory not found: $DataPath"
}

$computerName = $env:COMPUTERNAME
$qualifiedGroupName = "$computerName\$GroupName"
$resolvedAccounts = @(
    foreach ($account in $LocalAccount) {
        if ([string]::IsNullOrWhiteSpace($account)) {
            throw 'LocalAccount entries must not be empty.'
        }

        $shortName = if ($account.Contains('\')) {
            $parts = $account.Split('\', 2)

            if ($parts[0] -ne '.' -and
                $parts[0] -ne $computerName) {
                throw "Account is not local to this computer: $account"
            }

            $parts[1]
        }
        else {
            $account
        }

        $localUser = Get-LocalUser -Name $shortName -ErrorAction SilentlyContinue

        if ($null -eq $localUser -or -not $localUser.Enabled) {
            throw "Enabled local account not found: $shortName"
        }

        "$computerName\$shortName"
    }
)

$plan = [PSCustomObject]@{
    Apply          = [bool]$Apply
    Group          = $qualifiedGroupName
    Accounts       = $resolvedAccounts
    DataPath       = [System.IO.Path]::GetFullPath($DataPath)
    GroupRights    = 'Modify, Synchronize'
    RemoveBroadAcl = 'Write-capable Allow rules for Authenticated Users and BUILTIN\Users'
}

if (-not $Apply) {
    return $plan
}

$principal = [Security.Principal.WindowsPrincipal]::new(
    [Security.Principal.WindowsIdentity]::GetCurrent()
)

if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Administrator elevation is required. Re-run PowerShell as administrator.'
}

$group = Get-LocalGroup -Name $GroupName -ErrorAction SilentlyContinue

if ($null -eq $group) {
    $group = New-LocalGroup `
        -Name $GroupName `
        -Description 'PrintGateway runtime local accounts'
}

$existingMembers = @(
    Get-LocalGroupMember -Group $GroupName -ErrorAction SilentlyContinue |
        ForEach-Object { $_.Name }
)

foreach ($account in $resolvedAccounts) {
    if ($account -notin $existingMembers) {
        Add-LocalGroupMember -Group $GroupName -Member $account
    }
}

$acl = Get-Acl -LiteralPath $DataPath
$acl.SetAccessRuleProtection($true, $true)

foreach ($sidValue in @('S-1-5-11', 'S-1-5-32-545', 'S-1-1-0')) {
    $sid = [System.Security.Principal.SecurityIdentifier]::new($sidValue)
    $acl.PurgeAccessRules($sid)
}

$usersReadRule = [System.Security.AccessControl.FileSystemAccessRule]::new(
    [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-545'),
    ([System.Security.AccessControl.FileSystemRights]::ReadAndExecute -bor
     [System.Security.AccessControl.FileSystemRights]::Synchronize),
    ([System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
     [System.Security.AccessControl.InheritanceFlags]::ObjectInherit),
    [System.Security.AccessControl.PropagationFlags]::None,
    [System.Security.AccessControl.AccessControlType]::Allow
)

$acl.SetAccessRule($usersReadRule)

$runtimeRule = [System.Security.AccessControl.FileSystemAccessRule]::new(
    $qualifiedGroupName,
    ([System.Security.AccessControl.FileSystemRights]::Modify -bor
     [System.Security.AccessControl.FileSystemRights]::Synchronize),
    ([System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
     [System.Security.AccessControl.InheritanceFlags]::ObjectInherit),
    [System.Security.AccessControl.PropagationFlags]::None,
    [System.Security.AccessControl.AccessControlType]::Allow
)

$acl.SetAccessRule($runtimeRule)
Set-Acl -LiteralPath $DataPath -AclObject $acl

$appliedAcl = Get-Acl -LiteralPath $DataPath
$appliedRule = @(
    $appliedAcl.Access | Where-Object {
        $_.IdentityReference.Value -eq $qualifiedGroupName -and
        $_.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Allow -and
        ($_.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::Modify) -ne 0
    }
)

if ($appliedRule.Count -eq 0) {
    throw "Failed to verify Modify permission for $qualifiedGroupName on $DataPath"
}

return [PSCustomObject]@{
    Applied  = $true
    Group    = $qualifiedGroupName
    Accounts = @(
        Get-LocalGroupMember -Group $GroupName |
            ForEach-Object { $_.Name }
    )
    DataPath = [System.IO.Path]::GetFullPath($DataPath)
}
