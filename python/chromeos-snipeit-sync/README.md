# chromeos-snipeit-sync

Add-only sync of **Google Admin ChromeOS devices** into **Snipe-IT**.

Pulls every ChromeOS device with status **ACTIVE** from the Admin SDK
Directory API and creates the ones missing from Snipe-IT with status
**Ready to Deploy**. It **never updates, overwrites, or changes the status of
an existing Snipe-IT asset** — the script contains no update code path, and
no financial fields (cost, supplier, depreciation, …) are ever sent.

## How "new vs. exists" is decided

1. All existing Snipe-IT serials and asset tags are fetched once (paginated)
   into two normalized (trimmed, case-insensitive) sets.
2. Per Google device: `serial = serialNumber`, `asset tag = annotatedAssetId`
   (falls back to the serial when the annotated asset ID is empty).
3. The device is **skipped** when its serial OR its asset tag is already in
   Snipe-IT, or duplicates an earlier device in the same Google export.
4. Otherwise it is created with exactly: `asset_tag`, `serial`, `model_id`,
   `status_id` ("Ready to Deploy"), and an audit note.
5. Re-running is idempotent — everything created last time is skipped.

Models are matched to **existing** Snipe-IT models by case-insensitive exact
name (plus the persisted `model-map.json`). The script never guesses:

- **Interactive run** — unknown models prompt once each:
  create in Snipe-IT / map to an existing model / skip.
  Create and map decisions persist to `model-map.json` for future runs.
- **`--non-interactive` (cron)** — never prompts; devices with unknown models
  are skipped and the problems are emailed to you.

## Setup

### 1. Python

```bash
python3 -m venv venv
venv/bin/pip install -r requirements.txt
```

### 2. Google: service account with domain-wide delegation

1. In a Google Cloud project: enable the **Admin SDK API**, create a service
   account (no GCP roles needed), and create/download a **JSON key**.
   Note the service account's **OAuth2 Client ID** (on its details page).
2. Google Admin console → **Security → Access and data control →
   API controls → Domain-wide delegation → Add new**: paste the Client ID
   with exactly this scope:
   `https://www.googleapis.com/auth/admin.directory.device.chromeos.readonly`
3. Choose the admin account to impersonate (`GOOGLE_ADMIN_SUBJECT`). A
   delegated admin with ChromeOS-device read privileges is tighter than a
   super admin.
4. Store the key file outside the repo, `chmod 600`.

### 3. Snipe-IT: API token

1. Preferably create a dedicated user with a role limited to: view/create
   assets, view/create models, view categories/manufacturers/status labels.
2. Log in as that user → profile menu → **Manage API Keys** →
   **Create New Token** → `SNIPEIT_API_TOKEN`.
3. Confirm the **Ready to Deploy** status label exists (default installs
   ship it). If yours is renamed, set `SNIPEIT_STATUS_LABEL`.

Use HTTPS for `SNIPEIT_URL` if at all possible — the bearer token travels in
every request. For a self-signed certificate set `SNIPEIT_VERIFY_TLS=false`
(still better than plain HTTP); an internal-CA certificate is best.

### 4. Environment

```bash
cp chromeos-snipeit-sync.env.example /etc/nomma/chromeos-snipeit-sync.env
chmod 600 /etc/nomma/chromeos-snipeit-sync.env
# edit in real values
```

## Running

```bash
set -a; . /etc/nomma/chromeos-snipeit-sync.env; set +a

venv/bin/python chromeos_snipeit_sync.py --dry-run   # ALWAYS start here
venv/bin/python chromeos_snipeit_sync.py --limit 1   # first real device
venv/bin/python chromeos_snipeit_sync.py             # interactive run
venv/bin/python chromeos_snipeit_sync.py --non-interactive   # cron mode
```

| Flag | Effect |
|---|---|
| `--dry-run` | No writes, no prompts, no email. Prints/reports what would happen, including the email that a cron run would send. |
| `--non-interactive` | Cron mode: never prompts; unknown models are skipped and emailed. Requires the SMTP vars. |
| `--limit N` | Process only the first N devices (testing). |

Exit codes: `0` clean · `1` fatal error · `2` completed with problems
(unknown models or failed creates — check the report/email).

### Cron

```cron
17 6 * * * bash -c 'set -a; . /etc/nomma/chromeos-snipeit-sync.env; set +a; exec /opt/nomma/venv/bin/python /opt/nomma/chromeos-snipeit-sync/chromeos_snipeit_sync.py --non-interactive' >> /var/log/chromeos-snipeit-sync.log 2>&1
```

Cron runs email you **only when there are problems** (unknown models, failed
creates, fatal errors) — clean runs are silent.

## Run report

Every run writes `reports/sync-report_YYYY-MM-DD_HHMMSS.csv` with one row per
ACTIVE device:

```
run_timestamp, serial, asset_tag, asset_tag_source, google_model,
google_device_id, snipeit_model_id, snipeit_model_name, action, detail,
snipeit_asset_id
```

`action` is one of `created`, `would-create` (dry run), `skipped-exists`,
`skipped-unknown-model`, `failed`; `detail` carries the reason
(`serial already in Snipe-IT`, `duplicate within Google export`, Snipe-IT's
error messages, …). `asset_tag_source` is `annotatedAssetId` or
`serial-fallback`.

## Files

| File | Purpose |
|---|---|
| `chromeos_snipeit_sync.py` | The whole script (self-contained) |
| `model-map.json` | Persisted model decisions (created on first map/create; gitignored) |
| `reports/` | Run reports (gitignored) |
| `chromeos-snipeit-sync.env.example` | Environment template |

## Test plan

1. **Fail-fast:** run with no env vars → lists every missing var;
   `--non-interactive` without SMTP vars → fails.
2. **Dry run:** `--dry-run` → sensible counts, zero prompts, Snipe-IT asset
   count unchanged, report written.
3. **Archived assets:** archive a test asset in Snipe-IT, dry-run → its
   serial must show `skipped-exists`. (If your Snipe-IT version excludes
   archived assets from `GET /hardware`, tell the maintainer — an extra
   `status=Archived` prefetch pass is the fix.)
4. **First create:** `--limit 1` → verify serial/tag/model/status in
   Snipe-IT, empty purchase/financial fields, audit line in Notes.
5. **Idempotency:** full re-run → `created=0`, everything `skipped-exists`.
6. **Serial fallback:** blank one device's asset ID in Google Admin →
   `asset_tag == serial`, `asset_tag_source=serial-fallback`.
7. **Unknown model (interactive):** rename a Snipe-IT model temporarily →
   exercise create/map/skip; `model-map.json` persists; next run is silent.
8. **Unknown model (cron):** `--non-interactive` → skip + email with CSV
   attached; after fixing the model, a clean re-run sends **no** email.
9. **Existing tag, different serial:** pre-create a conflicting asset →
   device is `skipped-exists`; the existing asset is untouched.
10. **Non-TTY guard:** `echo | python3 chromeos_snipeit_sync.py` with an
    unknown model pending → clean abort telling you to use
    `--non-interactive`, not a hang.

## Known behaviors (by design)

- **Soft-deleted Snipe-IT assets** aren't returned by the API, so a manually
  deleted asset gets recreated on the next run (Google still reports the
  device ACTIVE). Deprovision it in Google Admin if you don't want it back.
- **Duplicate asset IDs in Google Admin:** the first device wins; later ones
  appear in the report as `skipped-exists` / `duplicate within Google export`.
- **"Ready to Deploy" missing/renamed:** the run aborts (and emails in cron
  mode) rather than guessing a status ID.
- **Devices with no serial number** are reported as `failed` — an asset is
  never created without a serial.
