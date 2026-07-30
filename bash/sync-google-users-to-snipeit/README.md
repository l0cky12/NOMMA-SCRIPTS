# Google Workspace → Snipe-IT User Sync

One-way synchronization of Google Workspace users from the **Cadets** OU (and all sub-OUs) into Snipe-IT user accounts.

**Google is authoritative.** Reads all users from `/Cadets` and sub-OUs, extracts Employee ID from Google's `externalIds`, maps the OU grade level to a Snipe-IT department, and creates/updates Snipe-IT user accounts with random passwords and login disabled.

## What it does

| Google Workspace field | Snipe-IT field |
|---|---|
| `primaryEmail` | `username`, `email` |
| `name.givenName` / `name.familyName` | `first_name`, `last_name` |
| `externalIds[type=organization].value` | `employee_num` |
| OU path (e.g. `Cadets/8th Grade`) → grade → department mapping | `department_id` |
| — | `password`: random 32-char base64 |
| — | `activated`: `false` (login disabled) |

### Scope

- **OU:** `/Cadets` and all sub-OUs (`/Cadets/8th Grade`, `/Cadets/9th Grade`, etc.)
- **Users with Employee ID:** that number is set as `employee_num` in Snipe-IT
- **Users without Employee ID:** the user is still created — `employee_num` is left blank
- **Root OU users** (directly in `/Cadets`, not in a grade sub-OU): created without a department

### IMPORTANT: login is disabled

All synced users are created with `activated: false`. They exist in Snipe-IT for asset assignment and tracking, but cannot log in. This is intentional — Cadets should not have interactive Snipe-IT access.

## Prerequisites

- Debian 12/13 with `bash`, `curl`, `jq`, `openssl`
- Google Workspace **service account** with domain-wide delegation for the **Admin SDK Directory API** (`admin.directory.user.readonly` scope)
- A Snipe-IT **API token** with permission to view, create, and edit users and departments

## Quick start

```bash
sudo apt update && sudo apt install -y curl jq openssl
cd /home/liam/NOMMA-SCRIPTS/bash/sync-google-users-to-snipeit
cp .env.example .env
chmod 600 .env
# Edit .env with your credentials
./sync_google_users_to_snipeit.sh --validate-config
```

## Google Cloud setup

1. In your Google Cloud project, **APIs & Services → Library**: enable **Admin SDK API**
2. **IAM & Admin → Service Accounts**: create a dedicated service account
3. Enable **Domain-wide delegation** and record the OAuth client ID
4. Create a JSON key and store it securely (e.g. `/etc/nomma/google-directory-reader.json`)
5. In Google Admin Console → **Security → Access and data control → API controls → Domain-wide delegation**: add the client ID with scope:
   ```
   https://www.googleapis.com/auth/admin.directory.user.readonly
   ```
6. Set `GOOGLE_DELEGATED_ADMIN` to a Workspace admin with read access to the Cadets OU

## Configuration

`.env` is ignored by Git. Edit all values before running:

| Variable | Required | Description |
|---|---|---|
| `GOOGLE_SERVICE_ACCOUNT_FILE` | ✓ | Path to Google service account JSON key |
| `GOOGLE_DELEGATED_ADMIN` | ✓ | Admin email for domain-wide delegation |
| `GOOGLE_CUSTOMER_ID` | ✓ | Usually `my_customer` |
| `SNIPEIT_URL` | ✓ | Snipe-IT base URL |
| `SNIPEIT_API_TOKEN` | ✓ | Snipe-IT bearer token |
| `GOOGLE_OU` | | OU to sync (default: `/Cadets`) |
| `GOOGLE_DOMAIN` | | Domain filter (default: `nomma.net`) |
| `GRADE_DEPT_MAPPING` | | Path to grade→department mapping JSON |
| `SNIPEIT_VERIFY_TLS` | | `true` or `false` (default: `true`) |
| `LOG_LEVEL` | | 0=quiet, 1=normal, 2=verbose (default: 1) |
| `LOG_FILE` | | Path to log file (default: stderr only) |

## Grade → Department mapping

`config/grade-department-mapping.json` maps Google OU names to Snipe-IT department names:

```json
{
  "8th Grade": "8th Grade",
  "9th Grade": "9th Grade",
  "10th Grade": "10th Grade",
  "11th Grade": "11th Grade"
}
```

The key is the immediate sub-OU name under `/Cadets`. The value is the Snipe-IT department name (which is created automatically if it doesn't exist).

## Usage

```bash
# Validate config only (no API calls)
./sync_google_users_to_snipeit.sh --validate-config

# Dry-run (default) — reads Google, compares with Snipe-IT, no writes
./sync_google_users_to_snipeit.sh

# Limit to first N users (useful for initial testing)
./sync_google_users_to_snipeit.sh --limit 5

# Apply changes (creates/updates users in Snipe-IT)
./sync_google_users_to_snipeit.sh --apply
```

## Scheduling

### Systemd timer (preferred)

```bash
sudo cp systemd/google-users-snipeit-sync.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now google-users-snipeit-sync.timer
sudo systemctl list-timers google-users-snipeit-sync.timer
```

Runs daily at 06:30 America/Chicago ±5 min.

### Cron alternative

```cron
30 6 * * * cd /home/liam/NOMMA-SCRIPTS/bash/sync-google-users-to-snipeit && ./sync_google_users_to_snipeit.sh --apply >> /var/log/google-snipeit-user-sync.log 2>&1
```

## How Employee ID is found

The script reads the Google Directory API with `projection=full` and looks for Employee ID in:

1. **`externalIds`** array — entries with `type: "organization"` → `value` is the Employee ID

This is the standard Google Workspace Employee ID field. If your Employee IDs are stored in a custom schema instead, you can modify `google_extract_employee_id()` in the script.

## Safety

- **Dry-run is the default.** No Snipe-IT writes happen without `--apply`
- Users are matched **by email** in Snipe-IT
- Departments are created if they don't exist
- Existing Snipe-IT users are **updated** (not recreated) — their passwords and activation status are **not** changed on update, only `first_name`, `last_name`, `employee_num`, and `department_id`
- New users get randomized 32-char passwords and login disabled
- The script never deletes anything in Snipe-IT or Google Workspace

## Cron on the Snipe-IT server

This script is designed to run on the Snipe-IT server itself. You'll need:

1. The Google service account JSON key copied to the server
2. `.env` configured with the API token and paths
3. Network access from the Snipe-IT server to `admin.googleapis.com` and `oauth2.googleapis.com`
4. Either systemd timer or cron installed

## Troubleshooting

| Problem | Likely cause |
|---|---|
| `Google token exchange failed` | Service account key path wrong, key expired, or domain-wide delegation not configured |
| `Snipe-IT HTTP 401` | API token is invalid or expired |
| `Snipe-IT HTTP 403` | API user lacks permission to manage users |
| No users returned | Wrong OU path, wrong customer ID, or delegated admin lacks OU read access |
| Employee IDs empty | Employee numbers not set in Google Workspace for those users |
| Departments not created | Check `GRADE_DEPT_MAPPING` file path and JSON format |