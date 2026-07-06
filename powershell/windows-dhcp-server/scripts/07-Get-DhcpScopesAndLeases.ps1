<#
.SYNOPSIS
    Lists all DHCP scopes, their utilization, and active leases.

.WHEN TO USE
    Day-to-day visibility: quick look at what the server is handing out.
    Read-only - always safe to run.

.HOW TO RUN
    As Administrator:
        .\07-Get-DhcpScopesAndLeases.ps1                      # all scopes
        .\07-Get-DhcpScopesAndLeases.ps1 -ScopeId 10.1.0.0    # one scope
#>

#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$ScopeId    # optional: limit output to one scope
)

$ErrorActionPreference = 'Stop'
Import-Module DhcpServer

try {
    # Select all scopes, or just the one requested.
    $scopes = if ($ScopeId) {
        Get-DhcpServerv4Scope -ScopeId $ScopeId
    } else {
        Get-DhcpServerv4Scope
    }
    if (-not $scopes) { Write-Warning "No scopes found."; return }

    # --- Scope overview ----------------------------------------------
    Write-Host "`n--- DHCP scopes ---" -ForegroundColor Cyan
    $scopes | Format-Table ScopeId, Name, StartRange, EndRange, SubnetMask, LeaseDuration, State -AutoSize

    # --- Utilization statistics ---------------------------------------
    Write-Host "--- Scope utilization ---" -ForegroundColor Cyan
    $stats = foreach ($s in $scopes) {
        Get-DhcpServerv4ScopeStatistics -ScopeId $s.ScopeId
    }
    $stats | Format-Table ScopeId, Free, InUse, Reserved, PercentageInUse -AutoSize

    # --- Active leases per scope ---------------------------------------
    foreach ($s in $scopes) {
        Write-Host "--- Active leases in $($s.ScopeId) ($($s.Name)) ---" -ForegroundColor Cyan
        $leases = Get-DhcpServerv4Lease -ScopeId $s.ScopeId |
            Where-Object { $_.AddressState -like 'Active*' }
        if ($leases) {
            $leases | Sort-Object IPAddress |
                Format-Table IPAddress, ClientId, HostName, AddressState, LeaseExpiryTime -AutoSize
        } else {
            Write-Host "  (no active leases)`n"
        }
    }
}
catch {
    Write-Error "Failed to read scopes/leases: $($_.Exception.Message)"
    exit 1
}
