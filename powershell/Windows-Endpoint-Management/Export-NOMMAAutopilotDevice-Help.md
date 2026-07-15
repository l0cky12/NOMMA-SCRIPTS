# Export-NOMMAAutopilotDevice.ps1 Help

Collects the current Windows 10/11 device's BIOS serial number and Autopilot hardware hash, then writes an Intune-compatible row to a CSV.

## Requirements

- Run from an **elevated Windows PowerShell 5.1** session.
- Windows 10 or Windows 11.
- Write access to the current directory or the selected CSV/share.
- For multi-device collection, all technicians must use the same UNC path.

No PowerShell module installation, Intune sign-in, or cloud credential is required.

## Quick start

Create or append to `NOMMA-Autopilot.csv` in the current directory with no group tag:

```powershell
.\Export-NOMMAAutopilotDevice.ps1
```

Use one shared central file for multiple devices:

```powershell
.\Export-NOMMAAutopilotDevice.ps1 -CsvPath '\\fileserver\Deployment\Autopilot\NOMMA-Autopilot.csv'
```

Add a supported Autopilot group tag:

```powershell
.\Export-NOMMAAutopilotDevice.ps1 `
    -CsvPath '\\fileserver\Deployment\Autopilot\NOMMA-Autopilot.csv' `
    -GroupTag 'Cadet Devices'
```

## Group tags

| Tag | Intended devices |
|---|---|
| `Cadet Devices` | Cadet/student devices |
| `Teacher Devices` | Teacher/staff instructional devices |
| `IT Devices` | IT-managed/admin devices |
| `School Administrator Devices` | School leadership/administration devices |

Omit `-GroupTag` when the device should not receive an Autopilot group tag.

## Safety behavior

- Uses a `.lock` file so concurrent writers do not corrupt the shared CSV.
- Refuses to append a duplicate BIOS serial number or hardware hash.
- Refuses to append if an existing CSV does not have Intune's expected Autopilot headers.
- Does not enroll, wipe, import, or modify the device in Intune.

If a device crashes while writing, confirm no exporter is running before manually removing the adjacent `.lock` file.

## Import into Intune

1. Go to **Intune admin center** → **Devices** → **Windows** → **Windows enrollment**.
2. Open **Windows Autopilot devices**.
3. Select **Import**.
4. Upload the consolidated CSV.
5. Wait for import status to complete.

## Entra dynamic device groups

Create dynamic device groups with one of these membership rules:

```text
(device.devicePhysicalIds -any (_ -eq "[OrderID]:Cadet Devices"))
```

```text
(device.devicePhysicalIds -any (_ -eq "[OrderID]:Teacher Devices"))
```

```text
(device.devicePhysicalIds -any (_ -eq "[OrderID]:IT Devices"))
```

```text
(device.devicePhysicalIds -any (_ -eq "[OrderID]:School Administrator Devices"))
```

Use the group only after the Autopilot import has completed and the device shows its group tag.

## Built-in PowerShell help

```powershell
Get-Help .\Export-NOMMAAutopilotDevice.ps1 -Full
```
