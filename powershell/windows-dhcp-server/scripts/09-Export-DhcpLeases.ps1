<#
.SYNOPSIS
    Exports all DHCP leases (every scope) to a timestamped CSV file.

.WHEN TO USE
    Audits, inventory snapshots, or before major changes. Read-only on
    the DHCP server itself - always safe to run.

.HOW TO RUN
    As Administrator:
        .\09-Export-DhcpLeases.ps1                          # default report folder
        .\09-Export-DhcpLeases.ps1 -Path C:\Temp\leases.csv # explicit file
#>

#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$Path    # optional: full path of the CSV to write
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\CompanyDhcpConfig.ps1"
Import-Module DhcpServer

try {
    # Default: <ReportRoot>\DhcpLeases-YYYYMMDD-HHMMSS.csv
    if (-not $Path) {
        if (-not (Test-Path $CompanyDhcp.ReportRoot)) {
            New-Item -Path $CompanyDhcp.ReportRoot -ItemType Directory -Force | Out-Null
        }
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $Path  = Join-Path $CompanyDhcp.ReportRoot "DhcpLeases-$stamp.csv"
    }

    # Gather leases from every scope with a scope-id column.
    $leases = foreach ($scope in Get-DhcpServerv4Scope) {
        Get-DhcpServerv4Lease -ScopeId $scope.ScopeId -ErrorAction SilentlyContinue |
            Select-Object @{n='ScopeId';e={$scope.ScopeId}},
                          @{n='ScopeName';e={$scope.Name}},
                          IPAddress, ClientId, HostName, AddressState,
                          LeaseExpiryTime, Description
    }

    if (-not $leases) {
        Write-Warning "No leases found; nothing exported."
        return
    }

    $leases | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8
    Write-Host "Exported $($leases.Count) leases to: $Path" -ForegroundColor Green

    # --- Verification -------------------------------------------------
    Import-Csv $Path | Select-Object -First 5 | Format-Table -AutoSize
}
catch {
    Write-Error "Export failed: $($_.Exception.Message)"
    exit 1
}
