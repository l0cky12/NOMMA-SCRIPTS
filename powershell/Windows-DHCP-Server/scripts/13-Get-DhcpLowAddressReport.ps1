<#
.SYNOPSIS
    Shows free/used addresses per scope and flags scopes running low.

.WHEN TO USE
    Capacity planning, or scheduled (Task Scheduler) to catch pools
    filling up before clients start failing to get leases. Read-only.

.HOW TO RUN
    As Administrator:
        .\13-Get-DhcpLowAddressReport.ps1                       # default 80% threshold
        .\13-Get-DhcpLowAddressReport.ps1 -ThresholdPercent 70
#>

#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [ValidateRange(1, 100)]
    [int]$ThresholdPercent = 80    # flag scopes at/above this utilization
)

$ErrorActionPreference = 'Stop'
Import-Module DhcpServer

try {
    $report = foreach ($scope in Get-DhcpServerv4Scope) {
        $stat = Get-DhcpServerv4ScopeStatistics -ScopeId $scope.ScopeId
        [pscustomobject]@{
            ScopeId   = $scope.ScopeId
            Name      = $scope.Name
            State     = $scope.State
            Total     = $stat.Free + $stat.InUse   # addresses in the pool (minus exclusions)
            InUse     = $stat.InUse
            Free      = $stat.Free
            Reserved  = $stat.Reserved
            PctInUse  = [math]::Round($stat.PercentageInUse, 1)
            LowOnIPs  = ($stat.PercentageInUse -ge $ThresholdPercent)
        }
    }

    if (-not $report) { Write-Warning "No scopes found."; return }

    # --- Full availability table ---------------------------------------
    Write-Host "`n--- Available addresses per scope ---" -ForegroundColor Cyan
    $report | Format-Table ScopeId, Name, State, Total, InUse, Free, Reserved, PctInUse, LowOnIPs -AutoSize

    # --- Scopes over the threshold ---------------------------------------
    $low = $report | Where-Object LowOnIPs
    if ($low) {
        Write-Host "--- Scopes at or above ${ThresholdPercent}% utilization ---" -ForegroundColor Red
        $low | Format-Table ScopeId, Name, Free, PctInUse -AutoSize
        Write-Warning "Consider shortening lease duration, cleaning stale leases, or extending the range."
        exit 1   # non-zero exit so a scheduled task can alert on it
    } else {
        Write-Host "No scope is above the ${ThresholdPercent}% threshold." -ForegroundColor Green
    }
}
catch {
    Write-Error "Report failed: $($_.Exception.Message)"
    exit 1
}
