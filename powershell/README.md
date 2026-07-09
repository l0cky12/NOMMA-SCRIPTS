# NOMMA PC Rename Script

Renames computers during Autopilot enrollment based on serial number and asset tag from a CSV file.

## Naming Convention

`L5-SERIAL(7)-ASSETTAG(4)`

Example: Serial `ABC1234567890` + AssetTag `1001` → `L5-567890-1001`

## CSV Format

```csv
SerialNumber,AssetTag
ABC1234567890,1001
DEF5678901234,1002
GHI9012345678,1003
```

## Usage

### Manual test (dry run)
```powershell
.\rename-pc.ps1 -CsvPath "C:\ProgramData\Intune\rename-list.csv" -WhatIf
```

### Production run
```powershell
.\rename-pc.ps1 -CsvPath "C:\ProgramData\Intune\rename-list.csv"
```

### Intune Win32 App deployment
1. Package `rename-pc.ps1` + `rename-list.csv` as a Win32 app
2. Install command: `powershell.exe -ExecutionPolicy Bypass -File rename-pc.ps1 -CsvPath ".\rename-list.csv"`
3. Detection rule: Check if computer name matches the CSV pattern
4. Deploy to Autopilot device group

## Requirements
- Windows 10/11
- PowerShell 5.1+
- Administrator rights
- CSV file with SerialNumber and AssetTag columns

## Log Output
Logs are written to `C:\ProgramData\Intune\rename-pc.log`

---

# NOMMA DC / CA Diagnostics

Script: `Invoke-NOMMA-DC-CA-Diagnostics.ps1`

Runs a quick health check for which domain controller and certificate authority a Windows server is using. It queries secure channel status, current logon server, Kerberos tickets, and several `certutil` checks against `NOMMA`, `NOMMA-DC2023`, and `NOMMA-DC05`.

### Usage
```powershell
cd .\powershell
.\Invoke-NOMMA-DC-CA-Diagnostics.ps1
```

---

# Windows DHCP Server Scripts

Folder: `powershell/windows-dhcp-server/`

Contains Windows Server DHCP role automation scripts imported from `l0cky12/windows-server-powershell`, including:

- DHCP Server role installation and authorization
- Company DHCP scope creation and options
- Exclusions and reservations
- Scope and lease reporting
- Lease search/export
- DHCP backup and restore
- Health checks and low-address reports
- DHCP service restart and safe scope removal

Start with:

```powershell
cd .\windows-dhcp-server
.\Configure-DhcpServer.ps1
```

Review `windows-dhcp-server/scripts/CompanyDhcpConfig.ps1` before production use.

