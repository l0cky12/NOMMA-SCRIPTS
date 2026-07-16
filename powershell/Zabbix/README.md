# Zabbix PowerShell Scripts

Scripts used to support Zabbix Agent 2 and Zabbix-related Windows setup tasks.

## Scripts

### `Setup-ZabbixAgent2ScriptFolder.ps1`
Clones the `zabbix-windows-ad-dhcp-dns-monitoring` repo, copies the `.ps1` files from `scripts/windows`, verifies the target folder, and cleans up the cloned repo afterward.

### `Deploy-ZabbixAgent2-PSK-Action1.ps1`
Action1 deployment script for an already-installed Zabbix Agent 2. It sets the Zabbix server address, uses the endpoint computer name as the Zabbix host name, creates a unique PSK, configures PSK in both directions, restricts inbound TCP 10050 to the Zabbix server, restarts the agent, and prints the values to enter in the Zabbix host encryption settings.

Before deployment, update `$ZabbixServer` at the top of the script if the server or proxy IP changes.

### `Test-ZabbixHyperV-Action1.ps1`
Read-only Action1 validation for the NOMMA Hyper-V Zabbix collector. Run it on actual Hyper-V hosts after deploying `Get-ZabbixHyperV.ps1` and `userparameter_hyperv.conf`. It validates the Agent 2 service, Hyper-V module, VMMS service, direct collector JSON, `hyperv.collect` UserParameter, active-check TCP reachability, and recent agent log entries.

### Usage

```powershell
.\Setup-ZabbixAgent2ScriptFolder.ps1
```

```powershell
.\Setup-ZabbixAgent2ScriptFolder.ps1 -WhatIf
```
