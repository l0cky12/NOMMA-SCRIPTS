# Zabbix PowerShell Scripts

Scripts used to support Zabbix Agent 2 and Zabbix-related Windows setup tasks.

## Scripts

### `Setup-ZabbixAgent2ScriptFolder.ps1`
Clones the `zabbix-windows-ad-dhcp-dns-monitoring` repo, copies the `.ps1` files from `scripts/windows`, verifies the target folder, and cleans up the cloned repo afterward.

### `Deploy-ZabbixAgent2-PSK-Action1.ps1`
Action1 deployment script for an already-installed Zabbix Agent 2. It sets the Zabbix server address, uses the endpoint computer name as the Zabbix host name, creates a unique PSK, configures PSK in both directions, restricts inbound TCP 10050 to the Zabbix server, restarts the agent, and prints the values to enter in the Zabbix host encryption settings.

Before deployment, update `$ZabbixServer` at the top of the script if the server or proxy IP changes.

### Usage

```powershell
.\Setup-ZabbixAgent2ScriptFolder.ps1
```

```powershell
.\Setup-ZabbixAgent2ScriptFolder.ps1 -WhatIf
```
