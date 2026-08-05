#!/usr/bin/env bash
# Mock-only, dry-run-first Google Workspace + Snipe-IT offboarding coordinator.
set -euo pipefail
# Do not permit a caller's `bash -x` invocation to trace generated passwords.
set +x

readonly TOOL_VERSION="0.1.0-mock-only"
readonly ACTION_SEQUENCE="suspend > move:/Inactive > rename > add-alias > set-password > verify-google > soft-deactivate-snipeit > verify-snipeit"
APPLY=false
CONFIRM_HASH=""
CSV=""
MOCK_STATE_DIR="${MOCK_STATE_DIR:-}"
REPORT_DIR="${REPORT_DIR:-}"
PLAN_HASH=""
FAILURES=0

usage() {
    cat <<'EOF'
Usage: offboard-google-snipeit-users.sh --csv PATH [--apply --confirm-plan-hash SHA256]

Mock-only tool. Dry-run is the default. Set MOCK_ONLY=true and point MOCK_STATE_DIR
at test fixtures (google-users.tsv, snipe-users.tsv, actions.log). Reports default
under bash/reports/offboarding. No live adapters are implemented.
EOF
}
fatal() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
sha256() { printf '%s' "$1" | sha256sum | awk '{print $1}'; }
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

while (($#)); do
    case "$1" in
        --csv) (($# >= 2)) || fatal '--csv requires a path'; CSV="$2"; shift 2 ;;
        --apply) APPLY=true; shift ;;
        --confirm-plan-hash) (($# >= 2)) || fatal '--confirm-plan-hash requires a value'; CONFIRM_HASH="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) fatal "unknown option: $1" ;;
    esac
done
[[ -n "$CSV" ]] || fatal '--csv is required'
[[ -z "$CONFIRM_HASH" || "$APPLY" == true ]] || fatal '--confirm-plan-hash requires --apply.'
[[ -r "$CSV" ]] || fatal "CSV is not readable: $CSV"
[[ "${MOCK_ONLY:-}" == true ]] || fatal 'This build supports MOCK_ONLY=true only; live adapters are intentionally unavailable.'
[[ -n "$MOCK_STATE_DIR" && -d "$MOCK_STATE_DIR" ]] || fatal 'MOCK_STATE_DIR must name a mock fixture directory.'
[[ -r "$MOCK_STATE_DIR/google-users.tsv" && -r "$MOCK_STATE_DIR/snipe-users.tsv" && -e "$MOCK_STATE_DIR/inactive-ou.available" ]] || fatal 'mock fixture files or /Inactive OU availability marker are missing.'
command -v sha256sum >/dev/null 2>&1 || fatal 'required command not found: sha256sum'
command -v openssl >/dev/null 2>&1 || fatal 'required command not found: openssl'
mkdir -p "${REPORT_DIR:=$(dirname "$0")/reports/offboarding}"
REPORT="$REPORT_DIR/offboarding-report.txt"
MANIFEST="$REPORT_DIR/restoration-manifest.json"
: >"$REPORT"

mapfile -t csv_lines <"$CSV"
((${#csv_lines[@]} >= 2)) || fatal 'CSV has no data rows.'
[[ "$(trim "${csv_lines[0]//$'\r'/}")" == email ]] || fatal 'CSV header must be exactly: email'
declare -a EMAILS=()
declare -A SEEN=()
for ((i=1; i<${#csv_lines[@]}; i++)); do
    email="$(trim "${csv_lines[$i]//$'\r'/}")"
    [[ -n "$email" ]] || fatal "malformed empty CSV row $((i + 1))"
    [[ "$email" =~ ^[A-Za-z0-9._%+\-]+@nomma\.net$ ]] || {
        [[ "$email" == *@* ]] && fatal "email is outside permitted domain at row $((i + 1))" || fatal "malformed email at row $((i + 1))"
    }
    [[ "$email" != inactive*@nomma.net ]] || fatal "email already has inactive prefix at row $((i + 1))"
    [[ -z "${SEEN[$email]:-}" ]] || fatal "duplicate email: $email"
    SEEN[$email]=1; EMAILS+=("$email")
done

# Parse mock directory into adapter state. The adapter format is intentionally local-only:
# primary|suspended(true/false)|ou|comma-separated-aliases|exists(true/false)
declare -A G_SUSP G_OU G_ALIAS G_EXISTS S_ACTIVE
while IFS='|' read -r primary suspended ou aliases exists; do
    [[ -n "$primary" ]] || continue
    G_SUSP["$primary"]="$suspended"; G_OU["$primary"]="$ou"; G_ALIAS["$primary"]="$aliases"; G_EXISTS["$primary"]="$exists"
done <"$MOCK_STATE_DIR/google-users.tsv"
while IFS='|' read -r email active; do [[ -n "$email" ]] && S_ACTIVE["$email"]="$active"; done <"$MOCK_STATE_DIR/snipe-users.tsv"

find_primary_for_original() {
    local original="$1" primary aliases
    for primary in "${!G_EXISTS[@]}"; do
        aliases=",${G_ALIAS[$primary]},"
        [[ "$primary" == "$original" || "$aliases" == *",$original,"* ]] && { printf '%s' "$primary"; return; }
    done
    return 1
}
plan="version=$TOOL_VERSION\nactions=$ACTION_SEQUENCE\n"
declare -A RESOLVED STATUS PRIOR_PRIMARY PRIOR_OU PRIOR_SNIPE
for email in "${EMAILS[@]}"; do
    inactive="inactive${email%@nomma.net}@nomma.net"; RESOLVED["$email"]="$inactive"
    primary="$(find_primary_for_original "$email" || true)"
    if [[ -n "$primary" && "${G_SUSP[$primary]}" == true && "${G_OU[$primary]}" == /Inactive && ",${G_ALIAS[$primary]}," == *",$email,"* ]]; then
        STATUS["$email"]="already-offboarded"; PRIOR_PRIMARY["$email"]="$primary"; PRIOR_OU["$email"]="/Inactive"; PRIOR_SNIPE["$email"]="${S_ACTIVE[$email]:-unknown}"
    elif [[ -z "$primary" ]]; then
        STATUS["$email"]="failed-user-not-found"
    elif [[ -n "${G_EXISTS[$inactive]:-}" || "$(find_primary_for_original "$inactive" || true)" != "" ]]; then
        STATUS["$email"]="failed-rename-collision"
    else
        STATUS["$email"]="planned"; PRIOR_PRIMARY["$email"]="$primary"; PRIOR_OU["$email"]="${G_OU[$primary]}"; PRIOR_SNIPE["$email"]="${S_ACTIVE[$email]:-unknown}"
    fi
    plan+="email=$email|inactive=$inactive|state=${STATUS[$email]}|prior_ou=${PRIOR_OU[$email]:-unknown}|snipe=${PRIOR_SNIPE[$email]:-unknown}\n"
done
PLAN_HASH="$(sha256 "$plan")"
preflight_failures=0
for email in "${EMAILS[@]}"; do
    [[ "${STATUS[$email]}" == planned || "${STATUS[$email]}" == already-offboarded ]] || preflight_failures=$((preflight_failures + 1))
done

if [[ "$APPLY" != true ]]; then
    dry_failures="$preflight_failures"
    printf 'MODE=dry-run\nPLAN_SHA256=%s\nACTIONS=%s\n' "$PLAN_HASH" "$ACTION_SEQUENCE"
    for email in "${EMAILS[@]}"; do
        printf '%s -> %s: %s\n' "$email" "${RESOLVED[$email]}" "${STATUS[$email]}"
        [[ "${STATUS[$email]}" == planned || "${STATUS[$email]}" == already-offboarded ]] || dry_failures=$((dry_failures + 1))
    done
    if ((dry_failures != 0)); then
        printf 'ERROR: preflight contains collision or invalid target state.\n' >&2
        exit 2
    fi
    exit 0
fi
[[ -n "$CONFIRM_HASH" ]] || fatal 'apply requires --confirm-plan-hash for the exact generated plan.'
[[ "$CONFIRM_HASH" == "$PLAN_HASH" ]] || fatal 'confirmed plan hash does not match the exact generated plan.'
((preflight_failures == 0)) || fatal 'apply refused because preflight contains collision or invalid target state.'

printf 'timestamp=%s\ntool_version=%s\nmode=apply\nplan_sha256=%s\nactions=%s\n' "$(now)" "$TOOL_VERSION" "$PLAN_HASH" "$ACTION_SEQUENCE" >>"$REPORT"
log_action() { printf '%s\n' "$1" >>"$MOCK_STATE_DIR/actions.log"; }
update_google_file() {
    local old="$1" new="$2" suspended="$3" ou="$4" aliases="$5" tmp
    tmp="$(mktemp "$MOCK_STATE_DIR/google-users.tsv.XXXXXX")"
    while IFS='|' read -r primary a b c d; do
        [[ "$primary" == "$old" ]] && printf '%s|%s|%s|%s|true\n' "$new" "$suspended" "$ou" "$aliases" || printf '%s|%s|%s|%s|%s\n' "$primary" "$a" "$b" "$c" "$d"
    done <"$MOCK_STATE_DIR/google-users.tsv"; mv "$tmp" "$MOCK_STATE_DIR/google-users.tsv"
}
process_user() {
    local email="$1" inactive="${RESOLVED[$1]}" primary="${PRIOR_PRIMARY[$1]:-}" aliases password
    if [[ "${STATUS[$email]}" == already-offboarded ]]; then
        printf 'entry=%s|inactive=%s|outcome=already-offboarded|google=verified|snipeit=already-inactive|skipped=false\n' "$email" "$inactive" >>"$REPORT"; return 0
    fi
    if [[ "${STATUS[$email]}" != planned ]]; then
        printf 'entry=%s|inactive=%s|outcome=failed|google=not-run|snipeit=skipped|error=preflight-validation\n' "$email" "$inactive" >>"$REPORT"; return 1
    fi
    for action in suspend move rename alias password; do
        [[ "${MOCK_GAM_FAIL_ACTION:-}" != "$action" ]] || { printf 'entry=%s|inactive=%s|outcome=failed|google=failed|snipeit=skipped|error=google-%s-failed\n' "$email" "$inactive" "$action" >>"$REPORT"; return 1; }
        case "$action" in
            suspend) log_action "suspend:$primary" ;;
            move) log_action "move:$primary:/Inactive" ;;
            rename) log_action "rename:$primary:$inactive" ;;
            alias) log_action "alias:$inactive:$email" ;;
            password) password="$(openssl rand -hex 32)"; [[ -n "$password" ]]; log_action "password:$inactive" ;;
        esac
    done
    aliases="${G_ALIAS[$primary]}"; aliases="${aliases:+$aliases,}$email"
    update_google_file "$primary" "$inactive" true /Inactive "$aliases"
    log_action "verify-google:$inactive"
    if [[ "${MOCK_GAM_VERIFY_FAIL:-}" == true ]]; then
        printf 'entry=%s|inactive=%s|outcome=failed|google=failed-verification|snipeit=skipped|error=google-verification-failed\n' "$email" "$inactive" >>"$REPORT"; return 1
    fi
    log_action "soft-deactivate-snipeit:$email"
    if [[ "${MOCK_SNIPE_FAIL:-}" == true ]]; then
        printf 'entry=%s|inactive=%s|outcome=snipeit-failed|google=verified|snipeit=failed|error=snipeit-soft-deactivation-failed\n' "$email" "$inactive" >>"$REPORT"; return 1
    fi
    log_action "verify-snipeit:$email"
    printf 'entry=%s|inactive=%s|outcome=offboarded|google=verified|snipeit=soft-deactivated|skipped=false\n' "$email" "$inactive" >>"$REPORT"
}
for email in "${EMAILS[@]}"; do process_user "$email" || FAILURES=$((FAILURES + 1)); done
printf 'totals=processed:%s failures:%s\n' "${#EMAILS[@]}" "$FAILURES" >>"$REPORT"
(
    umask 077
    {
        printf '{\n  "plan_sha256": "%s",\n  "restoration_requires_separate_approval": true,\n  "entries": [\n' "$PLAN_HASH"
        for ((i=0; i<${#EMAILS[@]}; i++)); do email="${EMAILS[$i]}"; printf '    {"original_primary":"%s","new_primary":"%s","alias_relationship":"%s retained as alias","prior_google_ou":"%s","prior_snipeit_active":"%s","action_timestamp":"%s"}%s\n' "$email" "${RESOLVED[$email]}" "$email" "${PRIOR_OU[$email]:-unknown}" "${PRIOR_SNIPE[$email]:-unknown}" "$(now)" "$([[ $i -lt $((${#EMAILS[@]} - 1)) ]] && printf ',' || true)"; done
        printf '  ]\n}\n'
    } >"$MANIFEST"
    chmod 600 "$MANIFEST"
)
((FAILURES == 0)) || exit 2
printf 'MODE=apply\nPLAN_SHA256=%s\nREPORT=%s\nMANIFEST=%s\n' "$PLAN_HASH" "$REPORT" "$MANIFEST"
