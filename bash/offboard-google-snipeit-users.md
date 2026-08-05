# Mock-only Google Workspace + Snipe-IT offboarding

`offboard-google-snipeit-users.sh` is a **build/test artifact only**. It has no
network client, live GAM command, Snipe-IT API, SMTP integration, or credential
configuration. It refuses to run unless `MOCK_ONLY=true` and local mock fixtures
are provided.

## Input and safeguards

Input is a UTF-8 CSV with exactly this header and one `@nomma.net` address per
row:

```csv
email
user@nomma.net
```

The default is a dry-run. It validates schema, duplicate rows, permitted domain,
`inactive` prefixes, mock state, collisions, and already-completed state. It
prints a canonical plan SHA-256 and does not mutate mock state.

```bash
MOCK_ONLY=true MOCK_STATE_DIR=/path/to/fixtures \
  ./bash/offboard-google-snipeit-users.sh --csv bash/offboarding.sample.csv
```

An apply requires both flags and the exact hash from a newly reviewed dry-run:

```bash
MOCK_ONLY=true MOCK_STATE_DIR=/path/to/fixtures \
  ./bash/offboard-google-snipeit-users.sh --csv bash/offboarding.sample.csv \
  --apply --confirm-plan-hash '<sha256>'
```

The ordered mock workflow is: suspend, move to `/Inactive`, rename to
`inactive<local-part>@nomma.net`, retain the old primary as alias, set a secure
random password (never stored or printed), verify Google state, soft-deactivate
Snipe-IT, then verify Snipe-IT. It never implements deletion behavior.

## Mock fixture contract

`MOCK_STATE_DIR` must contain:

- `google-users.tsv`: `primary|suspended|ou|comma-separated-aliases|exists`
- `snipe-users.tsv`: `email|active`
- `inactive-ou.available`: an empty marker proving the mock `/Inactive` OU exists
- `actions.log`: an empty writable file used exclusively by the mock adapter.

Test-only fault injection is supported through `MOCK_GAM_FAIL_ACTION`,
`MOCK_GAM_VERIFY_FAIL=true`, and `MOCK_SNIPE_FAIL=true`. These are not production
adapter settings. `REPORT_DIR` optionally sets an output directory; otherwise
reports go under `bash/reports/offboarding`.

Every valid run, including dry-run, writes protected mode-600 human-readable
`offboarding-report.txt`, machine-readable `offboarding-report.json`, and
`restoration-manifest.json` files. The reports record the mode, timestamp, tool
version, plan hash, each resolved address/action/outcome, verification or skip
status, redacted errors, and aggregate totals. The manifest has only minimum
non-secret restoration state: original/new addresses, alias relationship, prior
Google state and OU, Snipe-IT state, action timestamps, plan hash, and a
separate-approval marker. Restoration is never performed automatically and must
be a separately reviewed operation.

## Validation

Run the portable, local-only test harness:

```bash
bash bash/tests/test-offboard-google-snipeit-users.sh
```

It creates temporary fixtures and covers CSV validation, dry run, confirmation,
action ordering, sequencing, Google/Snipe-IT failures, secret redaction,
idempotency/collisions, and manifest restrictions.

## Future production adapters

A separately approved production implementation must replace the local wrappers
with reviewed, dependency-injected GAM and Snipe-IT adapters; add protected
credential handling outside the repository; perform live preflight and approval;
and receive independent security and operational review. This mock-only artifact
must not be pointed at production services.
