# Daily Operations Dashboard

Create one Zabbix dashboard named **Hyper-V Operations**. The template intentionally does not import a rigid dashboard because host groups and naming conventions vary.

## KPI widgets

1. **Problems:** host group containing Hyper-V hosts; severity Warning and above; tags `component=replication`, `component=vm`, `component=storage`, `component=cluster`, `component=network`, `component=backup`, or `component=certificate`.
2. **Item value:** `Hyper-V: VMs critical`, aggregated by host.
3. **Item value:** `Hyper-V Replica: Critical relationships`, aggregated by host.
4. **Item value:** `Hyper-V Replica: Oldest replication lag`, displayed as duration.
5. **Item value:** `Hyper-V Storage: Minimum fixed-volume free space`, displayed as percent.
6. **Item value:** `Hyper-V Capacity: Available physical memory`, displayed as percent.
7. **Item value:** `Hyper-V Backup: Age of last success`, limited to hosts where backup monitoring is enabled.
8. **Top hosts:** `Hyper-V: Recent critical/error event count`.

## Daily check

Healthy daily posture is: collector status 1, VM critical count 0, replica critical count 0, oldest lag below 600 seconds, no CSV/switch failures, storage above warning thresholds, and current backup/certificate indicators where those features are enabled.
