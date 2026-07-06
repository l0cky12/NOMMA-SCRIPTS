# Windows DHCP Server PowerShell Scripts

PowerShell scripts for installing, configuring, operating, backing up, restoring, and auditing the Windows Server DHCP role.

Source repo imported from: https://github.com/l0cky12/windows-server-powershell

## Layout

```text
powershell/windows-dhcp-server/
├── Configure-DhcpServer.ps1
└── scripts/
    ├── CompanyDhcpConfig.ps1
    ├── 01-Install-DhcpServerRole.ps1
    ├── 02-Authorize-DhcpServer.ps1
    ├── 03-New-CompanyDhcpScopes.ps1
    ├── 04-Set-CompanyDhcpOptions.ps1
    ├── 05-Add-DhcpExclusions.ps1
    ├── 06-Add-DhcpReservation.ps1
    ├── 07-Get-DhcpScopesAndLeases.ps1
    ├── 08-Find-DhcpLease.ps1
    ├── 09-Export-DhcpLeases.ps1
    ├── 10-Backup-DhcpServer.ps1
    ├── 11-Restore-DhcpServer.ps1
    ├── 12-Invoke-DhcpHealthCheck.ps1
    ├── 13-Get-DhcpLowAddressReport.ps1
    ├── 14-Export-DhcpDocumentation.ps1
    ├── 15-Restart-DhcpService.ps1
    └── 16-Remove-DhcpScopeSafely.ps1
```

## Requirements

- Windows Server with PowerShell 5.1+
- Administrator rights for install/configuration scripts
- DHCP Server role or RSAT DHCP tools for operational scripts
- Run from an elevated PowerShell session

## Typical use

Review `scripts/CompanyDhcpConfig.ps1` first, then run the orchestrator:

```powershell
.\Configure-DhcpServer.ps1
```

For individual tasks, run the numbered scripts directly from the `scripts` folder. Several scripts support safety switches such as `-WhatIf` or require explicit parameters before making changes.

## Notes

These scripts are intended for Windows Server DHCP administration. Test in a lab before running against production DHCP scopes.
