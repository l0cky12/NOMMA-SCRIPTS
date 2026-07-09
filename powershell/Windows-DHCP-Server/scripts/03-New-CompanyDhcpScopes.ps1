<#
.SYNOPSIS
    Creates the three company DHCP scopes defined in CompanyDhcpConfig.ps1.

.WHEN TO USE
    Once after the server is installed and authorized (scripts 01-02).
    Safe to re-run: existing scopes are skipped, never duplicated.
    Scopes are created INACTIVE by default so options can be applied
    first (script 04). Use -Activate to activate immediately.

.HOW TO RUN
    As Administrator:
        .\03-New-CompanyDhcpScopes.ps1              # create inactive
        .\03-New-CompanyDhcpScopes.ps1 -Activate    # create and activate
#>

#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [switch]$Activate    # activate scopes immediately after creation
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\CompanyDhcpConfig.ps1"   # load shared settings
Import-Module DhcpServer

foreach ($scope in $CompanyDhcp.Scopes) {
    try {
        # --- Skip if the scope already exists (idempotency) ----------
        if (Get-DhcpServerv4Scope -ScopeId $scope.ScopeId -ErrorAction SilentlyContinue) {
            Write-Host "Scope $($scope.ScopeId) already exists. Skipping." -ForegroundColor Yellow
            continue
        }

        Write-Host "Creating $($scope.Name) [$($scope.StartRange) - $($scope.EndRange)]..."
        Add-DhcpServerv4Scope `
            -Name          $scope.Name `
            -Description   $scope.Description `
            -StartRange    $scope.StartRange `
            -EndRange      $scope.EndRange `
            -SubnetMask    $scope.SubnetMask `
            -LeaseDuration $CompanyDhcp.LeaseDuration `
            -State         $(if ($Activate) { 'Active' } else { 'InActive' })

        Write-Host "Scope $($scope.ScopeId) created ($(if ($Activate) {'Active'} else {'InActive - run 04 to set options, then activate'}))." -ForegroundColor Green
    }
    catch {
        Write-Error "Failed to create scope $($scope.ScopeId): $($_.Exception.Message)"
    }
}

# --- Verification -----------------------------------------------------
Write-Host "`n--- Configured scopes ---" -ForegroundColor Cyan
Get-DhcpServerv4Scope | Format-Table ScopeId, Name, StartRange, EndRange, SubnetMask, State -AutoSize
