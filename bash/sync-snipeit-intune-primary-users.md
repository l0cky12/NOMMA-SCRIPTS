# Snipe-IT to Intune Primary User Sync

`sync-snipeit-intune-primary-users.sh` makes Snipe-IT's direct hardware
checkout the source of truth for the primary user on matching Windows Intune
devices.

The script is **dry-run by default**. It never checks assets in, changes
Snipe-IT, clears a primary user, or updates non-Windows devices.

## Data flow

1. Read **transitive** users from Entra group
   `627b0785-7658-4f80-a3ff-c362a723cd4a`. Nested-group users are included;
   non-user members are excluded by the typed Graph relationship.
2. Use each Entra user's `mail`, falling back to `userPrincipalName` only when
   `mail` is empty.
3. Find exactly one Snipe-IT user by exact email and page through `/hardware`
   with both `assigned_to={user-id}` and `assigned_type=App\\Models\\User`.
   This excludes location and asset-to-asset assignments.
4. Match the trimmed serial to an Intune managed device using an exact,
   case-insensitive comparison. Zero or duplicate matches are blocked.
5. Require a Windows managed device with a nonempty Entra device ID.
6. Read the current primary-user relationship. Correct assignments are no-ops.
7. In `--apply` mode only, assign the target with:

   ```http
   POST https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/{id}/users/$ref
   Content-Type: application/json

   {"@odata.id":"https://graph.microsoft.com/v1.0/users/{user-id}"}
   ```

The script does not issue a DELETE against the current user relationship, so it
never deliberately leaves a device without a primary user.

## Microsoft Graph permissions

Use **application permissions** and grant tenant admin consent:

| Permission | Why |
|---|---|
| `GroupMember.Read.All` | Read direct and nested membership of the source group. |
| `User.ReadBasic.All` | Read member `mail`, `userPrincipalName`, display name, and ID. |
| `DeviceManagementManagedDevices.ReadWrite.All` | List managed devices, read their primary-user relationship, and assign the primary user. |

If the group has hidden membership, Microsoft also requires
`Member.Read.Hidden`. Do not grant it unless the source group is hidden.

Microsoft's current v1.0 `managedDevice` documentation identifies `userId` as
read-only and exposes `users` as the primary-user relationship. The relationship
`POST .../users/$ref` method is used instead of PATCHing `userId`.

References:

- <https://learn.microsoft.com/graph/api/resources/intune-devices-manageddevice?view=graph-rest-1.0>
- <https://learn.microsoft.com/graph/api/group-list-transitivemembers?view=graph-rest-1.0>
- <https://learn.microsoft.com/graph/permissions-reference>
- <https://learn.microsoft.com/answers/questions/2153212/how-do-you-re-assign-a-primary-user-to-an-intune-d>

## Prerequisites

- Bash 4+
- `curl`
- `jq`
- A Snipe-IT API token that can read users and hardware
- An Entra app registration with the application permissions above
- An active Intune license in the tenant
- Network access to Snipe-IT and Microsoft endpoints

Store the real environment file outside the repository:

```bash
sudo install -d -m 700 /etc/nomma
sudo install -m 600 \
  bash/sync-snipeit-intune-primary-users.env.example \
  /etc/nomma/sync-snipeit-intune-primary-users.env
sudoedit /etc/nomma/sync-snipeit-intune-primary-users.env
```

For Snipe-IT's internal TLS certificate, prefer `SNIPEIT_CA_BUNDLE`. Setting
`SNIPEIT_INSECURE=true` disables certificate validation and is only for a
short-lived test.

## Usage

Load the environment without passing secrets on the command line:

```bash
set -a
. /etc/nomma/sync-snipeit-intune-primary-users.env
set +a
```

### One-user pilot

```bash
# Read-only dry run
./bash/sync-snipeit-intune-primary-users.sh --user user@nomma.net

# Review the CSV, then make changes for that one user
./bash/sync-snipeit-intune-primary-users.sh --user user@nomma.net --apply
```

`--user` must match the selected Entra email (`mail`, or UPN when mail is
empty). One Snipe-IT user can have multiple assigned devices; all are evaluated.

### Limited pilot

`--limit` limits users after group retrieval, not devices:

```bash
./bash/sync-snipeit-intune-primary-users.sh --limit 5
./bash/sync-snipeit-intune-primary-users.sh --limit 5 --apply
```

An apply run affecting more than one selected user requires an interactive
confirmation. For reviewed automation, add `--yes`:

```bash
./bash/sync-snipeit-intune-primary-users.sh --limit 5 --apply --yes
```

### Full run

```bash
# Always review this report first
./bash/sync-snipeit-intune-primary-users.sh

# BULK CHANGE: interactive confirmation requires typing APPLY
./bash/sync-snipeit-intune-primary-users.sh --apply

# Noninteractive bulk run, only after reviewing a current dry-run report
./bash/sync-snipeit-intune-primary-users.sh --apply --yes
```

Use `--report /secure/path/report.csv` to select the report path. Otherwise the
script writes under `bash/reports/`, which is ignored by Git.

## Audit actions

The timestamped CSV records user email, asset tag, serial, Intune ID/name,
previous user, proposed user, action, and error detail. Important actions:

- `would-update-primary-user`: dry run found a safe change.
- `updated-primary-user`: Graph accepted the relationship update.
- `unchanged-primary-user-correct`: idempotent no-op.
- `blocked-duplicate-intune-serial`: ambiguous serial; no mutation.
- `blocked-multiple-current-primary-users`: unexpected relationship state.
- `skipped-missing-serial`, `skipped-intune-device-not-found`, and
  `skipped-unsupported-*`: no mutation.

Exit codes: `0` completed cleanly, `1` fatal setup/API error, `2` completed but
one or more records were skipped or blocked.

## Rollback

The CSV records `previous_primary_user`. To roll back, validate the affected
serial and restore that user from Intune admin center, or run the existing
single-device `Set-NOMMAIntuneDeviceAssignment.ps1` workflow. There is no
automatic rollback because blindly replaying stale ownership data is unsafe.

## Troubleshooting

- **401/403 from Graph:** verify tenant/client IDs, secret expiry, application
  permissions, and admin consent. Intune APIs also require tenant licensing.
- **Group users have null mail/UPN:** grant `User.ReadBasic.All` application
  permission and admin consent.
- **Snipe-IT user not found:** email matching is exact; correct the Snipe-IT
  email rather than using fuzzy matching.
- **TLS failure to `10.1.2.81`:** set `SNIPEIT_CA_BUNDLE` to the NOMMA CA chain.
- **HTTP 429/5xx:** requests retry with `Retry-After` or a bounded backoff.
- **Duplicate serial:** fix the duplicate Intune record; the script will not
  choose one.
- **HTTP 400 on primary-user POST:** verify the device is Windows and Entra
  joined or hybrid joined, the user has an Intune license, and the app has
  `DeviceManagementManagedDevices.ReadWrite.All`.
