<#
.SYNOPSIS
    Deactivates - or, on explicit request, deletes - a DHCP scope.
    *** DELETION IS DESTRUCTIVE: leases and reservations are removed. ***

.WHEN TO USE
    Decommissioning a network segment. Recommended workflow:
      1. Deactivate first (default behavior) and wait days/weeks.
      2. Only delete (-Delete) once you are sure nothing depends on it.
    Take a backup (10-Backup-DhcpServer.ps1) before deleting.

.HOW TO RUN
    As Administrator:
        .\16-Remove-DhcpScopeSafely.ps1 -ScopeId 10.6.12.0            # deactivate only
        .\16-Remove-DhcpScopeSafely.ps1 -ScopeId 10.6.12.0 -Delete    # permanent removal
#>

#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ScopeId,     # e.g. 10.6.12.0
    [switch]$Delete       # permanently remove instead of deactivating
)

$ErrorActionPreference = 'Stop'
Import-Module DhcpServer

try {
    $scope = Get-DhcpServerv4Scope -ScopeId $ScopeId -ErrorAction SilentlyContinue
    if (-not $scope) {
        Write-Warning "Scope $ScopeId does not exist on this server. Nothing to do."
        return
    }

    # Show what is at stake before asking for confirmation.
    $activeLeases  = @(Get-DhcpServerv4Lease -ScopeId $ScopeId -ErrorAction SilentlyContinue |
                       Where-Object { $_.AddressState -like 'Active*' })
    $reservations  = @(Get-DhcpServerv4Reservation -ScopeId $ScopeId -ErrorAction SilentlyContinue)

    Write-Host "`nScope        : $($scope.ScopeId) ($($scope.Name))" -ForegroundColor Cyan
    Write-Host "State        : $($scope.State)"
    Write-Host "Active leases: $($activeLeases.Count)"
    Write-Host "Reservations : $($reservations.Count)`n"

    if ($Delete) {
        # --- Permanent deletion path ------------------------------------
        Write-Warning "You are about to PERMANENTLY DELETE scope $ScopeId,"
        Write-Warning "including $($activeLeases.Count) active lease(s) and $($reservations.Count) reservation(s)."
        Write-Warning "Run 10-Backup-DhcpServer.ps1 first if you have not already."
        $confirm = Read-Host "Type the scope ID ($ScopeId) to confirm deletion"
        if ($confirm -ne $ScopeId) {
            Write-Host "Aborted - scope NOT deleted." -ForegroundColor Yellow
            return
        }
        Remove-DhcpServerv4Scope -ScopeId $ScopeId -Force
        Write-Host "Scope $ScopeId deleted." -ForegroundColor Green
    }
    else {
        # --- Safe default: deactivate only ------------------------------
        if ($scope.State -eq 'InActive') {
            Write-Host "Scope $ScopeId is already inactive." -ForegroundColor Yellow
            return
        }
        Write-Warning "The scope will stop answering DHCP requests but its data is kept."
        $answer = Read-Host "Deactivate scope $ScopeId now? (y/N)"
        if ($answer -notmatch '^[Yy]') {
            Write-Host "Aborted - scope unchanged." -ForegroundColor Yellow
            return
        }
        Set-DhcpServerv4Scope -ScopeId $ScopeId -State InActive
        Write-Host "Scope $ScopeId deactivated (re-activate with: Set-DhcpServerv4Scope -ScopeId $ScopeId -State Active)." -ForegroundColor Green
    }

    # --- Verification -------------------------------------------------
    Write-Host "`n--- Remaining scopes ---" -ForegroundColor Cyan
    Get-DhcpServerv4Scope | Format-Table ScopeId, Name, State -AutoSize
}
catch {
    Write-Error "Operation failed: $($_.Exception.Message)"
    exit 1
}
