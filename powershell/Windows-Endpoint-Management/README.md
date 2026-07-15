# Windows Endpoint Management PowerShell Scripts

Scripts for endpoint renaming and other Intune / Autopilot-adjacent tasks.

## Scripts

### `Export-NOMMAAutopilotDevice.ps1`

Runs locally in an elevated Windows PowerShell 5.1 session, reads the BIOS serial number and Autopilot hardware hash, and safely adds one row to a shared local or UNC CSV for Intune Autopilot import. It does not install modules or use cloud credentials. Full usage: [`Export-NOMMAAutopilotDevice-Help.md`](Export-NOMMAAutopilotDevice-Help.md).

```powershell
# Creates or appends to .\NOMMA-Autopilot.csv without a group tag.
.\Export-NOMMAAutopilotDevice.ps1
```

```powershell
# Use a shared CSV and apply an Autopilot group tag.
.\Export-NOMMAAutopilotDevice.ps1 `
    -CsvPath "\\fileserver\Deployment\Autopilot\NOMMA-Autopilot.csv" `
    -GroupTag "Cadet Devices"
```

Supported group tags:

- `Cadet Devices`
- `Teacher Devices`
- `IT Devices`
- `School Administrator Devices`

The CSV uses the exact Intune headers below. `Windows Product ID` and `Assigned User` are intentionally blank.

```text
Device Serial Number,Windows Product ID,Hardware Hash,Group Tag,Assigned User
```

Concurrent devices use an atomically created `<CsvPath>.lock` file. A device waits up to 120 seconds by default, validates an existing CSV before appending, and skips a row when the serial number or hardware hash already exists. Use `-LockTimeoutSeconds` to change the wait. A timeout does not delete another writer's lock.

### Dynamic Entra device groups for Autopilot group tags

Create one dynamic device security group per Autopilot group tag and use the matching membership rule:

| Group tag | Dynamic membership rule |
|---|---|
| Cadet Devices | `(device.devicePhysicalIds -any (_ -eq "[OrderID]:Cadet Devices"))` |
| Teacher Devices | `(device.devicePhysicalIds -any (_ -eq "[OrderID]:Teacher Devices"))` |
| IT Devices | `(device.devicePhysicalIds -any (_ -eq "[OrderID]:IT Devices"))` |
| School Administrator Devices | `(device.devicePhysicalIds -any (_ -eq "[OrderID]:School Administrator Devices"))` |

In the Entra admin center, create a Security group with **Membership type: Dynamic Device**, then paste the applicable rule above. Autopilot stores the CSV `Group Tag` value in `devicePhysicalIds` as `[OrderID]:<Group Tag>`.

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
