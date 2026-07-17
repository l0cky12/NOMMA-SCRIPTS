# Google Admin → Snipe-IT Chromebook inventory sync

Production-oriented, one-way synchronization from the Google Admin SDK Directory API to `https://inv.nomma.tech`.

**Google is authoritative.** Assets are matched only by serial number. The tool creates missing Snipe-IT assets and updates only a differing `asset_tag` and/or `model_id`. It never deletes anything, never changes Google Admin, and never modifies Snipe-IT assets absent from Google.

> The configured status is intentionally preserved as **`Ready to Depoly`**. The live Snipe-IT API must return that exact name before a run can proceed. Real API verification has not been performed because credentials were not supplied.

## Safety behavior

- No Snipe-IT write is possible unless `--apply` is present. No mode flag means dry-run.
- `--dry-run` reads both APIs and executes the full comparison without POST/PATCH requests.
- Existing assets are matched only by normalized exact serial (trimmed, case-insensitive).
- Duplicate serials or conflicting asset tags are blocked and logged, never guessed.
- Missing serial, missing asset ID, and unmapped model devices are skipped.
- Existing assets receive PATCH payloads containing only changed `asset_tag` and/or `model_id`.
- New assets contain only `asset_tag`, `serial`, `model_id`, `status_id`, and `company_id`; location remains unassigned.
- Category is inherited from the selected Snipe-IT model. Every mapped model must belong to the resolved `Chromebook` category.
- No categories, models, companies, locations, status labels, or assets are ever deleted. Supporting records are never created.
- A nonblocking file lock prevents concurrent runs.

## Prerequisites

- Debian 13 with `python3`, `python3-venv`, and CA certificates.
- Google Workspace ChromeOS inventory and permission to configure domain-wide delegation.
- A Snipe-IT API user/token with the permissions listed below.
- Existing Snipe-IT category `Chromebook`, status label `Ready to Depoly`, company `New Orleans Military & Maritime Academy`, and all models named in the mapping file.

```bash
sudo apt update
sudo apt install -y python3 python3-venv ca-certificates
cd /home/liam/NOMMA-SCRIPTS/python/sync-google-admin-snipeit
chmod +x scripts/install.sh scripts/run-sync.sh
./scripts/install.sh
```

The installer creates `.venv`; it does not install Python packages globally.

## Google Cloud and Workspace setup

1. Create or select a Google Cloud project.
2. **APIs & Services → Library**: enable **Admin SDK API**.
3. **IAM & Admin → Service Accounts**: create a dedicated service account. It needs no Google Cloud IAM role for this API.
4. Open the service account, enable **Domain-wide delegation**, and record its OAuth 2 client ID.
5. Create a JSON key. Store it outside this repository, for example `/etc/nomma/google-chromeos-reader.json`.
6. Google Admin Console → **Security → Access and data control → API controls → Domain-wide delegation → Manage Domain Wide Delegation → Add new**.
7. Enter the service account OAuth client ID and this least-privilege scope only:

   ```text
   https://www.googleapis.com/auth/admin.directory.device.chromeos.readonly
   ```

8. Set `GOOGLE_DELEGATED_ADMIN` to a Workspace administrator account. Prefer a custom delegated-admin role over Super Admin. It must have read access to the relevant organizational units and the Admin console privilege required to view ChromeOS devices (under **Services → Chrome Management → Devices**, wording can vary by Workspace edition).
9. Restrict the key:

   ```bash
   sudo chown liam:liam /etc/nomma/google-chromeos-reader.json
   chmod 600 /etc/nomma/google-chromeos-reader.json
   ```

Validate local key path/configuration first, then authenticate and retrieve devices with a dry-run:

```bash
.venv/bin/python sync_google_admin_snipeit.py --validate-config
.venv/bin/python sync_google_admin_snipeit.py --dry-run
```

Typical Google failures:

- `401`: bad/revoked key, wrong delegated subject, or invalid token.
- `403 notAuthorizedToAccessThisResource/apiNotEnabled`: Admin SDK disabled, domain-wide delegation missing/wrong client ID or scope, or delegated admin lacks ChromeOS device read privilege.
- Empty inventory: wrong `GOOGLE_CUSTOMER_ID` or delegated administrator/OU visibility.
- Network/5xx/rate-limit failures: the official client uses bounded retries (`num_retries=5`).

The Directory API request uses `chromeosdevices.list`, `projection=FULL`, up to 300 records per page, and follows every `nextPageToken`. It does not scrape the Admin Console.

## Snipe-IT token

1. Create a dedicated Snipe-IT service user.
2. Assign a role that can **view, create, and edit assets**, plus **view models, categories, status labels, and companies**. No delete permission is needed. Tokens inherit the user's permissions.
3. Sign in as that user → profile menu → **Manage API Keys** → **Create New Token**.
4. Put the token only in `.env`; never pass it on the command line.

```bash
cp .env.example .env
chmod 600 .env /etc/nomma/google-chromeos-reader.json
```

Snipe-IT behavior:

- List endpoints use `limit`/`offset` until `total` is exhausted.
- Assets are fetched from `GET /api/v1/hardware`, indexed by exact normalized serial, and matched only by serial. This avoids accepting fuzzy `search` results as identity.
- Models are fetched from `GET /api/v1/models`; mapped names must resolve exactly once.
- Category, status, and company are independently paginated and resolved by exact name before synchronization.
- Creates use `POST /api/v1/hardware`; updates use `PATCH /api/v1/hardware/{id}`.
- HTTP 429 honors `Retry-After`; network errors and 5xx responses receive at most five exponential-backoff attempts.
- Duplicate asset tags, validation failures, invalid IDs, and insufficient permissions can be returned as HTTP errors or a JSON `status=error`; both are reported. A single device write failure does not stop unrelated devices.

## Configuration

`.env` is ignored by Git. The script loads it from its own directory unless `--env-file` is supplied.

| Variable | Meaning / default |
|---|---|
| `SNIPEIT_URL` | Required HTTPS base URL; production is `https://inv.nomma.tech` |
| `SNIPEIT_API_TOKEN` | Required secret bearer token |
| `GOOGLE_SERVICE_ACCOUNT_FILE` | Required path to service-account JSON key |
| `GOOGLE_DELEGATED_ADMIN` | Required delegated Workspace admin email |
| `GOOGLE_CUSTOMER_ID` | Required; normally literal `my_customer` |
| `MODEL_MAPPING_FILE` | Required mapping JSON path |
| `LOG_LEVEL` | `INFO` by default |
| `LOG_FILE` | `logs/sync.log` by default |
| `LOCK_FILE` | `logs/sync.lock` by default |
| `SNIPEIT_CATEGORY_NAME` | `Chromebook` |
| `SNIPEIT_STATUS_NAME` | `Ready to Depoly` (exact current requested spelling) |
| `SNIPEIT_COMPANY_NAME` | `New Orleans Military & Maritime Academy` |
| `SNIPEIT_VERIFY_TLS` | `true`; do not disable for production |

`--validate-config` checks required values, paths, HTTPS, and mapping JSON without calling either API. A real dry-run additionally proves Google authentication, device retrieval, Snipe-IT authentication, permissions, defaults, and mapped model resolution.

## Exact model mapping

No fuzzy matching exists. `config/model-mapping.json` is a JSON object whose keys are exact Google `model` values and whose values are exact existing Snipe-IT model names:

```json
{
  "Exact Google hardware-model text": "Exact existing Snipe-IT model name"
}
```

The shipped files contain obvious fixture/example placeholders only. They do **not** claim that any Dell or HP examples in the request are equivalent.

Discover Google values:

```bash
.venv/bin/python sync_google_admin_snipeit.py --list-unmapped-models
```

Discover exact Snipe-IT model names without exposing the token in process arguments or shell history:

```bash
read -rsp 'Snipe-IT token: ' TOKEN; printf '\n'
curl --fail --silent --show-error \
  -H "Authorization: Bearer $TOKEN" -H 'Accept: application/json' \
  'https://inv.nomma.tech/api/v1/models?limit=500&offset=0&sort=name&order=asc' \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print("\n".join(r["name"] for r in d["rows"])); print("returned={} total={}".format(len(d["rows"]), d["total"]), file=sys.stderr)'
unset TOKEN
```

If `total` exceeds 500, repeat with `offset=500`, `1000`, etc. Add only reviewed exact pairs to `config/model-mapping.json`, then run `--dry-run`. A Google model without a mapping is logged as `unmapped_model`; its device is skipped. Mappings to missing/duplicate models or models outside the `Chromebook` category fail safely before processing.

## CLI

```bash
# Safest obvious usage; --dry-run is also the default when no mode is given.
.venv/bin/python sync_google_admin_snipeit.py --dry-run

# Required for writes. Do this only after reviewing the dry-run and mappings.
.venv/bin/python sync_google_admin_snipeit.py --apply

.venv/bin/python sync_google_admin_snipeit.py --validate-config
.venv/bin/python sync_google_admin_snipeit.py --list-unmapped-models
```

Exit codes: `0` clean, `2` configuration, `3` concurrent-run lock, `4` fatal API/I/O failure, `5` completed with device errors or unmapped models, `130` interrupted.

### Offline verification

The fixture path is read-only and is rejected with `--apply`:

```bash
.venv/bin/python sync_google_admin_snipeit.py \
  --validate-config --fixture-file tests/fixtures/offline-inventory.json
.venv/bin/python sync_google_admin_snipeit.py \
  --dry-run --fixture-file tests/fixtures/offline-inventory.json
```

## Logging and reports

Console and `logs/sync.log` receive timestamped action lines. The log rotates at 5 MiB and retains five backups. Every device is classified as `created`/`would_create`, `updated`/`would_update`, `unchanged`, `missing_serial`, `missing_asset_tag`, `unmapped_model`, `duplicate_conflict`, or `error`. The final summary includes Google devices read, eligible, created, updated, unchanged, skipped, unmapped, and errors.

Tokens and private-key material are never logged. API error bodies are truncated; the configured token is redacted defensively. If logs are moved elsewhere, keep that directory writable by `liam` and inaccessible to untrusted users.

## Scheduling (systemd preferred)

The service explicitly uses `--apply`; do not enable it until a real dry-run has been reviewed.

```bash
sudo cp systemd/google-admin-snipeit-sync.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now google-admin-snipeit-sync.timer
systemctl list-timers google-admin-snipeit-sync.timer
journalctl -u google-admin-snipeit-sync.service
```

The timer runs daily around 06:15 America/Chicago with up to five minutes of jitter.

Cron alternative (also explicitly applies):

```cron
15 6 * * * cd /home/liam/NOMMA-SCRIPTS/python/sync-google-admin-snipeit && /home/liam/NOMMA-SCRIPTS/python/sync-google-admin-snipeit/.venv/bin/python sync_google_admin_snipeit.py --apply >> logs/cron.log 2>&1
```

Do not configure both cron and the systemd timer. The lock prevents overlap, but duplicate schedules are noise.

## Troubleshooting and rollback

- **Required default missing:** confirm spelling/case in Snipe-IT. The tool never creates a replacement.
- **`Ready to Depoly` not found:** determine whether the typo is intentional in the live instance. Preserve the live exact name; change `.env` only after explicit review.
- **Mapped model rejected:** verify exact name and that the model's category is `Chromebook`.
- **Duplicate asset tag:** repair the conflicting inventory manually; the sync will not take ownership.
- **401/403 from Snipe-IT:** token revoked/expired or service user lacks endpoint permissions.
- **TLS failure:** install the issuing CA on Debian. Do not disable verification in production.

There is no automated rollback because a compensating delete would violate the no-delete rule. Stop the timer, inspect Snipe-IT's audit history and the structured action log, manually correct only affected asset tag/model fields, fix configuration, and rerun dry-run. Existing unrelated fields are never included in update payloads.

## Developer verification

```bash
.venv/bin/python -m py_compile sync_google_admin_snipeit.py tests/test_sync.py
.venv/bin/python -m unittest discover -s tests -v
.venv/bin/python sync_google_admin_snipeit.py --help
```
