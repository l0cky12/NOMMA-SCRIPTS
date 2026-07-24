# Zabbix PowerShell Scripts

Scripts used to support Zabbix Agent 2 and Zabbix-related Windows setup tasks.

## Scripts

### `Setup-ZabbixAgent2ScriptFolder.ps1`
Clones the `zabbix-windows-ad-dhcp-dns-monitoring` repo, copies the `.ps1` files from `scripts/windows`, verifies the target folder, and cleans up the cloned repo afterward.

### `Install-ZabbixAgent2-PSK.ps1`
Full install of Zabbix Agent 2 from scratch on Windows Server 2012 R2+ with PSK encryption. Downloads the MSI from cdn.zabbix.com, installs silently, writes the PSK file, configures `zabbix_agent2.conf` for TLS/PSK pointing at `10.1.2.61`, optionally creates a firewall rule restricting TCP 10050 to the Zabbix server, restarts the service, and outputs the PSK identity + value needed in the Zabbix frontend.

**For interactive PowerShell use only** — not compatible with Action1.

```powershell
.\Install-ZabbixAgent2-PSK.ps1
.\Install-ZabbixAgent2-PSK.ps1 -ZabbixServer '10.1.2.61' -ConfigureFirewall
.\Install-ZabbixAgent2-PSK.ps1 -SkipInstall -ConfigureFirewall
```

### `Install-ZabbixAgent2-PSK-Action1.ps1`
Action1-compatible version of `Install-ZabbixAgent2-PSK.ps1` (no `[CmdletBinding()]` or typed parameters — Action1's PS engine rejects those). Downloads and installs Zabbix Agent 2 from scratch, configures PSK encryption, creates a unique random PSK, optionally creates a firewall rule, and outputs the PSK identity + value.

Edit the variables at the top of the script (`$ZabbixServer`, `$ConfigureFirewall`) before deploying through Action1.

### `Deploy-ZabbixAgent2-PSK-Action1.ps1`
Action1 deployment script for an already-installed Zabbix Agent 2. It sets the Zabbix server address, uses the endpoint computer name as the Zabbix host name, creates a unique PSK, configures PSK in both directions, restricts inbound TCP 10050 to the Zabbix server, restarts the agent, and prints the values to enter in the Zabbix host encryption settings.

Before deployment, update `$ZabbixServer` at the top of the script if the server or proxy IP changes.

### `Test-ZabbixHyperV-Action1.ps1`
Read-only Action1 validation for the NOMMA Hyper-V Zabbix collector. Run it on actual Hyper-V hosts after deploying `Get-ZabbixHyperV.ps1` and `userparameter_hyperv.conf`. It validates the Agent 2 service, Hyper-V module, VMMS service, direct collector JSON, `hyperv.collect` UserParameter, active-check TCP reachability, and recent agent log entries.

### `Repair-ZabbixHyperVCollector-Action1.ps1`
Action1 remediation for actual Hyper-V hosts. It downloads the current public Hyper-V collector and UserParameter file, increases the Agent 2 timeout to 30 seconds without adding a UTF-8 BOM, restarts Agent 2, and prints direct and Agent 2 collector output. It creates a timestamped backup of `zabbix_agent2.conf` before changing the timeout.

### Usage

```powershell
.\Setup-ZabbixAgent2ScriptFolder.ps1
```

```powershell
.\Setup-ZabbixAgent2ScriptFolder.ps1 -WhatIf
```
