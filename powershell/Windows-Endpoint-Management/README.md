# Windows Endpoint Management PowerShell Scripts

Scripts for endpoint renaming and other Intune / Autopilot-adjacent tasks.

## Scripts

### `rename-pc.ps1`
Renames computers during Autopilot enrollment based on serial number and asset tag from a CSV file.

**Naming convention:** `L5-SERIAL(7)-ASSETTAG(4)`

**Example:** Serial `ABC1234567890` + AssetTag `1001` → `L5-567890-1001`

### Usage

```powershell
.\rename-pc.ps1 -CsvPath "C:\ProgramData\Intune\rename-list.csv" -WhatIf
```

```powershell
.\rename-pc.ps1 -CsvPath "C:\ProgramData\Intune\rename-list.csv"
```

## Requirements
- Windows 10/11
- PowerShell 5.1+
- Administrator rights
- CSV file with `SerialNumber` and `AssetTag` columns

## Log Output
Logs are written to `C:\ProgramData\Intune\rename-pc.log`
