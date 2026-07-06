<#
.SYNOPSIS
    Installs the DHCP Server role and management tools on Windows Server 2019.

.WHEN TO USE
    Once, on a new DHCP server (or to verify the role on an existing one).
    Safe to re-run: does nothing if the role is already installed.

.HOW TO RUN
    Right-click PowerShell -> "Run as Administrator", then:
        .\01-Install-DhcpServerRole.ps1
#>

#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'

try {
    # --- Check current role state -----------------------------------
    $feature = Get-WindowsFeature -Name DHCP

    if ($feature.Installed) {
        Write-Host "DHCP Server role is already installed." -ForegroundColor Green
    }
    else {
        Write-Host "Installing DHCP Server role and management tools..."
        $result = Install-WindowsFeature -Name DHCP -IncludeManagementTools
        if (-not $result.Success) {
            throw "Install-WindowsFeature failed (ExitCode: $($result.ExitCode))."
        }
        Write-Host "DHCP Server role installed." -ForegroundColor Green
        if ($result.RestartNeeded -eq 'Yes') {
            Write-Warning "A restart is required. Reboot, then continue with 02-Authorize-DhcpServer.ps1."
        }
    }

    # --- Post-install housekeeping -----------------------------------
    # Create local DHCP Administrators / DHCP Users groups (no-op if present).
    Add-DhcpServerSecurityGroup -ErrorAction SilentlyContinue

    # Clear the Server Manager "Complete DHCP configuration" alert.
    $smKey = 'HKLM:\SOFTWARE\Microsoft\ServerManager\Roles\12'
    if (Test-Path $smKey) {
        Set-ItemProperty -Path $smKey -Name ConfigurationState -Value 2
    }

    # Ensure the service is running and starts with the OS.
    Set-Service  -Name DHCPServer -StartupType Automatic
    Start-Service -Name DHCPServer

    # --- Verification -------------------------------------------------
    Write-Host "`n--- Verification ---" -ForegroundColor Cyan
    Get-WindowsFeature -Name DHCP, RSAT-DHCP | Format-Table Name, InstallState -AutoSize
    Get-Service -Name DHCPServer | Format-Table Name, Status, StartType -AutoSize
}
catch {
    Write-Error "Role installation failed: $($_.Exception.Message)"
    exit 1
}
