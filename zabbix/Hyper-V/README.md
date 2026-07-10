# NOMMA Hyper-V and Hyper-V Replica Monitoring

Lean, production-oriented Zabbix monitoring for Windows Server Hyper-V hosts. One read-only PowerShell call returns JSON; Zabbix dependent items and low-level discovery extract the operational signals without launching PowerShell per metric.

## Verified Zabbix target

- **Built and live-import tested:** Zabbix **7.0.28 LTS**
- **Verification date:** **2026-07-10 UTC**
- **Latest standard release observed:** Zabbix **7.4.12**
- **Why 7.0 LTS:** the official lifecycle page lists 7.0 LTS full support through 2027-06-30 and limited support through 2029-06-30. Zabbix 7.4 is a standard release supported until 8.0 LTS, planned for Q4 2026. The LTS line is the safer production target for NOMMA.
- **Official sources:** [lifecycle policy](https://www.zabbix.com/life_cycle_and_release_policy), [source downloads](https://www.zabbix.com/download_sources), [7.0.28 release notes](https://www.zabbix.com/rn/rn7.0.28), and [7.0 template import format](https://www.zabbix.com/documentation/7.0/en/manual/xml_export_import/templates).
- **Fallback:** later 7.0.x patches should remain compatible. Import into 7.4 is normally forward-compatible but was not the production target. Zabbix 6.0 and earlier are not supported by this export.

Zabbix Agent 2 7.0 is recommended. The classic Zabbix agent 7.0 is supported because collection uses a standard `UserParameter`; no Agent 2-only plugin is required.

## Design

- 31 host-level items: 27 operational/summary checks plus four collector/support values.
- Four items per discovered VM: state, health, heartbeat, and uptime.
- Nine items per discovered replica relationship: health, state, mode, last successful replication, lag, errors, backlog, resynchronization, and failover readiness.
- Conditional discovery for fixed volumes, CSVs, external switches, and configured certificates.
- Optional features do not alert when absent: no replica relationships, no cluster, no CSVs, no certificate thumbprints, and no supported backup provider produce empty discovery or `enabled=0`.
- Trigger expressions are gated by collector, VMMS, cluster, feature-enabled, health, and per-object context macros to suppress downstream storms.
- Recovery expressions add hysteresis for capacity, storage, replication lag, backlog, backup age, and certificate expiry.

## Minimum viable monitoring

1. Collector availability and success.
2. VMMS and Host Compute services.
3. VM state, health, and heartbeat.
4. Replica health, state, last replication, and lag.
5. Fixed-volume free space.
6. External vSwitch uplink state.
7. Recent Hyper-V critical/error events.
8. CPU and available-memory exhaustion.

## Recommended production additions

- Replica errors, backlog, resynchronization, and failover readiness.
- Cluster service, local node, Replica Broker, and CSV health/free space when clustered.
- Exact certificate thumbprints when HTTPS replication is used.
- Windows Server Backup or backup status-file freshness.
- Link the official `Windows by Zabbix agent` template separately for agent availability, OS disks, OS services, and baseline Windows telemetry.

## Disabled unless troubleshooting

Do not add by default: per-vCPU counters, per-VM disk IOPS/latency, per-vNIC throughput, dynamic-memory counters, NUMA counters, virtual processor runtime, individual replication-cycle size/latency graphs, every Hyper-V event ID, checkpoint count alerts, and discovery of internal/private vSwitches. See `docs/Monitoring-Matrix.md`.

## Files

```text
zabbix/Hyper-V/
├── .gitignore
├── README.md
├── Setup.md
├── config/
│   ├── hyperv-monitoring.example.json
│   └── zabbix-agent2-hyperv.example.conf
├── docs/
│   ├── Dashboard.md
│   ├── Monitoring-Matrix.md
│   └── Validation-Report.md
├── scripts/
│   ├── Get-ZabbixHyperVData.ps1
│   └── Install-ZabbixHyperVMonitoring.ps1
├── templates/
│   └── template_hyperv_replica_7.0.yaml
├── tests/
│   ├── Test-HyperVMonitoring.ps1
│   ├── fixtures/scenarios.json
│   ├── live-import-result.json
│   └── validate.py
└── userparameters/
    └── hyperv.conf
```

Start with [`Setup.md`](Setup.md). **Run the installer with `-WhatIf` first.** Rollback is `Install-ZabbixHyperVMonitoring.ps1 -Uninstall -WhatIf`, followed by the same command without `-WhatIf` after review.
