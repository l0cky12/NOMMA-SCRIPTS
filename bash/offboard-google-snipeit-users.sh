#!/usr/bin/env bash
# Mock-only, dry-run-first Google Workspace + Snipe-IT offboarding coordinator.
set -euo pipefail
set +x

readonly TOOL_VERSION="0.2.0-mock-only"
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
at local fixtures. Each valid run creates protected text/JSON reports and a protected
restoration manifest. No live adapters are implemented.
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
umask 077
REPORT="$REPORT_DIR/offboarding-report.txt"
MACHINE_REPORT="$REPORT_DIR/offboarding-report.json"
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
    SEEN["$email"]=1; EMAILS+=("$email")
done

# Local-only mock adapter state re-read. No live command or endpoint is available.
declare -A G_SUSP G_OU G_ALIAS G_EXISTS S_ACTIVE
read_mock_state() {
    local primary suspended ou aliases exists snipe_email active
    G_SUSP=(); G_OU=(); G_ALIAS=(); G_EXISTS=(); S_ACTIVE=()
    while IFS='|' read -r primary suspended ou aliases exists; do
        [[ -n "$primary" ]] || continue
        G_SUSP["$primary"]="$suspended"; G_OU["$primary"]="$ou"; G_ALIAS["$primary"]="$aliases"; G_EXISTS["$primary"]="$exists"
    done <"$MOCK_STATE_DIR/google-users.tsv"
    while IFS='|' read -r snipe_email active; do
        [[ -n "$snipe_email" ]] && S_ACTIVE["$snipe_email"]="$active"
    done <"$MOCK_STATE_DIR/snipe-users.tsv"
}
find_primary_for_original() {
    local original="$1" primary aliases
    for primary in "${!G_EXISTS[@]}"; do
        aliases=",${G_ALIAS[$primary]},"
        [[ "${G_EXISTS[$primary]}" == true && ( "$primary" == "$original" || "$aliases" == *",$original,"* ) ]] && { printf '%s' "$primary"; return 0; }
    done
    return 1
}
google_postconditions_hold() {
    local original="$1" inactive="$2" aliases
    read_mock_state
    aliases=",${G_ALIAS[$inactive]:-},"
    [[ "${G_EXISTS[$inactive]:-}" == true && "${G_SUSP[$inactive]:-}" == true && "${G_OU[$inactive]:-}" == /Inactive && "$aliases" == *",$original,"* ]]
}
snipe_postcondition_holds() { read_mock_state; [[ "${S_ACTIVE[$1]:-missing}" == false ]]; }

read_mock_state
plan="version=$TOOL_VERSION\nactions=$ACTION_SEQUENCE\n"
declare -A RESOLVED STATUS PRIOR_PRIMARY PRIOR_OU PRIOR_SUSP PRIOR_SNIPE ENTRY_TS OUTCOME GOOGLE_RESULT SNIPE_RESULT SKIPPED ERROR_DETAIL
for email in "${EMAILS[@]}"; do
    inactive="inactive${email%@nomma.net}@nomma.net"; RESOLVED["$email"]="$inactive"
    primary="$(find_primary_for_original "$email" || true)"
    PRIOR_SNIPE["$email"]="${S_ACTIVE[$email]:-missing}"
    if [[ "${S_ACTIVE[$email]:-}" != true && "${S_ACTIVE[$email]:-}" != false ]]; then
        STATUS["$email"]="failed-snipe-user-not-found"
    elif [[ -z "$primary" ]]; then
        STATUS["$email"]="failed-user-not-found"
    else
        PRIOR_PRIMARY["$email"]="$primary"; PRIOR_OU["$email"]="${G_OU[$primary]}"; PRIOR_SUSP["$email"]="${G_SUSP[$primary]}"
        if google_postconditions_hold "$email" "$inactive"; then
            if [[ "${S_ACTIVE[$email]}" == false ]]; then STATUS["$email"]="already-offboarded"; else STATUS["$email"]="google-complete-snipe-planned"; fi
        elif [[ -n "${G_EXISTS[$inactive]:-}" || -n "$(find_primary_for_original "$inactive" || true)" ]]; then
            STATUS["$email"]="failed-rename-collision"
        else
            STATUS["$email"]="planned"
        fi
    fi
    plan+="email=$email|inactive=$inactive|state=${STATUS[$email]}|prior_ou=${PRIOR_OU[$email]:-unknown}|snipe=${PRIOR_SNIPE[$email]}\n"
done
PLAN_HASH="$(sha256 "$plan")"
preflight_failures=0
for email in "${EMAILS[@]}"; do
    [[ "${STATUS[$email]}" == planned || "${STATUS[$email]}" == already-offboarded || "${STATUS[$email]}" == google-complete-snipe-planned ]] || preflight_failures=$((preflight_failures + 1))
done

write_artifacts() {
    local mode="$1" generated_at="$2" email comma=""
    {
        printf 'timestamp=%s\ntool_version=%s\nmode=%s\nplan_sha256=%s\nactions=%s\n' "$generated_at" "$TOOL_VERSION" "$mode" "$PLAN_HASH" "$ACTION_SEQUENCE"
        for email in "${EMAILS[@]}"; do
            printf 'entry=%s|inactive=%s|outcome=%s|actions=%s|timestamp=%s|google=%s|snipeit=%s|skipped=%s|error=%s\n' "$email" "${RESOLVED[$email]}" "${OUTCOME[$email]:-${STATUS[$email]}}" "$ACTION_SEQUENCE" "${ENTRY_TS[$email]:-$generated_at}" "${GOOGLE_RESULT[$email]:-planned}" "${SNIPE_RESULT[$email]:-planned}" "${SKIPPED[$email]:-false}" "${ERROR_DETAIL[$email]:-none}"
        done
        printf 'totals=processed:%s failures:%s\n' "${#EMAILS[@]}" "$FAILURES"
    } >"$REPORT"
    {
        printf '{\n  "timestamp": "%s",\n  "tool_version": "%s",\n  "mode": "%s",\n  "plan_sha256": "%s",\n  "totals": {"processed": %s, "failures": %s},\n  "entries": [\n' "$generated_at" "$TOOL_VERSION" "$mode" "$PLAN_HASH" "${#EMAILS[@]}" "$FAILURES"
        for email in "${EMAILS[@]}"; do
            printf '%s    {"input_email":"%s","resolved_inactive_email":"%s","outcome":"%s","actions":"%s","timestamp":"%s","google_verification":"%s","snipeit_status":"%s","snipeit_skipped":%s,"error":"%s"}' "$comma" "$email" "${RESOLVED[$email]}" "${OUTCOME[$email]:-${STATUS[$email]}}" "$ACTION_SEQUENCE" "${ENTRY_TS[$email]:-$generated_at}" "${GOOGLE_RESULT[$email]:-planned}" "${SNIPE_RESULT[$email]:-planned}" "${SKIPPED[$email]:-false}" "${ERROR_DETAIL[$email]:-none}"
            comma=","; printf '\n'
        done
        printf '  ]\n}\n'
    } >"$MACHINE_REPORT"
    {
        printf '{\n  "timestamp": "%s",\n  "tool_version": "%s",\n  "mode": "%s",\n  "plan_sha256": "%s",\n  "restoration_requires_separate_approval": true,\n  "restoration_prerequisites": "separate reviewed approval and verified mock adapter state",\n  "entries": [\n' "$generated_at" "$TOOL_VERSION" "$mode" "$PLAN_HASH"
        comma=""
        for email in "${EMAILS[@]}"; do
            printf '%s    {"original_primary": "%s", "new_primary": "%s", "alias_relationship": "%s retained as alias", "original_google_suspended": "%s", "prior_google_ou": "%s", "prior_snipeit_active": "%s", "action_timestamp": "%s"}' "$comma" "$email" "${RESOLVED[$email]}" "$email" "${PRIOR_SUSP[$email]:-unknown}" "${PRIOR_OU[$email]:-unknown}" "${PRIOR_SNIPE[$email]}" "${ENTRY_TS[$email]:-$generated_at}"
            comma=","; printf '\n'
        done
        printf '  ]\n}\n'
    } >"$MANIFEST"
    chmod 600 "$REPORT" "$MACHINE_REPORT" "$MANIFEST"
}

if [[ "$APPLY" != true ]]; then
    for email in "${EMAILS[@]}"; do
        ENTRY_TS["$email"]="$(now)"; OUTCOME["$email"]="${STATUS[$email]}"; GOOGLE_RESULT["$email"]="planned"; SNIPE_RESULT["$email"]="planned"; SKIPPED["$email"]=false; ERROR_DETAIL["$email"]=none
    done
    FAILURES=$preflight_failures
    write_artifacts dry-run "$(now)"
    printf 'MODE=dry-run\nPLAN_SHA256=%s\nACTIONS=%s\nREPORT=%s\nMACHINE_REPORT=%s\nMANIFEST=%s\n' "$PLAN_HASH" "$ACTION_SEQUENCE" "$REPORT" "$MACHINE_REPORT" "$MANIFEST"
    for email in "${EMAILS[@]}"; do printf '%s -> %s: %s\n' "$email" "${RESOLVED[$email]}" "${STATUS[$email]}"; done
    ((FAILURES == 0)) || { printf 'ERROR: preflight contains collision or invalid target state.\n' >&2; exit 2; }
    exit 0
fi
[[ -n "$CONFIRM_HASH" ]] || fatal 'apply requires --confirm-plan-hash for the exact generated plan.'
[[ "$CONFIRM_HASH" == "$PLAN_HASH" ]] || fatal 'confirmed plan hash does not match the exact generated plan.'
((preflight_failures == 0)) || fatal 'apply refused because preflight contains collision or invalid target state.'

log_action() { printf '%s\n' "$1" >>"$MOCK_STATE_DIR/actions.log"; }
update_google_file() {
    local old="$1" new="$2" suspended="$3" ou="$4" aliases="$5" tmp primary a b c d
    tmp="$(mktemp "$MOCK_STATE_DIR/google-users.tsv.XXXXXX")"
    while IFS='|' read -r primary a b c d; do
        [[ "$primary" == "$old" ]] && printf '%s|%s|%s|%s|true\n' "$new" "$suspended" "$ou" "$aliases" || printf '%s|%s|%s|%s|%s\n' "$primary" "$a" "$b" "$c" "$d"
    done <"$MOCK_STATE_DIR/google-users.tsv" >"$tmp"
    mv "$tmp" "$MOCK_STATE_DIR/google-users.tsv"
}
update_snipe_file() {
    local target="$1" tmp email active
    tmp="$(mktemp "$MOCK_STATE_DIR/snipe-users.tsv.XXXXXX")"
    while IFS='|' read -r email active; do
        [[ "$email" == "$target" ]] && printf '%s|false\n' "$email" || printf '%s|%s\n' "$email" "$active"
    done <"$MOCK_STATE_DIR/snipe-users.tsv" >"$tmp"
    mv "$tmp" "$MOCK_STATE_DIR/snipe-users.tsv"
}
process_user() {
    local email="$1" inactive="${RESOLVED[$1]}" primary="${PRIOR_PRIMARY[$1]:-}" aliases password action
    ENTRY_TS["$email"]="$(now)"; ERROR_DETAIL["$email"]=none; SKIPPED["$email"]=false
    if [[ "${STATUS[$email]}" == already-offboarded ]]; then
        google_postconditions_hold "$email" "$inactive" && snipe_postcondition_holds "$email" || { OUTCOME["$email"]=failed; GOOGLE_RESULT["$email"]=failed-verification; SNIPE_RESULT["$email"]=skipped; SKIPPED["$email"]=true; ERROR_DETAIL["$email"]=state-reread-failed; return 1; }
        OUTCOME["$email"]=already-offboarded; GOOGLE_RESULT["$email"]=verified; SNIPE_RESULT["$email"]=already-inactive; return 0
    fi
    if [[ "${STATUS[$email]}" == planned ]]; then
        for action in suspend move rename alias password; do
            [[ "${MOCK_GAM_FAIL_ACTION:-}" != "$action" ]] || { OUTCOME["$email"]=failed; GOOGLE_RESULT["$email"]=failed; SNIPE_RESULT["$email"]=skipped; SKIPPED["$email"]=true; ERROR_DETAIL["$email"]=google-action-failed; return 1; }
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
    fi
    log_action "verify-google:$inactive"
    if [[ "${MOCK_GAM_VERIFY_FAIL:-}" == true ]] || ! google_postconditions_hold "$email" "$inactive"; then
        OUTCOME["$email"]=failed; GOOGLE_RESULT["$email"]=failed-verification; SNIPE_RESULT["$email"]=skipped; SKIPPED["$email"]=true; ERROR_DETAIL["$email"]=google-postcondition-failed; return 1
    fi
    GOOGLE_RESULT["$email"]=verified
    log_action "soft-deactivate-snipeit:$email"
    if [[ "${MOCK_SNIPE_FAIL:-}" == true ]]; then
        OUTCOME["$email"]=snipeit-failed; SNIPE_RESULT["$email"]=failed; ERROR_DETAIL["$email"]=snipeit-soft-deactivation-failed; return 1
    fi
    update_snipe_file "$email"
    log_action "verify-snipeit:$email"
    if ! snipe_postcondition_holds "$email"; then
        OUTCOME["$email"]=snipeit-failed; SNIPE_RESULT["$email"]=failed-verification; ERROR_DETAIL["$email"]=snipeit-postcondition-failed; return 1
    fi
    OUTCOME["$email"]=offboarded; SNIPE_RESULT["$email"]=soft-deactivated; return 0
}
for email in "${EMAILS[@]}"; do process_user "$email" || FAILURES=$((FAILURES + 1)); done
write_artifacts apply "$(now)"
((FAILURES == 0)) || exit 2
printf 'MODE=apply\nPLAN_SHA256=%s\nREPORT=%s\nMACHINE_REPORT=%s\nMANIFEST=%s\n' "$PLAN_HASH" "$REPORT" "$MACHINE_REPORT" "$MANIFEST"
