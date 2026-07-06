<#
.SYNOPSIS
    Applies scope options (router, DNS servers, DNS domain, lease duration)
    from CompanyDhcpConfig.ps1 to every company scope.

.WHEN TO USE
    After creating scopes (script 03), and any time company DNS/gateway
    settings change. Safe to re-run: options are simply overwritten with
    the configured values; placeholder (CHANGE_ME) values are skipped
    with a warning.

.HOW TO RUN
    As Administrator:
        .\04-Set-CompanyDhcpOptions.ps1                   # options only
        .\04-Set-CompanyDhcpOptions.ps1 -ActivateScopes   # options + activate
#>

#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [switch]$ActivateScopes   # activate each scope once options are applied
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\CompanyDhcpConfig.ps1"
Import-Module DhcpServer

foreach ($scope in $CompanyDhcp.Scopes) {
    try {
        if (-not (Get-DhcpServerv4Scope -ScopeId $scope.ScopeId -ErrorAction SilentlyContinue)) {
            Write-Warning "Scope $($scope.ScopeId) does not exist. Run 03-New-CompanyDhcpScopes.ps1 first."
            continue
        }
        Write-Host "`nScope $($scope.ScopeId):" -ForegroundColor Cyan

        # Option 003 - default gateway (per scope, from config placeholder).
        if (Test-DhcpConfigured $scope.Router) {
            Set-DhcpServerv4OptionValue -ScopeId $scope.ScopeId -Router $scope.Router
            Write-Host "  Router (003)     : $($scope.Router)" -ForegroundColor Green
        } else {
            Write-Warning "  Router still 'CHANGE_ME' - gateway option NOT set."
        }

        # Option 006 - DNS servers. -Force skips DNS-registration validation.
        if (Test-DhcpConfigured $CompanyDhcp.DnsServers) {
            Set-DhcpServerv4OptionValue -ScopeId $scope.ScopeId -DnsServer $CompanyDhcp.DnsServers -Force
            Write-Host "  DNS (006)        : $($CompanyDhcp.DnsServers -join ', ')" -ForegroundColor Green
        } else {
            Write-Warning "  DnsServers still 'CHANGE_ME' - DNS option NOT set."
        }

        # Option 015 - DNS domain name.
        if (Test-DhcpConfigured $CompanyDhcp.DnsDomain) {
            Set-DhcpServerv4OptionValue -ScopeId $scope.ScopeId -DnsDomain $CompanyDhcp.DnsDomain
            Write-Host "  Domain (015)     : $($CompanyDhcp.DnsDomain)" -ForegroundColor Green
        } else {
            Write-Warning "  DnsDomain still 'CHANGE_ME' - domain option NOT set."
        }

        # Lease duration - kept in sync with config on every run.
        Set-DhcpServerv4Scope -ScopeId $scope.ScopeId -LeaseDuration $CompanyDhcp.LeaseDuration
        Write-Host "  Lease duration   : $($CompanyDhcp.LeaseDuration)" -ForegroundColor Green

        if ($ActivateScopes) {
            Set-DhcpServerv4Scope -ScopeId $scope.ScopeId -State Active
            Write-Host "  State            : Active" -ForegroundColor Green
        }
    }
    catch {
        Write-Error "Failed on scope $($scope.ScopeId): $($_.Exception.Message)"
    }
}

# --- Verification -----------------------------------------------------
Write-Host "`n--- Options per scope ---" -ForegroundColor Cyan
foreach ($scope in $CompanyDhcp.Scopes) {
    Get-DhcpServerv4OptionValue -ScopeId $scope.ScopeId -ErrorAction SilentlyContinue |
        Format-Table @{n='Scope';e={$scope.ScopeId}}, OptionId, Name, Value -AutoSize
}
