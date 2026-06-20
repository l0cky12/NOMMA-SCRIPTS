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
