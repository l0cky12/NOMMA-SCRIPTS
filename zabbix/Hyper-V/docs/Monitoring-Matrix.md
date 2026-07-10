# Monitoring Matrix

All dependent values update when `hyperv.collect` runs every 60 seconds. Discovery adds no extra PowerShell process. Thresholds are template macros and should be adjusted to the actual RPO, backup schedule, and storage growth rate.

## Host and platform checks

| Metric or condition | Why it matters | Warning | Critical | Zabbix logic / recovery | Interval | Class | Collection |
|---|---|---:|---:|---|---:|---|---|
| Master JSON available | Proves agent/UserParameter path works | - | No data 5m | `nodata(hyperv.collect,5m)=1`; recovers on data | 1m | Essential | Agent UserParameter + PowerShell |
| Collector status/error | Separates collection failure from platform failure | - | `ok=0` for 3m | Recovers at `ok=1`; downstream triggers require collector OK | 1m | Essential | PowerShell |
| Collector duration | Detects timeout risk | Review above 15s | None by default | No trigger; investigate before 20s agent timeout | 1m | Optional support | PowerShell stopwatch |
| Hyper-V role detected | Prevents alerts on non-Hyper-V servers | None | None | Informational; absent role returns healthy empty data | 1m | Essential gate | Cmdlet/service detection |
| VMMS service | VM control plane | - | Down 3m | Requires role; recovery Running | 1m | Essential | `Get-Service vmms` |
| Host Compute service | VM compute lifecycle | Down 3m | - | Requires role and VMMS up; recovery Running | 1m | Essential | `Get-Service vmcompute` |
| VM total/running/critical | Daily fleet posture and unexpected count changes | No count trigger | Critical VMs alert per VM | Dashboard only to avoid change noise | 1m | Essential summary | `Get-VM` |
| Replica enabled/relationship counts | Confirms whether feature is in use | No trigger when disabled | Per-replica triggers | Disabled and empty are valid | 1m | Essential gate/summary | `Get-VMReplicationServer`, `Get-VMReplication` |
| Oldest replica lag | Fast RPO posture | >600s | >1800s | Per-replica sustained windows; recovery <300s | 1m | Essential summary | Replica timestamps |
| Cluster detected/service | Cluster control plane | - | Service down 3m | Only when cluster detected; recovery service up | 1m | Essential if clustered | FailoverClusters cmdlets/service |
| Local cluster node state | Host participation | - | Not Up 3m | Requires cluster service; recovery Up | 1m | Essential if clustered | `Get-ClusterNode` |
| Replica Broker present/online | Clustered Replica endpoint | - | Offline 3m | Only when broker resource exists | 1m | Essential if broker used | `Get-ClusterResource` |
| CSV count/unhealthy | Shared storage posture | No count trigger | Per-CSV offline | Empty is valid on standalone/non-CSV clusters | 1m | Essential if CSV | `Get-ClusterSharedVolume` |
| External vSwitch count/down | VM network availability | - | Uplink down 3m | Only external switches; per-switch context disable; VMMS gate | 1m | Essential | `Get-VMSwitch`, `Get-NetAdapter` |
| Minimum fixed-volume free % | Host capacity summary | <15% | <8% | Per-volume recovery >18% | 1m | Essential | CIM `Win32_Volume` |
| Critical/error Hyper-V events | Surfaces control-plane/storage failures | Any Level 1/2 event in 10m | Escalate by operations policy | Rolling window; recovers at count 0 | 1m | Essential | `Get-WinEvent` configured logs |
| CPU utilization | Sustained host exhaustion | Disabled to avoid duplicate warning | >95% for 15m | Recovery <85% for 10m | 1m | Essential capacity | CIM formatted processor data |
| Available memory | Paging/outage risk | <15% for 10m | <5% for 5m | Recovery >20% or >15% | 1m | Essential capacity | CIM OS memory |
| Backup monitor enabled/status | Backup failure indicator | - | Last job failed 5m | No alert when unsupported/disabled; recovery success | 1m | Recommended | WSB cmdlet or status JSON |
| Backup age | Backup freshness | >36h | >72h | Recovery <24h / <36h | 1m | Recommended | Last success timestamp |

## Per-VM checks

| Metric | Why | Warning | Critical | Logic / recovery | Interval | Class | Collection |
|---|---|---:|---:|---|---:|---|---|
| State | Finds unintentionally stopped/paused/saved VMs | Unexpected for two polls | Site may escalate selected VMs | Default expected state Running; context macro by VM ID supports intentional Off; VMMS/collector gated | 1m | Essential | `Get-VM` |
| Health/status | Hyper-V reports a VM-level failure | - | Bad status for 5m | Recovery healthy; collector/VMMS gated | 1m | Essential | `Get-VM` invariant properties |
| Heartbeat | Guest OS hang or integration failure | Unavailable 5m while Running | Optional escalation | Disabled/off heartbeat does not alert for stopped VM; recovery heartbeat or VM stops | 1m | Essential | Integration service invariant GUID |
| Uptime | Confirms recent restart and aids triage | No default alert | None | Dashboard/latest data only | 1m | Optional | `Get-VM` |

## Per-replica checks

| Metric | Why | Warning | Critical | Logic / recovery | Interval | Class | Collection |
|---|---|---:|---:|---|---:|---|---|
| Replication health | Primary Microsoft health signal | Warning 5m | Critical 3m | Mutually exclusive; recovery state changes; context macro can disable one relationship | 1m | Essential | `Get-VMReplication` |
| Replication state/status | Detects suspended/critical relationships | - | Suspended, Critical, or Resync-suspended 5m | Health-critical suppression; recovery Replicating/Prepared | 1m | Essential | `Get-VMReplication` |
| Mode/relationship type | Distinguishes primary, replica, extended relationships | None | None | Informational, no alert | 1m | Essential context | `Get-VMReplication` |
| Last successful replication | Direct recovery-point freshness | Derived through lag | Derived through lag | Stored as Unix time | 1m | Essential | Relationship/statistics timestamp |
| Replication lag | RPO violation | >600s for 10m | >1800s for 5m | Warning/critical mutually exclusive; recovery <300s/<600s | 1m | Essential | Current time minus last success |
| Replication errors | Active replication-cycle errors | >0 for 5m | Health trigger handles critical | Suppressed when health already critical; recovery 0 | 1m | Essential | `Measure-VMReplication` |
| Backlog | Link/storage inability to drain pending data | >1GiB for 10m | Set site-specific critical if needed | Recovery <512MiB; zero when property unavailable | 1m | Recommended | Statistics supported property |
| Resynchronizing | Extended protection gap | Active >30m | Escalate by RPO policy | Recovery when complete | 1m | Essential | Replication state |
| Failover readiness | Relationship not ready despite normal health | Failed 15m | Optional escalation | Requires health Normal and not resyncing to prevent duplicates | 1m | Essential | Computed health/state/freshness |

## Storage, CSV, network, certificate

| Metric | Warning | Critical | Logic / recovery | Interval | Class | Collection |
|---|---:|---:|---|---:|---|---|
| Fixed volume free % | <15% 10m | <8% 5m | Recovery >18%; exclude recovery/system labels and small volumes | 1m | Essential | CIM |
| CSV online | - | Offline 3m | Cluster-service gated; recovery Online | 1m | Essential if CSV | FailoverClusters |
| CSV free % | <20% 10m | <10% 5m | Recovery >25%/>20% | 1m | Essential if CSV | CSV partition info |
| External vSwitch uplink | - | Down 3m | Only external switches; context macro disable | 1m | Essential | Hyper-V + NetAdapter |
| Configured certificate valid | - | Missing/not valid 3m | Only exact configured thumbprints are discovered | 1m | Essential for HTTPS Replica | LocalMachine certificate store |
| Certificate days remaining | <30d | <14d | Recovery >45d/>30d | 1m | Essential for HTTPS Replica | Certificate `NotAfter` |

## Noise control and dependencies

- No role, relationships, cluster, CSVs, certificates, or backup provider means no feature alert.
- Collector failure and VMMS/cluster-service failures gate downstream expressions.
- Health-critical, lag, state, errors, resync, and readiness expressions are mutually gated to reduce duplicate Replica events.
- VM context macros allow intentional Off states: `{$HYPERV.VM.EXPECTED.STATE:"<VM-ID>"}=0` or disable all VM triggers with `{$HYPERV.VM.MONITOR:"<VM-ID>"}=0`.
- Replica, volume, and switch context macros provide the same per-object suppression without editing discovery.
- Warning and critical storage/lag/backup/certificate ranges are mutually exclusive and use lower recovery thresholds.
- Empty discovery and deleted VMs age out after seven days rather than producing a deleted-object alert.

## Keep disabled unless troubleshooting

Per-vCPU runtime/queue, per-VM memory pressure, per-VHD IOPS/latency/throughput, per-vNIC packets/throughput, NUMA spanning counters, checkpoint inventory alarms, replication transfer-size/latency graphs, all individual event IDs, internal/private switch discovery, and physical NIC error-rate triggers. These are useful during diagnosis, but create cardinality, baseline work, and alert noise in daily operations.
