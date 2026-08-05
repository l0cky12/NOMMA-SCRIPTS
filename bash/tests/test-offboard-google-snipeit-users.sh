#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TARGET="$REPO_ROOT/bash/offboard-google-snipeit-users.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/offboard-tests.XXXXXX")"
trap 'rm -rf "$work"' EXIT
pass=0

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_contains() { grep -Fq "$1" "$2" || fail "expected '$1' in $2"; }
assert_not_contains() { ! grep -Fq "$1" "$2" || fail "did not expect '$1' in $2"; }
assert_status() { [[ "$1" -eq "$2" ]] || fail "exit was $1, expected $2"; }
run_expect_fail() { set +e; "$@" >"$work/out" 2>"$work/err"; status=$?; set -e; [[ "$status" -ne 0 ]] || fail "command unexpectedly succeeded: $*"; }

setup_mock() {
    local name="$1"
    MOCK_STATE_DIR="$work/$name/state"
    REPORT_DIR="$work/$name/reports"
    mkdir -p "$MOCK_STATE_DIR" "$REPORT_DIR"
    cat >"$MOCK_STATE_DIR/google-users.tsv" <<'EOF'
user@nomma.net|false|/Staff||true
inactivealready@nomma.net|true|/Inactive|already@nomma.net|true
collision@nomma.net|false|/Staff||true
inactivecollision@nomma.net|false|/Staff||true
EOF
    cat >"$MOCK_STATE_DIR/snipe-users.tsv" <<'EOF'
user@nomma.net|true
already@nomma.net|false
collision@nomma.net|true
EOF
    : >"$MOCK_STATE_DIR/inactive-ou.available"
    : >"$MOCK_STATE_DIR/actions.log"
    printf 'email\nuser@nomma.net\n' >"$work/$name/input.csv"
    export MOCK_STATE_DIR REPORT_DIR
}
run_tool() { MOCK_ONLY=true "$TARGET" "$@"; }
plan_hash() { run_tool --csv "$1" 2>&1 | awk -F= '/^PLAN_SHA256=/{print $2}'; }

# 1. CSV parsing: malformed, duplicate, empty, and domain rejection.
setup_mock csv
printf 'email\nuser@nomma.net\nuser@nomma.net\n' >"$work/csv/duplicate.csv"
run_expect_fail run_tool --csv "$work/csv/duplicate.csv"
assert_contains 'duplicate' "$work/err"
printf 'email\noutside@example.test\n' >"$work/csv/domain.csv"
run_expect_fail run_tool --csv "$work/csv/domain.csv"
assert_contains 'permitted domain' "$work/err"
printf 'email\nnot-an-email\n' >"$work/csv/malformed.csv"
run_expect_fail run_tool --csv "$work/csv/malformed.csv"
assert_contains 'malformed' "$work/err"
printf 'email\n' >"$work/csv/empty.csv"
run_expect_fail run_tool --csv "$work/csv/empty.csv"
assert_contains 'no data rows' "$work/err"
pass=$((pass + 1)); printf 'PASS 1: CSV validation\n'

# 2. Dry-run is non-mutating and prints ordered plan plus hash.
setup_mock dry
run_tool --csv "$work/dry/input.csv" >"$work/dry/out"
assert_contains 'PLAN_SHA256=' "$work/dry/out"
assert_contains 'suspend > move:/Inactive > rename > add-alias > set-password > verify-google > soft-deactivate-snipeit > verify-snipeit' "$work/dry/out"
[[ ! -s "$MOCK_STATE_DIR/actions.log" ]] || fail 'dry run invoked mutation wrapper'
pass=$((pass + 1)); printf 'PASS 2: dry-run safeguards\n'

# 3. Apply requires apply flag and exact plan hash.
setup_mock approval
hash="$(plan_hash "$work/approval/input.csv")"
run_expect_fail run_tool --csv "$work/approval/input.csv" --confirm-plan-hash "$hash"
assert_contains 'requires --apply' "$work/err"
run_expect_fail run_tool --csv "$work/approval/input.csv" --apply --confirm-plan-hash bad
assert_contains 'does not match' "$work/err"
pass=$((pass + 1)); printf 'PASS 3: apply approval\n'

# 4. Correct Google action order.
setup_mock order
hash="$(plan_hash "$work/order/input.csv")"
run_tool --csv "$work/order/input.csv" --apply --confirm-plan-hash "$hash" >"$work/order/out"
expected=$'suspend:user@nomma.net\nmove:user@nomma.net:/Inactive\nrename:user@nomma.net:inactiveuser@nomma.net\nalias:inactiveuser@nomma.net:user@nomma.net\npassword:inactiveuser@nomma.net\nverify-google:inactiveuser@nomma.net'
[[ "$(head -n 6 "$MOCK_STATE_DIR/actions.log")" == "$expected" ]] || fail 'Google action order incorrect'
pass=$((pass + 1)); printf 'PASS 4: Google action order\n'

# 5. Snipe-IT follows Google verification only.
setup_mock sequencing
hash="$(plan_hash "$work/sequencing/input.csv")"
run_tool --csv "$work/sequencing/input.csv" --apply --confirm-plan-hash "$hash" >/dev/null
[[ "$(tail -n 2 "$MOCK_STATE_DIR/actions.log")" == $'soft-deactivate-snipeit:user@nomma.net\nverify-snipeit:user@nomma.net' ]] || fail 'Snipe-IT ordering incorrect'
pass=$((pass + 1)); printf 'PASS 5: Snipe-IT sequencing\n'

# 6. Google failure blocks Snipe-IT and records failure report.
setup_mock gamfail
hash="$(plan_hash "$work/gamfail/input.csv")"
set +e; MOCK_GAM_FAIL_ACTION=move run_tool --csv "$work/gamfail/input.csv" --apply --confirm-plan-hash "$hash" >"$work/gamfail/out" 2>"$work/gamfail/err"; status=$?; set -e
assert_status "$status" 2
assert_not_contains 'soft-deactivate-snipeit' "$MOCK_STATE_DIR/actions.log"
assert_contains 'failed' "$REPORT_DIR/offboarding-report.txt"
pass=$((pass + 1)); printf 'PASS 6: Google failure isolation\n'

# 7. Snipe soft-deactivation failure is reported and non-destructive.
setup_mock snipefail
hash="$(plan_hash "$work/snipefail/input.csv")"
set +e; MOCK_SNIPE_FAIL=true run_tool --csv "$work/snipefail/input.csv" --apply --confirm-plan-hash "$hash" >/dev/null; status=$?; set -e
assert_status "$status" 2
assert_contains 'snipeit-failed' "$REPORT_DIR/offboarding-report.txt"
assert_not_contains 'delete' "$MOCK_STATE_DIR/actions.log"
pass=$((pass + 1)); printf 'PASS 7: Snipe-IT failure reporting\n'

# 8. Passwords and mock secret values never appear in outputs or artifacts.
setup_mock secret
hash="$(plan_hash "$work/secret/input.csv")"
MOCK_SECRET='mock-secret-value' run_tool --csv "$work/secret/input.csv" --apply --confirm-plan-hash "$hash" >"$work/secret/out" 2>"$work/secret/err"
assert_not_contains 'mock-secret-value' "$work/secret/out"
assert_not_contains 'mock-secret-value' "$REPORT_DIR/offboarding-report.txt"
assert_not_contains 'password=' "$REPORT_DIR/offboarding-report.txt"
pass=$((pass + 1)); printf 'PASS 8: secret redaction\n'

# 9. Already-offboarded state is idempotent; collision is blocked.
setup_mock idempotent
printf 'email\nalready@nomma.net\n' >"$work/idempotent/already.csv"
run_tool --csv "$work/idempotent/already.csv" >"$work/idempotent/out"
assert_contains 'already-offboarded' "$work/idempotent/out"
printf 'email\ncollision@nomma.net\n' >"$work/idempotent/collision.csv"
run_expect_fail run_tool --csv "$work/idempotent/collision.csv"
assert_contains 'collision' "$work/err"
pass=$((pass + 1)); printf 'PASS 9: idempotency and collision\n'

# 10. Restoration manifest records non-secret minimum state only.
setup_mock manifest
hash="$(plan_hash "$work/manifest/input.csv")"
run_tool --csv "$work/manifest/input.csv" --apply --confirm-plan-hash "$hash" >/dev/null
manifest="$REPORT_DIR/restoration-manifest.json"
assert_contains 'original_primary' "$manifest"
assert_contains 'prior_google_ou' "$manifest"
assert_contains 'prior_snipeit_active' "$manifest"
assert_contains 'restoration_requires_separate_approval' "$manifest"
assert_not_contains 'password' "$manifest"
assert_not_contains 'token' "$manifest"
[[ "$(stat -c '%a' "$manifest")" == 600 ]] || fail 'manifest permissions are not 600'
pass=$((pass + 1)); printf 'PASS 10: restoration manifest\n'
printf 'PASS: %s scenarios\n' "$pass"
