<#
.SYNOPSIS
    Safely restarts the DHCP Server service with confirmation and
    post-restart verification.

.WHEN TO USE
    After configuration changes that need a service restart, or when the
    service misbehaves. Brief impact: clients cannot obtain NEW leases
    during the restart (existing leases keep working).

.HOW TO RUN
    As Administrator:
        .\15-Restart-DhcpService.ps1          # asks for confirmation
        .\15-Restart-DhcpService.ps1 -Force   # no prompt (for automation)
#>

#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [switch]$Force    # skip the confirmation prompt
)

$ErrorActionPreference = 'Stop'

try {
    $svc = Get-Service -Name DHCPServer
    Write-Host "Current status: $($svc.Status)" -ForegroundColor Cyan

    # --- Confirm before interrupting lease issuance ---------------------
    if (-not $Force) {
        Write-Warning "Restarting DHCPServer briefly prevents clients from obtaining new leases."
        $answer = Read-Host "Restart the DHCP Server service now? (y/N)"
        if ($answer -notmatch '^[Yy]') {
            Write-Host "Aborted - service not restarted." -ForegroundColor Yellow
            return
        }
    }

    Write-Host "Restarting DHCPServer service..."
    Restart-Service -Name DHCPServer -Force

    # --- Wait for the service to report Running -------------------------
    $svc = Get-Service -Name DHCPServer
    $svc.WaitForStatus('Running', [TimeSpan]::FromSeconds(60))
    Write-Host "DHCPServer service is running again." -ForegroundColor Green

    # --- Verification: service up AND answering management calls --------
    Get-Service -Name DHCPServer | Format-Table Name, Status, StartType -AutoSize
    Import-Module DhcpServer
    $scopeCount = (Get-DhcpServerv4Scope | Measure-Object).Count
    Write-Host "Server is responding: $scopeCount scope(s) visible." -ForegroundColor Green
}
catch {
    Write-Error "Service restart failed: $($_.Exception.Message)"
    Write-Warning "Check the event log: Get-WinEvent -LogName 'Microsoft-Windows-DHCP Server Events/Operational' -MaxEvents 20"
    exit 1
}
