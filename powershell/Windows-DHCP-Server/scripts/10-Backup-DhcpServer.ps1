<#
.SYNOPSIS
    Backs up the complete DHCP server configuration and lease database
    to a timestamped folder.

.WHEN TO USE
    Before ANY significant change (new scopes, restores, migrations),
    and on a schedule (e.g. daily via Task Scheduler). Safe to re-run:
    each run creates a new timestamped folder.

.HOW TO RUN
    As Administrator:
        .\10-Backup-DhcpServer.ps1                       # default BackupRoot
        .\10-Backup-DhcpServer.ps1 -BackupRoot D:\Backups\DHCP
        .\10-Backup-DhcpServer.ps1 -KeepLast 14          # prune old backups
#>

#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$BackupRoot,     # override the config file's BackupRoot
    [int]$KeepLast = 30      # how many timestamped backups to retain
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\CompanyDhcpConfig.ps1"
Import-Module DhcpServer

try {
    if (-not $BackupRoot) { $BackupRoot = $CompanyDhcp.BackupRoot }

    # Timestamped subfolder, e.g. C:\DhcpBackups\2026-07-06_143000
    $stamp     = Get-Date -Format 'yyyy-MM-dd_HHmmss'
    $backupDir = Join-Path $BackupRoot $stamp
    New-Item -Path $backupDir -ItemType Directory -Force | Out-Null

    # Native full backup (database + registry configuration).
    Write-Host "Backing up DHCP server to $backupDir ..."
    Backup-DhcpServer -Path $backupDir

    # Extra portable copy: XML export usable by Import-DhcpServer,
    # including leases - handy for migrating to another server.
    Export-DhcpServer -File (Join-Path $backupDir 'DhcpServerExport.xml') -Leases -Force

    Write-Host "Backup completed: $backupDir" -ForegroundColor Green

    # --- Retention: remove backups beyond -KeepLast --------------------
    $old = Get-ChildItem -Path $BackupRoot -Directory |
        Sort-Object Name -Descending | Select-Object -Skip $KeepLast
    foreach ($dir in $old) {
        Write-Host "Pruning old backup: $($dir.FullName)" -ForegroundColor Yellow
        Remove-Item -Path $dir.FullName -Recurse -Force
    }

    # --- Verification -------------------------------------------------
    Write-Host "`n--- Backup contents ---" -ForegroundColor Cyan
    Get-ChildItem -Path $backupDir -Recurse | Format-Table FullName, Length -AutoSize
}
catch {
    Write-Error "Backup failed: $($_.Exception.Message)"
    exit 1
}
