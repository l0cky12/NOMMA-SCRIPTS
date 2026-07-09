<#
.SYNOPSIS
    Searches DHCP leases across all scopes by hostname, MAC address, or IP.

.WHEN TO USE
    Helpdesk/troubleshooting: "which IP does PC-042 have?", "whose lease
    is 10.6.4.37?", "where is MAC AA-BB-...?". Read-only - always safe.

.HOW TO RUN
    As Administrator:
        .\08-Find-DhcpLease.ps1 -HostName PC-042          # partial match OK
        .\08-Find-DhcpLease.ps1 -MacAddress AA-BB-CC-DD-EE-FF
        .\08-Find-DhcpLease.ps1 -IPAddress 10.6.4.37
#>

#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$HostName,     # partial, case-insensitive match
    [string]$MacAddress,   # any format: colons, dashes, or bare hex
    [string]$IPAddress     # exact match
)

$ErrorActionPreference = 'Stop'
Import-Module DhcpServer

if (-not ($HostName -or $MacAddress -or $IPAddress)) {
    Write-Warning "Provide at least one of -HostName, -MacAddress, -IPAddress."
    return
}

try {
    # Normalize the MAC for comparison (strip separators, uppercase).
    $macNorm = if ($MacAddress) { ($MacAddress -replace '[^0-9A-Fa-f]', '').ToUpper() } else { $null }

    # Collect leases from every scope, tagging each with its scope id.
    $results = foreach ($scope in Get-DhcpServerv4Scope) {
        Get-DhcpServerv4Lease -ScopeId $scope.ScopeId -ErrorAction SilentlyContinue |
            Where-Object {
                ($HostName  -and $_.HostName -like "*$HostName*") -or
                ($macNorm   -and (($_.ClientId -replace '[^0-9A-Fa-f]', '').ToUpper() -eq $macNorm)) -or
                ($IPAddress -and $_.IPAddress.ToString() -eq $IPAddress)
            } |
            Select-Object @{n='ScopeId';e={$scope.ScopeId}}, IPAddress, ClientId,
                          HostName, AddressState, LeaseExpiryTime
    }

    if ($results) {
        Write-Host "`n--- Matching leases ---" -ForegroundColor Cyan
        $results | Format-Table -AutoSize
    } else {
        Write-Host "No leases matched the search criteria." -ForegroundColor Yellow
    }
}
catch {
    Write-Error "Lease search failed: $($_.Exception.Message)"
    exit 1
}
