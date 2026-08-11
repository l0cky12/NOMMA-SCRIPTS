# Remove-EducationPlusLicense-InactiveOU.ps1

Production-safe PowerShell 7 tool to **remove the Google Workspace for
Education Plus license** from user accounts in the `NOMMA.net/zMisc/Inactive`
organizational unit (OU).

This is the Google Workspace counterpart to the safety-first scripts in
`powershell/Windows-AD-Server/`. It follows the same principles: a clear
**dry-run by default**, an explicit `-Apply` gate with a single operator
confirmation, per-user fault isolation, and a timestamped CSV report.

## Safety model (the short version)

| Behavior | Default |
|----------|---------|
| Mutates licenses | **No** — dry-run prints the before/after plan and makes zero API calls |
| Remove licenses | Only with `-Apply` **and** a single interactive confirmation |
| What it removes | **Only** the `Google-Apps-For-Education-Plus` SKU. All other SKUs are left untouched |
| Live Google calls during build/test | **Never** — tests use mocks; prod run is a separately approved step |

> **Billing warning:** removing Education Plus is a **licensing/billing-affecting**
> change. Always run a dry-run against a real list before ever passing `-Apply`.

## File layout

- `Remove-EducationPlusLicense-InactiveOU.ps1` — one self-contained script containing
  the logic, Google API adapter, and orchestration (dry-run default, `-Apply` +
  confirmation gate, per-user fault isolation, exit 1 on errors)
- `tests/EducationPlusLicense.Tests.ps1` — Pester v6 mock tests (no live Google)

## Prerequisites

- **PowerShell 7** (`pwsh`), version 7.0+ (script declares `#Requires -Version 7.0`).
- **Pester** (test-only): `Install-Module Pester -Scope CurrentUser -Force`.
- **Google Admin SDK packages** — restored at runtime via NuGet; the adapter uses
  `dotnet restore/build` for a portable assembly-load. The adapter needs a **`.NET SDK`
  on the machine doing the REAL run**, OR the assemblies already loaded, OR the
  pre-restored DLLs present. Confirmed packages:
  - `Google.Apis.Admin.Directory.directory_v1` — user / OU lookup
  - `Google.Apis.Licensing.v1` — license read / remove
  - `Google.Apis.Auth` — OAuth2 installed-app flow
- **OAuth2 app credentials** JSON file (Desktop app type) — supplied via `-CredentialsPath`.
  Never hard-coded, never committed.

> **Mock-test mode needs none of the Google packages.** Tests mock the three adapter
> functions, so no NuGet restore and no `dotnet` are required to run the test suite.

## Mock test mode

Run the full mock suite (offline, no live Google):

```bash
cd powershell/Google-Admin
pwsh -NoProfile -Command "Import-Module Pester; Invoke-Pester ./tests -Output Detailed"
```

Expected: `Tests Passed: 10, Failed: 0`. The tests assert dry-run makes no mutation
calls, `-Apply` without `YES` exits 2 with no changes, only the Education Plus SKU is
removed (other SKUs untouched), already-clean users are unchanged, one failing user
doesn't block the batch (`exit` nonzero), secrets never appear in output/report, and
the report carries before/after + mode + timestamp.

## Real run (separately approved)

1. Create an OAuth2 client in the Google Cloud Console (Desktop app type).
2. Download the client JSON (e.g. `client_secret.json`).
3. Confirm the exact Education Plus SKU ID for your tenant with `gam` or the Admin
   console, and pass it via `-EducationPlusSkuId` if it differs from the default.
4. On first real run the script opens the installed-app flow and caches a token
   locally. Tokens are never printed or written to the CSV report.

A real **apply** run touches billing-affecting license assignments, so it is a
separately approved step — always run dry-run against the real list first.

## CLI usage

```powershell
# Dry run against the Inactive OU — makes zero changes
.\Remove-EducationPlusLicense-InactiveOU.ps1 -OuTarget "NOMMA.net/zMisc/Inactive" `
    -ReportPath ".\reports"

# Dry run against a CSV list of email addresses
.\Remove-EducationPlusLicense-InactiveOU.ps1 -CsvPath ".\users.csv" `
    -ReportPath ".\reports"

# Actually remove (single confirmation required)
.\Remove-EducationPlusLicense-InactiveOU.ps1 -OuTarget "NOMMA.net/zMisc/Inactive" `
    -Apply -ReportPath ".\reports"
```

## Parameters

| Parameter | Purpose |
|-----------|---------|
| `-CsvPath` | Path to a CSV of email addresses (default input mode) |
| `-OuTarget` | Switch: pull the live user list from this OU instead of a CSV |
| `-Apply` | **Required** to make license changes. Off by default (dry-run). |
| `-ReportPath` | Directory for the timestamped CSV report |

Remove only if you have verified the exact Education Plus SKU ID for your
tenant (see below).

## STOP-GATE — verify the SKU ID before any real run

The script targets the SKU ID `Google-Apps-For-Education-Plus`. Confirm the
exact ID your tenant reports before a real run — confirm with `gam` or the
Google Admin console. Some tenants report a **localized or alternate ID**.
If yours differs, pass the actual SKU ID before enabling `-Apply`.

## Reporting

A timestamped CSV report is written per run recording, per user:

- email address
- status (`processed` / `removed` / `already-clean` / `error`)
- Education Plus **before**
- Education Plus **after**
- error detail

Reports include the run timestamp and **mode** (`dry-run` / `apply`).
Secrets are never written to the report.
