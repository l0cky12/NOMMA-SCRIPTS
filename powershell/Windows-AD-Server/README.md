# Cleanup-ADMetadata.ps1

Production-safe PowerShell script for removing stale or orphaned Active
Directory metadata left behind by a **failed or incomplete domain controller
demotion** (dead hardware, deleted VM, failed `Uninstall-ADDSDomainController`
/ `dcpromo`).

## What the script does

The script works in four clearly separated phases:

1. **Pre-flight safety checks** — verifies modules and privileges, refuses to
   run on the stale DC itself, verifies the target DC is *not* reachable,
   detects FSMO roles held by the target (hard stop with seizure guidance),
   and refuses to touch the last remaining DC of a domain.
2. **Discovery** — inventories every piece of metadata tied to the stale DC
   and exports a timestamped **"Before" CSV report**. Nothing is modified.
3. **Removal** — with per-item confirmation (`SupportsShouldProcess`,
   `ConfirmImpact = High`), removes:
   - inbound replication connection objects (`nTDSConnection`) on other DCs
     that still reference the stale DC,
   - the **NTDS Settings** object (`nTDSDSA`) — the actual "metadata cleanup",
   - the **server object** in AD Sites and Services,
   - the **DC computer account** (including child objects such as RID Set,
     DFSR-LocalSettings and SYSVOL subscriptions),
   - legacy **FRS** and **DFSR** SYSVOL membership objects,
   - optionally (`-CleanupDNS`) **DNS records**: the DC's A/AAAA host records,
     the `_msdcs` CNAME (DSA GUID) alias, SRV locator records targeting the
     DC, NS records naming it, and well-known records (`@`, `gc`,
     `DomainDnsZones`, `ForestDnsZones`) carrying the DC's IP.
4. **Reporting** — exports a timestamped **"After" CSV report** with the
   outcome of every item and prints post-cleanup verification steps.

Anything the script cannot verify safely (e.g. a computer account that does
not look like a DC account, or apex DNS records when the DC's old IP could
not be determined) is **flagged for manual review instead of deleted**.

## When to use it

- A DC died (hardware/VM loss) and can never be demoted cleanly.
- A demotion failed halfway and left orphaned objects behind.
- `repadmin`/`dcdiag`/event logs still reference a DC that no longer exists.

**Do NOT use it** on a DC that is alive or recoverable — demote it properly
with `Uninstall-ADDSDomainController` instead. The script hard-stops if the
target answers on LDAP (TCP 389); this cannot be overridden.

## Related diagnostics

### `Invoke-NOMMA-DC-CA-Diagnostics.ps1`
Runs secure channel, logon server, Kerberos, and `certutil` checks to show
which DC and CA a server is using.

### Usage

```powershell
.\Invoke-NOMMA-DC-CA-Diagnostics.ps1
```

## Prerequisites

- Windows PowerShell **5.1** (or later).
- RSAT **ActiveDirectory** module
  (`Install-WindowsFeature RSAT-AD-PowerShell` on server OS,
  `Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0` on client OS).
- RSAT **DnsServer** module — only when using `-CleanupDNS`
  (`Install-WindowsFeature RSAT-DNS-Server` / `Add-WindowsCapability -Online -Name Rsat.Dns.Tools~~~~0.0.1.0`).
- Run from a **healthy DC or a domain-joined admin workstation** — never from
  the stale DC (the script refuses anyway).
- At least one healthy writable DC reachable via ADWS.
- If the stale DC held FSMO roles, **seize them first**
  (`Move-ADDirectoryServerOperationMasterRole -Identity <HealthyDC> -OperationMasterRole <Role> -Force`).

## Required permissions

- **Domain Admins** in the affected domain, and **Enterprise Admins** in some
  delegation models (the server / NTDS Settings objects live in the
  configuration partition).
- The script checks membership and stops if you appear to lack it; if you
  hold equivalent *delegated* rights you can override that specific check
  with `-Force`.

## Safety warnings

- **Metadata cleanup is destructive and not reversible** without an AD
  restore. Always run `-WhatIf` first and read the Before CSV.
- Nothing is deleted by default without confirmation — every object prompts
  individually, plus one final "are you sure" gate before the removal phase.
- `-Force` suppresses prompts. It does **not** override the hard stops:
  target alive on LDAP, target holds FSMO roles, target is the last DC.
- If the target answers **ping/SMB but not LDAP**, the script stops: the IP
  or name may have been reused by another machine. Investigate; only re-run
  with `-Force` when you are certain the DC is permanently gone.
- Take a **System State backup** of a healthy DC before large cleanups.
- The supported manual alternative is `ntdsutil` → `metadata cleanup`, or
  deleting the DC's computer object in AD Users and Computers (Windows
  Server 2008+ performs the same server-side cleanup).

## Example: dry run (always do this first)

```powershell
.\Cleanup-ADMetadata.ps1 -StaleDCName 'OLDDC01' -WhatIf
```

Runs all safety checks and the full discovery, exports the Before CSV, and
prints exactly what *would* be deleted. Nothing is changed.

## Example: cleanup

```powershell
# Interactive - confirm each deletion (recommended):
.\Cleanup-ADMetadata.ps1 -StaleDCName 'OLDDC01' -CleanupDNS

# Fully specified, unattended (only after a reviewed -WhatIf run):
.\Cleanup-ADMetadata.ps1 -StaleDCName 'OLDDC01' -DomainName 'corp.example.com' `
    -SiteName 'Branch-01' -CleanupDNS -Force
```

## Reviewing logs and CSV reports

Default locations (override with `-LogPath` / `-ReportPath`):

| Output | Default location |
|---|---|
| Log file | `%ProgramData%\ADMetadataCleanup\Logs\Cleanup-ADMetadata_<DC>_<timestamp>.log` |
| Before report | `%ProgramData%\ADMetadataCleanup\Reports\ADMetadataCleanup_<DC>_Before_<timestamp>.csv` |
| After report | `%ProgramData%\ADMetadataCleanup\Reports\ADMetadataCleanup_<DC>_After_<timestamp>.csv` |

The log records every check, decision, and deletion with timestamps. The CSVs
contain one row per metadata item with `Category`, `ObjectType`, `Identity`
(distinguished name), DNS `Zone`, and a `Status` column:

| Status | Meaning |
|---|---|
| `Detected` | Found and eligible for removal (Before report) |
| `Removed` | Deleted successfully |
| `WhatIf` | Dry run — would have been deleted |
| `Declined` | Operator answered "No" at the confirmation prompt |
| `Failed` | Deletion failed — see the `Result` column and the log |
| `NotFound` | Expected object absent (possibly already cleaned) |
| `ManualReview` | **Action required** — the script would not delete this automatically; verify and clean by hand |

After a run, filter the After CSV for `Failed` and `ManualReview` rows —
those are your remaining to-dos.

## What to check after running the script

1. Every `ManualReview` / `Failed` row in the After CSV has been handled.
2. AD Sites and Services no longer shows the old server object
   (`dssite.msc`), and the site itself — delete the site/subnet mappings if
   the location was fully decommissioned.
3. DNS: no remaining A/AAAA, CNAME (`_msdcs` GUID), SRV or NS records
   referencing the dead DC on **all** DNS servers hosting the zones.
4. DHCP scopes / option 006, static client DNS settings, VPN and firewall
   rules, monitoring, and backup jobs no longer reference the dead DC.
5. `nltest /dsgetdc:<domain>` never returns the removed DC.
6. If the DC was a Global Catalog, confirm remaining GCs cover the sites that
   relied on it (Exchange and other GC-dependent apps especially).
7. Time hierarchy: if the dead DC was the PDC emulator before seizure,
   confirm `w32tm /query /source` on the new PDC points at a valid source.

## How to verify AD replication health after cleanup

Run from a healthy DC (allow one replication cycle to pass first):

```powershell
# Overall replication summary - look for 0 fails and no reference to the old DC
repadmin /replsummary

# Remaining replication errors only
repadmin /showrepl * /errorsonly

# Force the KCC to recalculate the replication topology on all DCs
repadmin /kcc *

# Directory service health, errors only
dcdiag /q

# DNS-specific tests
dcdiag /test:dns /q

# PowerShell equivalents
Get-ADReplicationPartnerMetadata -Target * -PartnerType Both |
    Select-Object Server, Partner, LastReplicationSuccess, LastReplicationResult

Get-ADReplicationFailure -Target * -Scope Forest
```

Healthy signs: `repadmin /replsummary` shows no failures and the dead DC no
longer appears as a source or destination; `dcdiag /q` returns no output;
event logs on remaining DCs stop logging KCC/replication errors (events
1311, 1865, 2042) referencing the removed DC.
