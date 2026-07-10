# Validation Report

Validation date: **2026-07-10 UTC**

## Executed and passed

| Check | Result |
|---|---|
| Zabbix 7.0 YAML parse | Passed with PyYAML 6.0.2 |
| Static template/LLD validation | **437 checks passed**: UUIDv4/uniqueness, item-key uniqueness, master references, trigger item/macro references, Replica collector-failure gates, LLD macro fixtures, documented macros/files, supported Replica cmdlet, path quoting, PowerShell ASCII safety, repository scope, and secret patterns |
| Real Zabbix template import | **Passed** against disposable Zabbix server/frontend **7.0.28** with PostgreSQL; two consecutive update imports also passed |
| Imported object verification | 31 host items, 6 discovery rules, 14 host triggers, 7 value maps; import API returned `result: true` |
| PowerShell parser | Passed for every `.ps1` file using the installed PowerShell parser |
| PowerShell fixture tests | **146 assertions passed** across all 15 required scenarios |
| PSScriptAnalyzer | PSScriptAnalyzer 1.25.0 returned no Error or Warning findings |
| Collector JSON/data shapes | Passed in fixture tests for host, backup, VM, Replica, volume, CSV, switch, and certificate arrays |
| Non-Hyper-V runtime behavior | Executed on the Linux development host under PowerShell: valid JSON, collector OK, role absent, zero VMs/replicas; two optional Windows-component errors were retained for diagnostics without failing collection |
| Template syntax/functions | Real 7.0.28 import accepted UUIDs, names, keys, macros, value maps, preprocessing, trigger functions/expressions, and prototype references |
| Whitespace/diff integrity | `git diff --check` passed |

The fixture suite covered: Hyper-V operational/absent, Replica enabled/disabled/healthy/warning/critical, VM running/intentionally off, standalone/clustered, CSV present/absent, permission denied, inaccessible/deleted VM, empty discovery, and PowerShell/CIM failure.

Machine-readable live import evidence is in `tests/live-import-result.json`.

## Executed and failed

No final validation check failed. During development, import validation rejected discovery-rule tags and UUIDv5 values; both were corrected. Microsoft Learn documentation review also caught use of the unsupported `Get-VMReplicationStatistics` name; it was replaced with Microsoft's supported `Measure-VMReplication` cmdlet and a regression assertion was added. All affected tests were rerun and passed.

## Not executed

| Check | Reason / remaining command |
|---|---|
| Live collector on Windows Server Hyper-V | No Windows Hyper-V host was available in the development environment. Run the direct collector and Agent 2 commands in `Setup.md` on one production-like host. |
| Live Replica healthy/degraded/resync/failure transitions | No live Replica relationship was available. Compare Zabbix values with `Get-VMReplication` and `Measure-VMReplication`, then perform an approved test failover/resync exercise. |
| Live Failover Cluster, Replica Broker, and CSV | No Windows failover cluster was available. Run `Get-ClusterNode`, `Get-ClusterResource`, and `Get-ClusterSharedVolume` under the agent identity. |
| Agent service-account execution | Zabbix Agent 2 was not installed on this Linux build host. On Windows run `zabbix_agent2.exe -t hyperv.collect` under the configured service account and inspect access errors. |
| Windows PowerShell 5.1 runtime | The build host has PowerShell Core, not Windows PowerShell 5.1. Syntax is 5.1-compatible and ASCII-only, but final runtime execution must occur on Windows Server. |
| Real backup provider and restore | No WSB/third-party backup environment was available. Validate provider status and perform a separate restore test. |
| Real certificate expiry/trust | No Replica certificate from the target hosts was available. Configure exact thumbprints and compare with `Cert:\LocalMachine\My`. Trust-chain negotiation is outside scope. |
| Classic Zabbix agent runtime | Agent 2 is recommended; classic agent was not available. Test its generated UserParameter if NOMMA chooses classic agent. |

## Limitations of validation

A successful template import proves Zabbix schema/expression acceptance, not that Windows exposes identical optional properties on every server build. The collector therefore uses supported cmdlets, tolerant property lookup, empty-array behavior, and component diagnostics. One-host production smoke testing remains mandatory before broad deployment.
