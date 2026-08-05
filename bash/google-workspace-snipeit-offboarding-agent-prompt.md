# Google Workspace + Snipe-IT Offboarding Tool — Coding-Agent Prompt

> Copy and paste everything below into a coding agent. This is a **build-only, mocks-only** request: the agent must implement and test the tool locally but must not contact Google Workspace, Snipe-IT, or any other live service.

```text
Build a safety-first Bash offboarding tool that coordinates Google Workspace and Snipe-IT.

## Repository, placement, and Git delivery requirements

Work in the existing local clone of the `NOMMA-SCRIPTS` repository. Before editing anything:

1. Enter the existing repository clone and verify its repository root.
2. Review and report the current Git state and configured remotes, including:
   - `git status --short`
   - `git branch --show-current`
   - `git remote -v`
3. Confirm that the configured `origin` remote is the intended GitHub remote. Do not change Git remotes, Git credentials, or Git configuration.
4. Create and switch to a new descriptive topic branch, such as `feat/google-workspace-snipeit-offboarding`. Do not work directly on the default branch.

Implement the executable tool at exactly:

```text
bash/offboard-google-snipeit-users.sh
```

Keep all implementation, tests, fixtures, and documentation changes scoped to this offboarding tool and its support files within the existing repository conventions. Do not create a separate repository, place the primary tool outside `bash/`, or modify unrelated files.

After implementation and successful local mock-only validation:

1. Review the final scoped diff and ensure no credentials, secrets, or unrelated changes are included.
2. Commit the scoped implementation on the topic branch with a clear commit message.
3. Push that topic branch to the configured GitHub `origin` remote using an upstream-setting push, for example:
   ```bash
   git push -u origin <branch-name>
   ```
4. Report the branch name, resulting commit SHA, complete changed-file list, exact validation commands and results, and the actual `git push` command/output.

Do not open a pull request unless explicitly asked. Do not force-push. Do not push to the default branch. Do not use, request, print, store, commit, or modify GitHub credentials; rely only on the already configured local Git authentication if available. If the push fails because authentication, remote configuration, permissions, or network access is unavailable, do not bypass the failure or use alternate credentials. Report the exact failure and leave the completed local branch and commit intact.

## Safety boundary

Work only in the local repository and use mock commands/fixtures for all integrations. Do not contact live Google Workspace, Snipe-IT, SMTP, secrets managers, or any external API. Do not request, store, print, commit, or embed real credentials, API tokens, service-account keys, real personal email addresses, or production URLs.

## Deliverable

Implement a documented Bash tool and its automated validation tests. The tool accepts a CSV containing one email address per row (with a documented header format), produces a deterministic plan, defaults to dry-run, and performs no mutation unless all apply safeguards are explicitly satisfied.

Use placeholder/sample addresses only. The required transformation example is:

- Original primary address: `user@nomma.net`
- New primary address: `inactiveuser@nomma.net`
- Preserve `user@nomma.net` as an alias after the rename

Do not hard-code a real person's address. Derive the new local part by prefixing `inactive` to the original local part. Reject inputs that already have the prefix, are outside the permitted domain, are malformed, or would collide with an existing account/alias according to the mock lookup.

## Required workflow

For every validated CSV entry, generate a plan that performs these Google Workspace actions in this exact order when applying:

1. Read and validate the current Google user state through a GAM adapter/command wrapper.
2. Suspend the Google Workspace user with GAM.
3. Move the suspended user to Google organizational unit `/Inactive`.
4. Rename the primary email from `user@nomma.net` to `inactiveuser@nomma.net`.
5. Add the original address (`user@nomma.net`) back as an email alias.
6. Generate a cryptographically secure random password using an OS-supported secure source (for example `openssl rand`); apply it only through the GAM wrapper and never print, log, report, or retain the password.
7. Re-read Google Workspace through GAM and verify all required postconditions: the account is suspended, is in `/Inactive`, has the renamed primary email, and has the original email alias.
8. Only after that Google verification succeeds, soft-deactivate the corresponding Snipe-IT user through a Snipe-IT adapter/command wrapper. Do not delete users, assets, checkouts, history, or any Snipe-IT record.
9. Verify and report the Snipe-IT soft-deactivation result.

If any Google action or Google verification fails, stop that user's workflow, record the failure, and do not call Snipe-IT for that user. Continue with other independent users only when a documented fail-safe policy permits it; the final exit status must indicate any failure.

## Safety requirements

- **Build-only/mocks-only:** provide dependency-injected wrappers or command variables for GAM and Snipe-IT. Tests must use mocks and fixtures; no test may invoke a live endpoint or production command.
- **Dry run by default:** without `--apply`, make no changes. Print the planned actions and validation findings only.
- **Explicit apply approvals:** an apply run must require both `--apply` and an explicit confirmation mechanism such as `--confirm-plan-hash <hash>` (or an equivalent documented non-interactive approval). Refuse apply if the supplied hash does not exactly match the generated plan.
- **Plan hash:** serialize the plan canonically, calculate a SHA-256 plan hash, display it in dry-run output, and include it in all reports/manifests. Do not use a hash as authorization by itself; require the explicit apply flag as well.
- **Secret avoidance:** do not echo secrets, passwords, API tokens, authorization headers, service-account JSON, or full environment contents. Redact sensitive values in errors and reports. Include only `.env.example`-style placeholder configuration if configuration files are needed.
- **Least destructive behavior:** never delete a Google user, alias, Snipe-IT user, asset, checkout, or audit history. Snipe-IT action must be a reversible soft deactivation only.
- **Preflight checks:** validate CSV schema, duplicate inputs, domain allowlist, required tools, mock configuration, target user state, target `/Inactive` OU availability, and rename/alias collisions before applying.
- **Idempotency and retry safety:** clearly detect and report already-completed safe states. Do not create duplicate aliases or repeat destructive-equivalent actions. Make retry behavior explicit.
- **No implicit batch authorization:** require one verified plan hash for the exact input and resolved plan. Changing CSV contents or preflight-resolved state must require generating and confirming a new plan.

## Inputs and interface

Document a clear CLI such as:

```bash
# Default: dry run using mocks; prints the plan hash.
./bash/offboard-google-snipeit-users.sh --csv offboarding.csv

# Apply only after reviewing the generated plan and explicitly confirming its hash.
./bash/offboard-google-snipeit-users.sh --csv offboarding.csv --apply --confirm-plan-hash '<sha256>'
```

Use a CSV format such as:

```csv
email
user@nomma.net
another.user@nomma.net
```

Keep test-only configuration separate from runtime configuration. If environment variables are supported, validate that their values are nonempty without printing them.

## Reporting and restoration manifest

Create machine-readable and human-readable reports for every run. Each report must include at least:

- run timestamp, tool version, mode (`dry-run` or `apply`), and plan SHA-256 hash;
- each input email, resolved inactive email, outcome, action sequence, timestamps, and redacted error details;
- Google verification status and whether Snipe-IT was intentionally skipped;
- Snipe-IT soft-deactivation status;
- clear aggregate totals and a nonzero exit code when any entry fails.

Also create a protected, access-controlled restoration manifest that contains only the minimum non-secret state necessary to restore an offboarded account. It must record the original and new primary addresses, alias relationship, original Google OU/state when available, prior Snipe-IT activation state, action timestamps, plan hash, and restoration prerequisites. Never include passwords, tokens, secrets, or credential material. Document that restoration is a separately reviewed operation requiring explicit approval and is not automatically executed by the offboarding tool.

## Validation and tests

Provide automated Bash tests (for example using Bats or a portable test harness) with mock GAM and Snipe-IT adapters. At minimum, cover:

1. CSV parsing, malformed rows, duplicates, empty input, and domain rejection.
2. Dry-run behavior: no mutation wrapper calls; planned order and plan hash are shown.
3. Apply refusal without `--apply` and without a matching explicit plan-hash confirmation.
4. Correct Google action order: suspend, move to `/Inactive`, rename, add old-address alias, set secure random password, then verify.
5. Snipe-IT is called only after successful Google verification.
6. Google failure or verification failure prevents Snipe-IT mutation and produces a failure report.
7. Snipe-IT soft-deactivation failure is reported without deleting anything.
8. Passwords and mock secrets never appear in stdout, stderr, reports, manifests, shell traces, or committed fixtures.
9. Idempotent/already-offboarded and collision scenarios.
10. Restoration manifest contains required non-secret fields and excludes password/token/key fields.

Run the test suite locally with mocks and report the actual command and result. Add concise documentation describing setup, mock-only test mode, CLI usage, safeguards, report locations, restore-manifest handling, and explicitly how an operator would later configure adapters for a separately approved production deployment. Do not implement or perform live production configuration, live authentication, live API calls, or any account changes.

Before finishing, provide:

1. A short implementation summary.
2. The topic branch name.
3. The final commit SHA.
4. A complete list of changed files.
5. Exact local validation/test commands and their results.
6. The exact `git push` command and its actual output.
7. Any assumptions, remaining production-readiness decisions, or Git push blockers.

Do not claim live service validation, production readiness, or successful GitHub delivery unless the corresponding mock-only test output or actual `git push` output proves it.
```
