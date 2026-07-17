# PowerShell Scripts

All PowerShell scripts now live in category folders under `powershell/`.
There are no standalone `.ps1` files in this folder root.

## Folders

- `Windows-AD-Server/` — Active Directory / DC / CA cleanup and diagnostics
- `Windows-Endpoint-Management/` — endpoint rename and Autopilot-related scripts
- `Windows-DHCP-Server/` — Windows DHCP Server automation scripts
- `Zabbix/` — Zabbix Agent / monitoring helper scripts

## Quick map

### `Windows-AD-Server/`
- `Cleanup-ADMetadata.ps1`
- `Invoke-NOMMA-DC-CA-Diagnostics.ps1`
- `Test-ADCSIssuingCAConnection.ps1` — read-only native AD CS Issuing CA connectivity and authentication validation for Windows endpoints
- `Invoke-PrinterCertCADiagnostic.ps1` — read-only printer DNS, connectivity, and Issuing CA certificate-path diagnostics
- `New-BrotherPrinterTlsCertificate.ps1` — creates and validates a SAN-correct Brother HTTPS certificate PFX from the Issuing CA

### `Windows-Endpoint-Management/`
- `Export-NOMMAAutopilotDevice.ps1` - safely appends a local device's serial number, hardware hash, and approved group tag to a shared Intune Autopilot CSV
- `New-IntuneWinPackage.ps1` — downloads Microsoft’s packaging tool and creates an `.intunewin` from one `.msi`, `.exe`, or `.ps1`
- `rename-pc.ps1`

### `Windows-DHCP-Server/`
- `Configure-DhcpServer.ps1`
- `scripts/` — numbered DHCP helper scripts

### `Zabbix/`
- `Setup-ZabbixAgent2ScriptFolder.ps1`

## Usage examples

```powershell
cd .\Windows-AD-Server
.\Invoke-NOMMA-DC-CA-Diagnostics.ps1
```

```powershell
cd .\Windows-AD-Server
.\Invoke-PrinterCertCADiagnostic.ps1 -PrinterHost "b-4024.nomma.tech"
```

```powershell
cd .\Windows-Endpoint-Management
.\rename-pc.ps1 -CsvPath "C:\ProgramData\Intune\rename-list.csv"
```

```powershell
cd .\Zabbix
.\Setup-ZabbixAgent2ScriptFolder.ps1
```

```powershell
cd .\Windows-DHCP-Server
.\Configure-DhcpServer.ps1
```
