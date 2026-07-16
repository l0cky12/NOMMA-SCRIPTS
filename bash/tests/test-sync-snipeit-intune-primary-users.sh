#!/usr/bin/env bash
# shellcheck disable=SC2016 # Literal Microsoft Graph $ref text is intentional.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TARGET="$REPO_ROOT/bash/sync-snipeit-intune-primary-users.sh"
JQ_BIN="${JQ_BIN:-jq}"

command -v "$JQ_BIN" >/dev/null 2>&1 || {
    echo "SKIP: jq is required for mocked tests." >&2
    exit 77
}

work="$(mktemp -d "${TMPDIR:-/tmp}/test-snipe-intune.XXXXXX")"
trap 'rm -rf "$work"' EXIT

fake_curl="$work/fake-curl"
cat >"$fake_curl" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail

method=GET
out=""
headers=""
data=""
url=""
while (($# > 0)); do
    case "$1" in
        -X) method="$2"; shift 2 ;;
        -o) out="$2"; shift 2 ;;
        -D) headers="$2"; shift 2 ;;
        -w) shift 2 ;;
        -H|--connect-timeout|--max-time|--cacert) shift 2 ;;
        --data) data="$2"; shift 2 ;;
        --silent|--show-error|--insecure) shift ;;
        http*) url="$1"; shift ;;
        *) shift ;;
    esac
done

body='{}'
status=200
printf 'HTTP/1.1 200 OK\r\n\r\n' >"$headers"

case "$url" in
    *'/oauth2/v2.0/token')
        if [[ "${TEST_SCENARIO:-normal}" == retry && ! -e "${FAKE_RETRY_STATE:?}" ]]; then
            : >"$FAKE_RETRY_STATE"
            body='{"error":"throttled"}'
            status=429
            printf 'HTTP/1.1 429 Too Many Requests\r\nRetry-After: 0\r\n\r\n' >"$headers"
        else
            body='{"access_token":"mock-graph-token"}'
        fi
        ;;
    *'/groups/'*'/transitiveMembers/microsoft.graph.user'*)
        body='{"value":[{"id":"11111111-1111-1111-1111-111111111111","mail":"alice@nomma.net","userPrincipalName":"alice@nomma.net","displayName":"Alice"}],"@odata.nextLink":"https://graph.microsoft.com/v1.0/mock-group-page-2"}'
        ;;
    *'/mock-group-page-2')
        body='{"value":[{"id":"22222222-2222-2222-2222-222222222222","mail":null,"userPrincipalName":"bob@nomma.net","displayName":"Bob"}]}'
        ;;
    *'/deviceManagement/managedDevices?'*)
        if [[ "${TEST_SCENARIO:-normal}" == duplicate ]]; then
            body='{"value":[{"id":"dev-1","deviceName":"WIN-ALICE","serialNumber":"SN-ALICE","operatingSystem":"Windows","azureADDeviceId":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","deviceEnrollmentType":"windowsAutoEnrollment"},{"id":"dev-duplicate","deviceName":"WIN-ALICE-OLD","serialNumber":"sn-alice","operatingSystem":"Windows","azureADDeviceId":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","deviceEnrollmentType":"windowsAutoEnrollment"}]}'
        else
            body='{"value":[{"id":"dev-1","deviceName":"WIN-ALICE","serialNumber":"SN-ALICE","operatingSystem":"Windows","azureADDeviceId":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","deviceEnrollmentType":"windowsAutoEnrollment"}],"@odata.nextLink":"https://graph.microsoft.com/v1.0/mock-device-page-2"}'
        fi
        ;;
    *'/mock-device-page-2')
        body='{"value":[{"id":"dev-2","deviceName":"WIN-BOB","serialNumber":"SN-BOB","operatingSystem":"Windows","azureADDeviceId":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","deviceEnrollmentType":"windowsAzureADJoin"}]}'
        ;;
    *'/api/v1/users?email=alice%40nomma.net'*)
        body='{"total":1,"rows":[{"id":10,"email":"alice@nomma.net","username":"alice"}]}'
        ;;
    *'/api/v1/users?email=bob%40nomma.net'*)
        body='{"total":1,"rows":[{"id":20,"email":"bob@nomma.net","username":"bob"}]}'
        ;;
    *'/api/v1/hardware?assigned_to=10&assigned_type=App%5CModels%5CUser&limit=100&offset=0')
        if [[ "${TEST_SCENARIO:-normal}" == missing_serial ]]; then
            body='{"total":1,"rows":[{"id":101,"asset_tag":"NOMMA-101","serial":"","assigned_to":{"id":10,"type":"user"}}]}'
        elif [[ "${TEST_SCENARIO:-normal}" == snipe_pagination ]]; then
            body='{"total":2,"rows":[{"id":101,"asset_tag":"NOMMA-101","serial":" SN-ALICE ","assigned_to":{"id":10,"type":"user"}}]}'
        else
            body='{"total":1,"rows":[{"id":101,"asset_tag":"NOMMA-101","serial":" SN-ALICE ","assigned_to":{"id":10,"type":"user"}}]}'
        fi
        ;;
    *'/api/v1/hardware?assigned_to=10&assigned_type=App%5CModels%5CUser&limit=100&offset=1')
        body='{"total":2,"rows":[{"id":102,"asset_tag":"NOMMA-102","serial":"SN-NOT-IN-INTUNE","assigned_to":{"id":10,"type":"user"}}]}'
        ;;
    *'/api/v1/hardware?assigned_to=20&assigned_type=App%5CModels%5CUser&limit=100&offset=0')
        body='{"total":1,"rows":[{"id":202,"asset_tag":"NOMMA-202","serial":"SN-BOB","assigned_to":{"id":20,"type":"user"}}]}'
        ;;
    *'/deviceManagement/managedDevices/dev-1/users?'*)
        body='{"value":[{"id":"99999999-9999-9999-9999-999999999999","userPrincipalName":"old@nomma.net"}]}'
        ;;
    *'/deviceManagement/managedDevices/dev-2/users?'*)
        body='{"value":[{"id":"22222222-2222-2222-2222-222222222222","userPrincipalName":"bob@nomma.net"}]}'
        ;;
    *'/deviceManagement/managedDevices/dev-1/users/$ref')
        [[ "$method" == POST ]] || { status=405; body='{"error":"method"}'; }
        printf '%s\t%s\t%s\n' "$method" "$url" "$data" >>"${FAKE_CURL_LOG:?}"
        body=''
        status=204
        ;;
    *)
        status=404
        body="{\"error\":\"unhandled mock URL: $url\"}"
        ;;
esac

printf '%s' "$body" >"$out"
printf '%s' "$status"
FAKE
chmod +x "$fake_curl"

export ENTRA_TENANT_ID='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
export ENTRA_CLIENT_ID='bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
export ENTRA_CLIENT_SECRET='mock-secret-never-real'
export ENTRA_GROUP_ID='627b0785-7658-4f80-a3ff-c362a723cd4a'
export SNIPEIT_URL='https://snipe.test'
export SNIPEIT_API_TOKEN='mock-snipe-token'
export CURL_BIN="$fake_curl"
export JQ_BIN
export HTTP_RETRY_DELAY=1
export FAKE_CURL_LOG="$work/curl.log"
export FAKE_RETRY_STATE="$work/retry-state"

assert_contains() {
    local needle="$1"
    local file="$2"
    grep -Fq "$needle" "$file" || {
        echo "FAIL: expected '$needle' in $file" >&2
        exit 1
    }
}

assert_not_contains() {
    local needle="$1"
    local file="$2"
    if grep -Fq "$needle" "$file"; then
        echo "FAIL: did not expect '$needle' in $file" >&2
        exit 1
    fi
}

: >"$FAKE_CURL_LOG"
report="$work/alice-dry.csv"
"$TARGET" --user alice@nomma.net --report "$report"
assert_contains 'would-update-primary-user' "$report"
assert_contains 'old@nomma.net' "$report"
assert_not_contains $'POST\thttps://graph.microsoft.com/v1.0/deviceManagement/managedDevices/dev-1/users/$ref' "$FAKE_CURL_LOG"

: >"$FAKE_CURL_LOG"
report="$work/alice-apply.csv"
"$TARGET" --user alice@nomma.net --apply --report "$report"
assert_contains 'updated-primary-user' "$report"
assert_contains $'POST\thttps://graph.microsoft.com/v1.0/deviceManagement/managedDevices/dev-1/users/$ref' "$FAKE_CURL_LOG"
assert_contains 'https://graph.microsoft.com/v1.0/users/11111111-1111-1111-1111-111111111111' "$FAKE_CURL_LOG"

: >"$FAKE_CURL_LOG"
report="$work/bob-dry.csv"
"$TARGET" --user bob@nomma.net --report "$report"
assert_contains 'unchanged-primary-user-correct' "$report"
assert_not_contains $'POST\t' "$FAKE_CURL_LOG"

: >"$FAKE_CURL_LOG"
report="$work/duplicate.csv"
set +e
TEST_SCENARIO=duplicate "$TARGET" --user alice@nomma.net --apply --report "$report"
status=$?
set -e
[[ "$status" -eq 2 ]] || { echo "FAIL: duplicate scenario exit was $status, expected 2" >&2; exit 1; }
assert_contains 'blocked-duplicate-intune-serial' "$report"
assert_not_contains $'POST\t' "$FAKE_CURL_LOG"

: >"$FAKE_CURL_LOG"
report="$work/missing-serial.csv"
set +e
TEST_SCENARIO=missing_serial "$TARGET" --user alice@nomma.net --report "$report"
status=$?
set -e
[[ "$status" -eq 2 ]] || { echo "FAIL: missing-serial exit was $status, expected 2" >&2; exit 1; }
assert_contains 'skipped-missing-serial' "$report"

report="$work/snipe-pagination.csv"
set +e
TEST_SCENARIO=snipe_pagination "$TARGET" --user alice@nomma.net --report "$report"
status=$?
set -e
[[ "$status" -eq 2 ]] || { echo "FAIL: Snipe pagination exit was $status, expected 2" >&2; exit 1; }
assert_contains 'would-update-primary-user' "$report"
assert_contains 'SN-NOT-IN-INTUNE' "$report"
assert_contains 'skipped-intune-device-not-found' "$report"

rm -f "$FAKE_RETRY_STATE"
report="$work/retry.csv"
TEST_SCENARIO=retry "$TARGET" --user bob@nomma.net --report "$report"
[[ -e "$FAKE_RETRY_STATE" ]] || { echo 'FAIL: retry scenario did not receive the mocked 429' >&2; exit 1; }
assert_contains 'unchanged-primary-user-correct' "$report"

set +e
"$TARGET" --apply --report "$work/bulk.csv" </dev/null >"$work/bulk.out" 2>&1
status=$?
set -e
[[ "$status" -eq 1 ]] || { echo "FAIL: noninteractive bulk apply exit was $status, expected 1" >&2; exit 1; }
assert_contains 'Bulk --apply selected 2 users' "$work/bulk.out"

line_count="$(wc -l <"$work/alice-dry.csv")"
[[ "$line_count" -eq 2 ]] || { echo "FAIL: audit CSV expected 2 lines, got $line_count" >&2; exit 1; }

printf 'PASS: dry-run blocks mutation\n'
printf 'PASS: one-user apply uses v1.0 users/$ref relationship\n'
printf 'PASS: transitive Graph pagination, Snipe-IT pagination, and mail-to-UPN fallback\n'
printf 'PASS: idempotent current-user no-op\n'
printf 'PASS: duplicate serial and missing serial block mutation\n'
printf 'PASS: HTTP 429 retries honor Retry-After\n'
printf 'PASS: noninteractive bulk apply requires --yes\n'
printf 'PASS: audit CSV generated\n'
