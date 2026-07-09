# Zabbix PowerShell Scripts

Scripts used to support Zabbix Agent 2 and Zabbix-related Windows setup tasks.

## Scripts

### `Setup-ZabbixAgent2ScriptFolder.ps1`
Clones the `zabbix-windows-ad-dhcp-dns-monitoring` repo, copies the `.ps1` files from `scripts/windows`, verifies the target folder, and cleans up the cloned repo afterward.

### Usage

```powershell
.\Setup-ZabbixAgent2ScriptFolder.ps1
```

```powershell
.\Setup-ZabbixAgent2ScriptFolder.ps1 -WhatIf
```
