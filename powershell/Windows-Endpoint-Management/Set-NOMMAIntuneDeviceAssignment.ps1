<#
.SYNOPSIS
    Sets an Intune device primary user and places its Entra device object in one managed static group.
.DESCRIPTION
    Looks up an Intune managed Windows device by serial number, replaces its Intune primary user,
    removes its Entra device object from the other NOMMA managed device groups, and adds it to the
    selected target group. Supports -WhatIf.

    This script only works with assigned/static Entra security groups. It refuses to alter dynamic
    groups because Microsoft Entra does not allow direct membership changes to them.
.PARAMETER SerialNumber
    BIOS serial number shown in Intune for the managed device.
.PARAMETER PrimaryUserUPN
    UPN of the person who should be the Intune primary user.
.PARAMETER TargetGroup
    One of the four approved static NOMMA device groups.
.PARAMETER InstallGraphModule
    Installs Microsoft.Graph.Authentication for the current user only when it is not already present.
.EXAMPLE
    .\Set-NOMMAIntuneDeviceAssignment.ps1 -SerialNumber ABC123456 -PrimaryUserUPN teacher@nomma.net -TargetGroup 'School Teacher Devices' -WhatIf
.EXAMPLE
    .\Set-NOMMAIntuneDeviceAssignment.ps1 -SerialNumber ABC123456 -PrimaryUserUPN teacher@nomma.net -TargetGroup 'School Teacher Devices'
.NOTES
    Delegated Graph scopes requested: DeviceManagementManagedDevices.ReadWrite.All, User.Read.All,
    Device.Read.All, Group.Read.All, GroupMember.ReadWrite.All. The signed-in account also needs an
    appropriate Entra/Intune role to manage device group membership.
#>
#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$SerialNumber,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[^@\s]+@[^@\s]+\.[^@\s]+$')]
    [string]$PrimaryUserUPN,

    [Parameter(Mandatory = $true)]
    [ValidateSet(
        'School Administrators Devices',
        'School Teacher Devices',
        'IT Department Devices',
        'Cadet Devices'
    )]
    [string]$TargetGroup,

    [switch]$InstallGraphModule
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ManagedGroups = @(
    'School Administrators Devices',
    'School Teacher Devices',
    'IT Department Devices',
    'Cadet Devices'
)

function Get-GraphValue {
    param([Parameter(Mandatory = $true)][object]$Response)
    if ($null -ne $Response.value) { return @($Response.value) }
    return @()
}

function Invoke-GraphRequest {
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Uri,
        [object]$Body
    )

    $parameters = @{ Method = $Method; Uri = $Uri; OutputType = 'PSObject' }
    if ($PSBoundParameters.ContainsKey('Body')) {
        $parameters.Body = $Body | ConvertTo-Json -Depth 5 -Compress
        $parameters.ContentType = 'application/json'
    }
    Invoke-MgGraphRequest @parameters
}

function Get-ExactGroup {
    param([Parameter(Mandatory = $true)][string]$DisplayName)

    $escapedName = $DisplayName.Replace("'", "''")
    $uri = "/v1.0/groups?%24filter=displayName%20eq%20'$escapedName'&%24select=id,displayName,groupTypes,membershipRule,securityEnabled,mailEnabled&%24top=2"
    $groups = @(Get-GraphValue (Invoke-GraphRequest -Method GET -Uri $uri))

    if ($groups.Count -ne 1) {
        throw "Expected exactly one Entra group named '$DisplayName'; found $($groups.Count)."
    }

    $group = $groups[0]
    if ($group.groupTypes -contains 'DynamicMembership' -or -not [string]::IsNullOrWhiteSpace($group.membershipRule)) {
        throw "'$DisplayName' is a dynamic group. Dynamic Entra groups cannot be manually changed by this script."
    }
    if (-not $group.securityEnabled -or $group.mailEnabled) {
        throw "'$DisplayName' must be an assigned security group that accepts device members."
    }
    return $group
}

function Test-GroupDeviceMembership {
    param([string]$GroupId, [string]$DeviceObjectId)
    try {
        Invoke-GraphRequest -Method GET -Uri "/v1.0/groups/$GroupId/members/$DeviceObjectId/`$ref" | Out-Null
        return $true
    }
    catch {
        if ($_.Exception.Message -match '404|Request_ResourceNotFound') { return $false }
        throw
    }
}

function Remove-GroupDeviceMembership {
    param([string]$GroupId, [string]$GroupName, [string]$DeviceObjectId)
    if (-not (Test-GroupDeviceMembership -GroupId $GroupId -DeviceObjectId $DeviceObjectId)) { return }
    if ($PSCmdlet.ShouldProcess("$GroupName", "Remove device $DeviceObjectId")) {
        Invoke-GraphRequest -Method DELETE -Uri "/v1.0/groups/$GroupId/members/$DeviceObjectId/`$ref" | Out-Null
        Write-Host "Removed device from $GroupName." -ForegroundColor Yellow
    }
}

function Add-GroupDeviceMembership {
    param([string]$GroupId, [string]$GroupName, [string]$DeviceObjectId)
    if (Test-GroupDeviceMembership -GroupId $GroupId -DeviceObjectId $DeviceObjectId) {
        Write-Host "Device is already in $GroupName." -ForegroundColor Green
        return
    }
    if ($PSCmdlet.ShouldProcess("$GroupName", "Add device $DeviceObjectId")) {
        Invoke-GraphRequest -Method POST -Uri "/v1.0/groups/$GroupId/members/`$ref" -Body @{
            '@odata.id' = "https://graph.microsoft.com/v1.0/devices/$DeviceObjectId"
        } | Out-Null
        Write-Host "Added device to $GroupName." -ForegroundColor Green
    }
}

if (-not (Get-Command Connect-MgGraph -ErrorAction SilentlyContinue)) {
    if (-not $InstallGraphModule) {
        throw 'Microsoft.Graph.Authentication is required. Re-run with -InstallGraphModule to install it for the current user.'
    }
    Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -Repository PSGallery -Force
}

$scopes = @(
    'DeviceManagementManagedDevices.ReadWrite.All',
    'User.Read.All',
    'Device.Read.All',
    'Group.Read.All',
    'GroupMember.ReadWrite.All'
)

Connect-MgGraph -Scopes $scopes -NoWelcome
try {
    $escapedSerial = $SerialNumber.Replace("'", "''")
    $managedUri = "/v1.0/deviceManagement/managedDevices?%24filter=serialNumber%20eq%20'$escapedSerial'&%24select=id,deviceName,serialNumber,azureADDeviceId,operatingSystem&%24top=2"
    $managedDevices = @(Get-GraphValue (Invoke-GraphRequest -Method GET -Uri $managedUri))

    if ($managedDevices.Count -ne 1) {
        throw "Expected exactly one Intune managed device with serial '$SerialNumber'; found $($managedDevices.Count)."
    }
    $managedDevice = $managedDevices[0]
    if ($managedDevice.operatingSystem -ne 'Windows') { throw "'$SerialNumber' is not a Windows Intune device." }
    if ([string]::IsNullOrWhiteSpace($managedDevice.azureADDeviceId)) { throw "Intune device '$SerialNumber' has no Azure AD device ID." }

    $userUri = "/v1.0/users/$([uri]::EscapeDataString($PrimaryUserUPN))?%24select=id,userPrincipalName,displayName"
    $primaryUser = Invoke-GraphRequest -Method GET -Uri $userUri

    $directoryDevice = Invoke-GraphRequest -Method GET -Uri "/v1.0/devices(deviceId='$($managedDevice.azureADDeviceId)')?%24select=id,displayName,deviceId"
    $groupMap = @{}
    foreach ($groupName in $ManagedGroups) { $groupMap[$groupName] = Get-ExactGroup -DisplayName $groupName }

    Write-Host "Intune device: $($managedDevice.deviceName) | Serial: $($managedDevice.serialNumber)" -ForegroundColor Cyan
    Write-Host "Primary user: $($primaryUser.userPrincipalName)" -ForegroundColor Cyan
    Write-Host "Target group: $TargetGroup" -ForegroundColor Cyan

    $currentUsers = @(Get-GraphValue (Invoke-GraphRequest -Method GET -Uri "/v1.0/deviceManagement/managedDevices/$($managedDevice.id)/users?%24select=id,userPrincipalName"))
    foreach ($currentUser in $currentUsers) {
        if ($currentUser.id -ne $primaryUser.id -and $PSCmdlet.ShouldProcess($managedDevice.deviceName, "Remove existing primary user $($currentUser.userPrincipalName)")) {
            Invoke-GraphRequest -Method DELETE -Uri "/v1.0/deviceManagement/managedDevices/$($managedDevice.id)/users/$($currentUser.id)/`$ref" | Out-Null
        }
    }
    if ($currentUsers.id -notcontains $primaryUser.id -and $PSCmdlet.ShouldProcess($managedDevice.deviceName, "Set primary user $PrimaryUserUPN")) {
        Invoke-GraphRequest -Method POST -Uri "/v1.0/deviceManagement/managedDevices/$($managedDevice.id)/users/`$ref" -Body @{
            '@odata.id' = "https://graph.microsoft.com/v1.0/users/$($primaryUser.id)"
        } | Out-Null
        Write-Host "Primary user set to $PrimaryUserUPN." -ForegroundColor Green
    }

    foreach ($groupName in $ManagedGroups) {
        if ($groupName -ne $TargetGroup) {
            Remove-GroupDeviceMembership -GroupId $groupMap[$groupName].id -GroupName $groupName -DeviceObjectId $directoryDevice.id
        }
    }
    Add-GroupDeviceMembership -GroupId $groupMap[$TargetGroup].id -GroupName $TargetGroup -DeviceObjectId $directoryDevice.id
}
finally {
    Disconnect-MgGraph | Out-Null
}
