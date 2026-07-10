# Setup: NOMMA Hyper-V and Hyper-V Replica Monitoring

## 1. Purpose and scope

This solution monitors operational health for Hyper-V hosts, VMs, Hyper-V Replica, fixed storage, failover clustering and CSVs when present, external VM networking, critical Hyper-V event logs, resource exhaustion, backup freshness, and configured Replica certificates. It deliberately excludes high-cardinality performance telemetry.

## 2. Supported platforms

- Windows Server 2019, 2022, and 2025 with the Hyper-V role.
- Standalone hosts and Failover Clustering hosts.
- Windows PowerShell 5.1 or PowerShell 7.x; production collection is designed for built-in Windows PowerShell 5.1.
- Windows Server 2016 is best-effort only because several Replica/cluster properties differ and it was not live-tested.
- Zabbix Agent 2 7.0 is recommended. Classic Zabbix agent 7.0 is supported through the same `UserParameter`.

## 3. Verified Zabbix version

- **Exact target and live import test:** Zabbix **7.0.28 LTS**.
- **Verification date:** **2026-07-10 UTC**.
- Official references: [Zabbix lifecycle](https://www.zabbix.com/life_cycle_and_release_policy), [downloads](https://www.zabbix.com/download_sources), [7.0.28 release notes](https://www.zabbix.com/rn/rn7.0.28), and [7.0 template format](https://www.zabbix.com/documentation/7.0/en/manual/xml_export_import/templates).
- Zabbix 7.4.12 was the latest standard release observed. It is supported only until 8.0 LTS; 7.0 LTS has full support through 2027-06-30 and limited support through 2029-06-30. NOMMA therefore targets 7.0 LTS.
- Supported fallback: later patched Zabbix 7.0.x server and matching 7.0 agent. Forward import to 7.4 is expected but not validated here. Zabbix 6.0 or earlier is unsupported.

## 4. Agent requirements

Install an agent version no newer than the server major release. Agent 2 is preferred for current Windows support, but this solution does not require Agent 2 plugins.

Verify:

```powershell
& 'C:\Program Files\Zabbix Agent 2\zabbix_agent2.exe' -V
$PSVersionTable.PSVersion
```

For classic agent, replace `Zabbix Agent 2\zabbix_agent2.exe` with `Zabbix Agent\zabbix_agentd.exe`.

## 5. Roles, modules, services, and permissions

Required for the base solution:

```powershell
Get-WindowsFeature Hyper-V
Get-Service vmms,vmcompute
Get-Command Get-VM,Get-VMSwitch,Get-VMReplication -ErrorAction Stop
```

Conditional requirements:

```powershell
# Cluster/CSV/Replica Broker only
Get-WindowsFeature Failover-Clustering
Get-Command Get-ClusterNode,Get-ClusterSharedVolume,Get-ClusterResource

# Windows Server Backup provider only
Get-WindowsFeature Windows-Server-Backup
Get-Command Get-WBJob
```

The collector uses only built-in modules: `Hyper-V`, `FailoverClusters` when present, `WindowsServerBackup` when selected, CIM, `Get-WinEvent`, `Get-NetAdapter`, and the LocalMachine certificate store. It does not install modules or make remote changes.

### Service account

The recommended Agent 2 service identity is the default **Local System** account. Confirm it:

```powershell
Get-CimInstance Win32_Service -Filter "Name='Zabbix Agent 2'" |
  Select-Object Name,StartName,State
```

A custom least-privilege account needs, at minimum:

- membership in local `Hyper-V Administrators`, `Performance Monitor Users`, and `Event Log Readers`;
- read access to the Hyper-V WMI/CIM namespaces and configured event logs;
- read access to local cluster state on clustered nodes;
- read access to the configured backup status file and certificate public metadata.

Do not grant Domain Admin. Cluster and Windows Server Backup cmdlets may still require local administrative rights depending on hardening and version. Test under the actual service identity before rollout. To test Local System interactively, use an approved SYSTEM-shell tool in a maintenance window; do not store account passwords in the agent configuration.

## 6. Repository layout

- `templates/template_hyperv_replica_7.0.yaml`: importable Zabbix template.
- `scripts/Get-ZabbixHyperVData.ps1`: one-call JSON collector.
- `scripts/Install-ZabbixHyperVMonitoring.ps1`: idempotent installer/uninstaller with `-WhatIf`.
- `userparameters/hyperv.conf`: reference Agent 2 UserParameter.
- `config/hyperv-monitoring.example.json`: non-secret feature configuration.
- `tests/`: parser, fixture, static-schema, and live-import evidence.
- `docs/`: check matrix, dashboard, and validation results.

## 7. Execution policy

The UserParameter invokes Windows PowerShell with process-only `-ExecutionPolicy Bypass`. This does not change machine policy. If AppLocker/WDAC blocks unsigned scripts, sign the production copy with the organization's code-signing certificate and change the UserParameter to `-ExecutionPolicy AllSigned`. Check policy with:

```powershell
Get-ExecutionPolicy -List
Get-AuthenticodeSignature 'C:\Program Files\Zabbix Agent 2\scripts\Hyper-V\Get-ZabbixHyperVData.ps1'
```

## 8. Installation paths

Agent 2 defaults:

```text
C:\Program Files\Zabbix Agent 2\scripts\Hyper-V\Get-ZabbixHyperVData.ps1
C:\Program Files\Zabbix Agent 2\scripts\Hyper-V\hyperv-monitoring.json
C:\Program Files\Zabbix Agent 2\zabbix_agent2.d\hyperv.conf
```

Classic agent defaults replace `Zabbix Agent 2` with `Zabbix Agent` and use `zabbix_agentd.d`.

## 9. Install files

Copy or clone this repository to the host. From an elevated Windows PowerShell prompt in `zabbix\Hyper-V\scripts`, run the dry-run first:

```powershell
Set-Location 'C:\Path\To\NOMMA-SCRIPTS\zabbix\Hyper-V\scripts'
.\Install-ZabbixHyperVMonitoring.ps1 -AgentFlavor Agent2 -WhatIf
```

Review the paths, then install:

```powershell
.\Install-ZabbixHyperVMonitoring.ps1 -AgentFlavor Agent2
```

For a nonstandard install:

```powershell
.\Install-ZabbixHyperVMonitoring.ps1 -AgentFlavor Agent2 -AgentRoot 'D:\Zabbix Agent 2' -WhatIf
.\Install-ZabbixHyperVMonitoring.ps1 -AgentFlavor Agent2 -AgentRoot 'D:\Zabbix Agent 2'
```

The installer overwrites the collector and managed `hyperv.conf`, but preserves an existing `hyperv-monitoring.json`.

## 10. UserParameter and agent configuration

The installed file contains exactly one agent-side key:

```text
UserParameter=hyperv.collect,powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:\Program Files\Zabbix Agent 2\scripts\Hyper-V\Get-ZabbixHyperVData.ps1" -ConfigPath "C:\Program Files\Zabbix Agent 2\scripts\Hyper-V\hyperv-monitoring.json"
```

Confirm the main Agent 2 configuration contains these effective settings:

```text
Include=C:\Program Files\Zabbix Agent 2\zabbix_agent2.d\*.conf
Timeout=20
```

Inspect without revealing PSK material:

```powershell
Select-String -Path 'C:\Program Files\Zabbix Agent 2\zabbix_agent2.conf' -Pattern '^(Include|Timeout|Server|ServerActive|Hostname)='
```

Set `Server`, `ServerActive`, and `Hostname` to the actual Zabbix server/proxy addresses and exact host name. Those environment-specific values are intentionally not invented by this repository.

Validate and restart:

```powershell
& 'C:\Program Files\Zabbix Agent 2\zabbix_agent2.exe' -T -c 'C:\Program Files\Zabbix Agent 2\zabbix_agent2.conf'
Restart-Service 'Zabbix Agent 2'
Get-Service 'Zabbix Agent 2'
Get-WinEvent -LogName Application -MaxEvents 50 |
  Where-Object ProviderName -Like '*Zabbix*' |
  Select-Object -First 10 TimeCreated,LevelDisplayName,Message
```

If `-T` is unavailable in the installed build, start the service and inspect its log instead.

## 11. Local key and collector testing

Test the only executable custom agent key:

```powershell
& 'C:\Program Files\Zabbix Agent 2\zabbix_agent2.exe' `
  -t hyperv.collect `
  -c 'C:\Program Files\Zabbix Agent 2\zabbix_agent2.conf'
```

Test the collector directly and verify JSON:

```powershell
$json = & 'C:\Program Files\Zabbix Agent 2\scripts\Hyper-V\Get-ZabbixHyperVData.ps1' `
  -ConfigPath 'C:\Program Files\Zabbix Agent 2\scripts\Hyper-V\hyperv-monitoring.json'
$data = $json | ConvertFrom-Json
$data.collector
$data.host
$data.backup
$data.vms | Format-Table name,state,health,heartbeat
$data.replicas | Format-Table name,mode,health,state,lag_seconds,errors,backlog_bytes,resynchronizing,failover_ready
$data.volumes | Format-Table name,free_percent
$data.csvs | Format-Table name,state,free_percent
$data.switches | Format-Table name,adapter,up
$data.certificates | Format-Table subject,thumbprint,valid,days_remaining
```

All other custom keys are Zabbix dependent items; an agent binary cannot test them because they are evaluated on the server. Test every extraction after linking by opening **Monitoring -> Latest data**, filtering `Hyper-V`, and confirming these prefixes populate: `hyperv.collector.*`, `hyperv.host.*`, `hyperv.vm.*`, `hyperv.replica.*`, `hyperv.volume.*`, `hyperv.csv.*`, `hyperv.switch.*`, `hyperv.cert.*`, and `hyperv.backup.*`.

## 12. Configure optional collection

Edit this exact file as Administrator:

```powershell
notepad 'C:\Program Files\Zabbix Agent 2\scripts\Hyper-V\hyperv-monitoring.json'
```

Validate after every edit:

```powershell
Get-Content 'C:\Program Files\Zabbix Agent 2\scripts\Hyper-V\hyperv-monitoring.json' -Raw | ConvertFrom-Json | Format-List
```

### Hyper-V Replica

No collector setting enables Replica; existing relationships are discovered automatically. Verify:

```powershell
Get-VMReplicationServer
Get-VMReplication | Select-Object VMName,VMId,Mode,ReplicationHealth,ReplicationState,LastReplicationTime
Get-VMReplication | ForEach-Object { Measure-VMReplication -VMName $_.VMName }
```

If replication is intentionally unused, leave it disabled. Empty discovery does not alert.

### Cluster, CSV, and Replica Broker

No setting is required. Verify local visibility:

```powershell
Get-ClusterNode $env:COMPUTERNAME | Select-Object Name,State
Get-ClusterSharedVolume | Select-Object Name,State
Get-ClusterResource | Where-Object ResourceType -Match 'Virtual Machine Replica Broker' | Select-Object Name,State,ResourceType
```

A standalone host returns empty cluster/CSV data and does not alert.

### Certificate-based replication

Discover exact LocalMachine thumbprints:

```powershell
Get-ChildItem Cert:\LocalMachine\My |
  Select-Object Subject,Thumbprint,NotBefore,NotAfter,HasPrivateKey
```

Add only the certificate(s) used by Replica to `certificateThumbprints`, with no spaces. Example:

```json
"certificateThumbprints": [
  "0123456789ABCDEF0123456789ABCDEF01234567"
]
```

The value above is an example format, not a real certificate. The collector reads validity and expiry only; it does not export private keys.

### Backup monitoring

Default `"backupProvider": "Auto"` uses Windows Server Backup when `Get-WBJob` is available. Set `"backupProvider": "None"` to disable it explicitly.

For another backup product, make that product write a protected JSON status file after each job:

```json
{
  "status": "Success",
  "completedUtc": "2026-07-10T00:30:00Z"
}
```

Then set:

```json
"backupProvider": "File",
"backupStatusFile": "C:\\ProgramData\\NOMMA\\BackupStatus\\hyperv-backup.json"
```

Protect the directory so Administrators, SYSTEM, and the backup process can write; the Zabbix service identity needs read only:

```powershell
New-Item -ItemType Directory -Path 'C:\ProgramData\NOMMA\BackupStatus' -Force
icacls 'C:\ProgramData\NOMMA\BackupStatus' /inheritance:r
icacls 'C:\ProgramData\NOMMA\BackupStatus' /grant:r 'SYSTEM:(OI)(CI)F' 'BUILTIN\Administrators:(OI)(CI)F'
```

Add the backup service identity explicitly if it is not SYSTEM. **Test ACL changes on one host first.** Rollback: `icacls <path> /reset /T`.

## 13. Import and link the template

1. In Zabbix 7.0.28, open **Data collection -> Templates**.
2. Select **Import**.
3. Choose `zabbix/Hyper-V/templates/template_hyperv_replica_7.0.yaml`.
4. Keep Create new and Update existing enabled; do not select Delete missing.
5. Import. Expected result: successful import of `NOMMA Hyper-V and Replica by Zabbix agent`.
6. Open the Hyper-V host under **Data collection -> Hosts**.
7. Add a standard **Agent** interface using the host's management address and port 10050.
8. Link `NOMMA Hyper-V and Replica by Zabbix agent`.
9. Also link the official `Windows by Zabbix agent` template for baseline Windows/agent checks; this custom template intentionally does not duplicate them.

For active-only collection, the Agent interface is still useful for inventory, but `hyperv.collect` must be changed to Zabbix agent (active) in a local template clone. The shipped template uses passive polling.

## 14. Macros and defaults

Template defaults:

| Macro | Default | Purpose |
|---|---:|---|
| `{$HYPERV.VM.MONITOR}` | 1 | Enable per-VM triggers |
| `{$HYPERV.VM.EXPECTED.STATE}` | 1 | Expected VM state; 1 Running, 0 Off |
| `{$HYPERV.REPLICA.MONITOR}` | 1 | Enable per-relationship triggers |
| `{$HYPERV.REPLICA.LAG.WARN}` | 600s | Replica lag warning |
| `{$HYPERV.REPLICA.LAG.CRIT}` | 1800s | Replica lag critical |
| `{$HYPERV.REPLICA.LAG.RECOVERY}` | 300s | Replica lag recovery |
| `{$HYPERV.REPLICA.BACKLOG.WARN}` | 1073741824 bytes | Backlog warning (1 GiB) |
| `{$HYPERV.REPLICA.BACKLOG.RECOVERY}` | 536870912 bytes | Backlog recovery (512 MiB) |
| `{$HYPERV.REPLICA.RESYNC.MAX}` | 30m | Maximum normal resync duration |
| `{$HYPERV.VOLUME.MONITOR}` | 1 | Enable fixed-volume triggers |
| `{$HYPERV.VOLUME.WARN}` | 15% | Fixed-volume warning |
| `{$HYPERV.VOLUME.CRIT}` | 8% | Fixed-volume critical |
| `{$HYPERV.VOLUME.RECOVERY}` | 18% | Fixed-volume recovery |
| `{$HYPERV.CSV.WARN}` | 20% | CSV warning |
| `{$HYPERV.CSV.CRIT}` | 10% | CSV critical |
| `{$HYPERV.CSV.RECOVERY}` | 25% | CSV recovery |
| `{$HYPERV.SWITCH.MONITOR}` | 1 | Enable external-vSwitch triggers |
| `{$HYPERV.CPU.CRIT}` | 95% | Sustained CPU critical |
| `{$HYPERV.CPU.RECOVERY}` | 85% | CPU recovery |
| `{$HYPERV.MEM.WARN}` | 15% | Available-memory warning |
| `{$HYPERV.MEM.CRIT}` | 5% | Available-memory critical |
| `{$HYPERV.MEM.RECOVERY}` | 20% | Memory recovery |
| `{$HYPERV.BACKUP.WARN}` | 129600s (36h) | Backup-age warning |
| `{$HYPERV.BACKUP.CRIT}` | 259200s (72h) | Backup-age critical |
| `{$HYPERV.BACKUP.RECOVERY}` | 86400s (24h) | Backup-age recovery |
| `{$HYPERV.CERT.WARN}` | 30d | Certificate warning |
| `{$HYPERV.CERT.CRIT}` | 14d | Certificate critical |
| `{$HYPERV.CERT.RECOVERY}` | 45d | Certificate recovery |

Find immutable IDs:

```powershell
Get-VM | Select-Object Name,Id
Get-VMReplication | Select-Object VMName,VMId
Get-VMSwitch | Select-Object Name,Id,SwitchType
```

To allow one planned-off VM, define on the host:

```text
{$HYPERV.VM.EXPECTED.STATE:"22222222-2222-2222-2222-222222222222"}=0
```

To disable monitoring for one replica, volume, or switch:

```text
{$HYPERV.REPLICA.MONITOR:"<replica VM ID>"}=0
{$HYPERV.VOLUME.MONITOR:"<discovered volume ID>"}=0
{$HYPERV.SWITCH.MONITOR:"<vSwitch ID>"}=0
```

Use the exact discovery ID shown in Latest data. Context macros override the global default and prevent alerts without editing discovery.

## 15. Firewall and network

- Passive agent: allow TCP 10050 inbound **only** from the Zabbix server/proxy.
- Active agent, if using a cloned active template: allow TCP 10051 outbound to the Zabbix server/proxy.
- DNS and time synchronization must work.
- Hyper-V Replica ports (Kerberos HTTP 80 or certificate HTTPS 443) are outside this collector; existing Replica firewall rules must remain correct.
- The collector makes no remote network connection and requires no WinRM.

## 16. Polling, retention, and thresholds

The master item runs every 60 seconds; all dependent metrics share that sample. Discovery is dependent and adds no PowerShell process. Suggested history:

- Health/state/summary items: 30-90 days.
- Trendable capacity, lag, backlog, and free-percent items: 365 days of trends.
- Raw master JSON: 1 day, no trends.
- Text/error/mode: 7 days, no trends.

Use an RPO-derived Replica warning: normally two missed replication cycles. Set critical to the maximum tolerable recovery-point age, not an arbitrary larger number. Set backup warning slightly beyond one normal backup interval plus scheduling tolerance.

## 17. Trigger dependency and recovery behavior

- No-data identifies agent/UserParameter failure.
- Collector failure gates VM, Replica, storage, network, and cluster prototype expressions.
- VMMS failure gates VM and switch alerts.
- Cluster service failure gates node, Broker, and CSV alerts.
- Replica health Critical suppresses lower-value state/error/readiness conditions where possible.
- Warning and critical lag/storage/backup/certificate ranges do not overlap.
- Recovery thresholds are lower than problem thresholds to avoid flapping.
- Intentionally unused features yield `enabled=0`, `present=0`, or empty discovery and generate no problem.

## 18. Deployment validation

Run on one host before bulk deployment:

```powershell
Set-Location 'C:\Path\To\NOMMA-SCRIPTS\zabbix\Hyper-V'
.\tests\Test-HyperVMonitoring.ps1
& 'C:\Program Files\Zabbix Agent 2\zabbix_agent2.exe' -t hyperv.collect
```

In Zabbix confirm:

1. Master item is supported and returns JSON under 20 seconds.
2. `Hyper-V: Role installed=1`, collector status 1, and service values 1.
3. VM names/IDs match `Get-VM`.
4. Replica values match `Get-VMReplication`.
5. Cluster/CSV results match local cmdlets, or remain empty on standalone hosts.
6. Only configured certificate thumbprints appear.
7. Backup status/age matches the provider.
8. No duplicate or false problem appears during a normal 15-minute observation.

## 19. Expected output

Abbreviated healthy output:

```json
{"schema_version":1,"collector":{"ok":1,"error":""},"host":{"role_installed":1,"vmms_service":1,"replica_critical":0},"backup":{"enabled":1,"status":1},"vms":[{"name":"APP01","state":1,"health":1,"heartbeat":1}],"replicas":[{"name":"APP01","health":1,"state":1,"mode":"Primary","lag_seconds":45,"failover_ready":1}],"csvs":[],"certificates":[]}
```

Healthy VM state is 1; healthy Replica health is 1; ready/up values are 1. Feature-not-applicable values are usually `-1`, `0`, or an empty array and are gated from alerts.

## 20. Common errors and fixes

- **Unsupported key:** confirm `Include` loads `zabbix_agent2.d\*.conf`, validate config, and restart Agent 2.
- **Timeout while executing shell command:** keep `Timeout=20`, run the collector directly, and inspect `duration_ms`/`component_errors`. Do not increase blindly beyond site policy.
- **Access is denied from `Get-VM`:** verify the service identity and Hyper-V Administrators membership; restart Agent 2 after token/group changes.
- **PowerShell script blocked:** run `Unblock-File`, inspect AppLocker/WDAC logs, and sign the script if policy requires.
- **Replica array empty:** verify `Get-VMReplication` returns relationships under the service identity. Disabled Replica is valid.
- **CSV empty on a cluster:** verify FailoverClusters module and `Get-ClusterSharedVolume`; CSVs may not be used.
- **Certificate absent:** confirm the exact no-space thumbprint exists in `Cert:\LocalMachine\My`.
- **Backup disabled:** set an explicit provider and verify the WSB module or protected status file.
- **Item preprocessing error:** inspect the master JSON first; then compare the JSON field with the template JSONPath.

Useful triage:

```powershell
Get-Content 'C:\Program Files\Zabbix Agent 2\zabbix_agent2.log' -Tail 200
Get-WinEvent -LogName 'Microsoft-Windows-Hyper-V-VMMS-Admin' -MaxEvents 20
Get-WinEvent -LogName 'Microsoft-Windows-Hyper-V-Worker-Admin' -MaxEvents 20
Get-VM | Format-List Name,Id,State,Status,OperationalStatus
Get-VMReplication | Format-List *
Get-ClusterGroup | Format-Table Name,State,OwnerNode
Get-ClusterSharedVolume | Format-List *
```

## 21. Upgrade procedure

1. Read the target Zabbix release notes and template-format documentation.
2. Export the currently imported template as a backup.
3. Test the new server/agent patch in nonproduction.
4. Run `tests/validate.py`, PowerShell tests, PSScriptAnalyzer, and a real API/UI import against the exact target version.
5. Use the installer `-WhatIf`, deploy one host, observe for one day, then expand.
6. Preserve the existing `hyperv-monitoring.json`; the installer already does this.

Do not import this 7.0 export into an older Zabbix release.

## 22. Rollback and uninstall

**Test uninstall on one host before bulk removal.**

```powershell
Set-Location 'C:\Path\To\NOMMA-SCRIPTS\zabbix\Hyper-V\scripts'
.\Install-ZabbixHyperVMonitoring.ps1 -AgentFlavor Agent2 -Uninstall -WhatIf
.\Install-ZabbixHyperVMonitoring.ps1 -AgentFlavor Agent2 -Uninstall
Restart-Service 'Zabbix Agent 2'
```

Then unlink the template from the host. Choose **Clear and unlink** only if historical custom item data should be deleted; ordinary unlink preserves it. Rollback is to restore the previous template export and previous installed script/config copies.

## 23. Security considerations

- No credentials, private keys, certificate exports, server names, tokens, or tenant values are stored.
- Collection is local and read-only.
- Keep the script/config directory writable only by Administrators and SYSTEM.
- Restrict passive agent source addresses and use Zabbix PSK or certificate transport according to site policy.
- Treat VM names and event/error text as operationally sensitive; limit Zabbix role access and retention.
- The optional backup status file must not be writable by ordinary users, or monitoring can be spoofed.

## 24. Known limitations

- Live collection was not run on an actual Hyper-V/cluster host in the development environment; fixture scenarios and PowerShell parsing were used, and production smoke testing remains mandatory.
- Replica backlog properties vary by Windows release; unsupported properties report 0 rather than a false error.
- Failover readiness is a computed operational indicator, not a substitute for scheduled test failovers and documented recovery exercises.
- Backup monitoring confirms job status/freshness, not recoverability. Periodic restore tests are still required.
- Certificate monitoring requires explicit thumbprints and does not validate trust-chain or remote endpoint negotiation.
- Event monitoring counts current critical/error events in selected logs; it intentionally avoids noisy per-event discovery and does not expose full event text.
- The shipped template is passive-agent. Clone only the master item to active mode if active checks are required.
- Classic agent is supported but was not live-executed in this development environment.
