<#
.SYNOPSIS
    Restores the DHCP server configuration from a backup folder.
    *** DESTRUCTIVE: overwrites the current DHCP configuration. ***

.WHEN TO USE
    Disaster recovery only - after data loss, a failed change, or server
    rebuild. Requires a folder previously created by 10-Backup-DhcpServer.ps1
    (or Backup-DhcpServer).

.HOW TO RUN
    As Administrator:
        .\11-Restore-DhcpServer.ps1 -BackupPath 'C:\DhcpBackups\2026-07-06_143000'
#>

#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$BackupPath    # folder created by Backup-DhcpServer
)

$ErrorActionPreference = 'Stop'
Import-Module DhcpServer

try {
    if (-not (Test-Path $BackupPath)) {
        throw "Backup path not found: $BackupPath"
    }

    # --- Explicit confirmation before a destructive action ------------
    Write-Warning "This will OVERWRITE the current DHCP configuration on $env:COMPUTERNAME"
    Write-Warning "with the backup at: $BackupPath"
    $confirm = Read-Host "Type RESTORE (uppercase) to continue"
    if ($confirm -cne 'RESTORE') {
        Write-Host "Aborted - nothing was changed." -ForegroundColor Yellow
        return
    }

    # Safety net: back up the CURRENT state first, so even a bad restore
    # can be rolled back.
    $preRestore = Join-Path $env:TEMP ("DhcpPreRestore-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -Path $preRestore -ItemType Directory -Force | Out-Null
    Backup-DhcpServer -Path $preRestore
    Write-Host "Current configuration saved to $preRestore (rollback copy)." -ForegroundColor Cyan

    # --- Restore and restart -------------------------------------------
    Write-Host "Restoring DHCP configuration..."
    Restore-DhcpServer -Path $BackupPath -Force

    # The restore is applied when the service restarts.
    Restart-Service -Name DHCPServer -Force
    Write-Host "Restore complete; DHCP service restarted." -ForegroundColor Green

    # --- Verification -------------------------------------------------
    Write-Host "`n--- Scopes after restore ---" -ForegroundColor Cyan
    Get-DhcpServerv4Scope | Format-Table ScopeId, Name, State -AutoSize
    Get-Service -Name DHCPServer | Format-Table Name, Status -AutoSize
}
catch {
    Write-Error "Restore failed: $($_.Exception.Message)"
    Write-Warning "If the service is now unhealthy, restore the rollback copy from $preRestore."
    exit 1
}
