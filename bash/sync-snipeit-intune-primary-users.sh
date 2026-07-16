#!/usr/bin/env bash
# shellcheck disable=SC2016 # jq programs and literal $ref must not be shell-expanded.
set -euo pipefail

# Synchronize Snipe-IT hardware assignments to Intune managed-device primary users.
# Dry-run is the default. No Graph mutation occurs without --apply.

readonly DEFAULT_GROUP_ID="627b0785-7658-4f80-a3ff-c362a723cd4a"
readonly GRAPH_ROOT="https://graph.microsoft.com/v1.0"
readonly LOGIN_ROOT="https://login.microsoftonline.com"

APPLY=false
ASSUME_YES=false
USER_FILTER=""
LIMIT=""
REPORT_PATH=""
GRAPH_TOKEN=""
HTTP_BODY=""
HTTP_STATUS=""
ISSUE_COUNT=0
CHANGE_COUNT=0
UNCHANGED_COUNT=0
PROCESSED_USERS=0

CURL_BIN="${CURL_BIN:-curl}"
JQ_BIN="${JQ_BIN:-jq}"
MAX_RETRIES="${HTTP_MAX_RETRIES:-4}"
RETRY_DELAY="${HTTP_RETRY_DELAY:-2}"

usage() {
    cat <<'EOF'
Usage:
  sync-snipeit-intune-primary-users.sh [options]

Options:
  --apply          Make Intune primary-user changes. Default is dry-run.
  --user EMAIL     Process only the matching Entra group user.
  --limit NUMBER   Process only the first NUMBER selected users.
  --yes            Skip confirmation for a bulk --apply run.
  --report PATH    Write the CSV audit report to PATH.
  -h, --help       Show this help.

Required environment variables:
  ENTRA_TENANT_ID
  ENTRA_CLIENT_ID
  ENTRA_CLIENT_SECRET
  SNIPEIT_API_TOKEN

Optional environment variables:
  ENTRA_GROUP_ID       Default: 627b0785-7658-4f80-a3ff-c362a723cd4a
  SNIPEIT_URL          Default: https://10.1.2.81
  SNIPEIT_CA_BUNDLE    CA certificate bundle for the internal Snipe-IT TLS cert
  SNIPEIT_INSECURE     Set to true only for a temporary self-signed-cert test
  HTTP_MAX_RETRIES     Default: 4
  HTTP_RETRY_DELAY     Base delay in seconds; default: 2
EOF
}

log() {
    printf '%s\n' "$*" >&2
}

fatal() {
    log "ERROR: $*"
    exit 1
}

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

urlencode() {
    "$JQ_BIN" -nr --arg value "$1" '$value | @uri'
}

require_positive_integer() {
    local name="$1"
    local value="$2"
    [[ "$value" =~ ^[1-9][0-9]*$ ]] || fatal "$name must be a positive integer."
}

while (($# > 0)); do
    case "$1" in
        --apply)
            APPLY=true
            shift
            ;;
        --yes)
            ASSUME_YES=true
            shift
            ;;
        --user)
            (($# >= 2)) || fatal "--user requires an email address."
            USER_FILTER="$2"
            shift 2
            ;;
        --limit)
            (($# >= 2)) || fatal "--limit requires a number."
            LIMIT="$2"
            require_positive_integer "--limit" "$LIMIT"
            shift 2
            ;;
        --report)
            (($# >= 2)) || fatal "--report requires a path."
            REPORT_PATH="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fatal "Unknown option: $1"
            ;;
    esac
done

if [[ "$ASSUME_YES" == true && "$APPLY" != true ]]; then
    fatal "--yes is only valid with --apply."
fi

for command in "$CURL_BIN" "$JQ_BIN"; do
    command -v "$command" >/dev/null 2>&1 || fatal "Required command not found: $command"
done

required_vars=(ENTRA_TENANT_ID ENTRA_CLIENT_ID ENTRA_CLIENT_SECRET SNIPEIT_API_TOKEN)
missing_vars=()
for variable in "${required_vars[@]}"; do
    [[ -n "${!variable:-}" ]] || missing_vars+=("$variable")
done
if ((${#missing_vars[@]} > 0)); then
    fatal "Missing required environment variable(s): ${missing_vars[*]}"
fi

ENTRA_GROUP_ID="${ENTRA_GROUP_ID:-$DEFAULT_GROUP_ID}"
SNIPEIT_URL="${SNIPEIT_URL:-https://10.1.2.81}"
SNIPEIT_URL="${SNIPEIT_URL%/}"
SNIPEIT_INSECURE="${SNIPEIT_INSECURE:-false}"

[[ "$ENTRA_TENANT_ID" =~ ^[0-9a-fA-F-]{36}$ ]] || fatal "ENTRA_TENANT_ID must be a tenant GUID."
[[ "$ENTRA_CLIENT_ID" =~ ^[0-9a-fA-F-]{36}$ ]] || fatal "ENTRA_CLIENT_ID must be an application/client GUID."
[[ "$ENTRA_GROUP_ID" =~ ^[0-9a-fA-F-]{36}$ ]] || fatal "ENTRA_GROUP_ID must be a group GUID."
[[ "$SNIPEIT_URL" == https://* ]] || fatal "SNIPEIT_URL must use HTTPS."
[[ "$SNIPEIT_INSECURE" == true || "$SNIPEIT_INSECURE" == false ]] || fatal "SNIPEIT_INSECURE must be true or false."
require_positive_integer "HTTP_MAX_RETRIES" "$MAX_RETRIES"
require_positive_integer "HTTP_RETRY_DELAY" "$RETRY_DELAY"

if [[ -n "${SNIPEIT_CA_BUNDLE:-}" && ! -r "$SNIPEIT_CA_BUNDLE" ]]; then
    fatal "SNIPEIT_CA_BUNDLE is not readable: $SNIPEIT_CA_BUNDLE"
fi
if [[ "$SNIPEIT_INSECURE" == true ]]; then
    log "WARNING: SNIPEIT_INSECURE=true disables TLS certificate verification."
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/snipe-intune-sync.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

if [[ -z "$REPORT_PATH" ]]; then
    mkdir -p "$(dirname "$0")/reports"
    REPORT_PATH="$(dirname "$0")/reports/snipe-intune-primary-user-$(date -u +%Y%m%dT%H%M%SZ).csv"
else
    mkdir -p "$(dirname "$REPORT_PATH")"
fi

printf '%s\n' 'timestamp,user_email,asset_tag,serial_number,intune_device_id,intune_device_name,previous_primary_user,proposed_primary_user,action,error_details' >"$REPORT_PATH"

audit() {
    local user_email="$1"
    local asset_tag="$2"
    local serial="$3"
    local device_id="$4"
    local device_name="$5"
    local previous_user="$6"
    local proposed_user="$7"
    local action="$8"
    local details="$9"

    "$JQ_BIN" -nr \
        --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg user_email "$user_email" \
        --arg asset_tag "$asset_tag" \
        --arg serial "$serial" \
        --arg device_id "$device_id" \
        --arg device_name "$device_name" \
        --arg previous_user "$previous_user" \
        --arg proposed_user "$proposed_user" \
        --arg action "$action" \
        --arg details "$details" \
        '[$timestamp,$user_email,$asset_tag,$serial,$device_id,$device_name,$previous_user,$proposed_user,$action,$details] | @csv' \
        >>"$REPORT_PATH"
}

# http_request METHOD URL BODY CONTENT_TYPE AUTH_KIND
# Sets HTTP_BODY and HTTP_STATUS. AUTH_KIND is graph, snipe, or none.
http_request() {
    local method="$1"
    local url="$2"
    local body="${3:-}"
    local content_type="${4:-application/json}"
    local auth_kind="${5:-none}"
    local attempt=1
    local response_file="$TMP_DIR/http-body"
    local header_file="$TMP_DIR/http-headers"
    local curl_rc=0
    local retry_after=""
    local delay=""

    while ((attempt <= MAX_RETRIES)); do
        : >"$response_file"
        : >"$header_file"
        local -a args=(
            --silent --show-error
            --connect-timeout 15 --max-time 120
            -X "$method"
            -H "Accept: application/json"
            -H "Content-Type: $content_type"
            -D "$header_file"
            -o "$response_file"
            -w '%{http_code}'
        )

        case "$auth_kind" in
            graph)
                args+=(-H "Authorization: Bearer $GRAPH_TOKEN")
                ;;
            snipe)
                args+=(-H "Authorization: Bearer $SNIPEIT_API_TOKEN")
                if [[ -n "${SNIPEIT_CA_BUNDLE:-}" ]]; then
                    args+=(--cacert "$SNIPEIT_CA_BUNDLE")
                elif [[ "$SNIPEIT_INSECURE" == true ]]; then
                    args+=(--insecure)
                fi
                ;;
            none) ;;
            *) fatal "Internal error: unknown auth kind '$auth_kind'." ;;
        esac

        [[ -z "$body" ]] || args+=(--data "$body")
        args+=("$url")

        curl_rc=0
        HTTP_STATUS="$("$CURL_BIN" "${args[@]}")" || curl_rc=$?
        HTTP_BODY="$(<"$response_file")"

        if ((curl_rc == 0)) && [[ "$HTTP_STATUS" =~ ^2[0-9][0-9]$ ]]; then
            return 0
        fi

        if ((attempt >= MAX_RETRIES)); then
            break
        fi

        if ((curl_rc != 0)) || [[ "$HTTP_STATUS" == 429 || "$HTTP_STATUS" =~ ^5[0-9][0-9]$ ]]; then
            retry_after="$(tr -d '\r' <"$header_file" | awk 'BEGIN{IGNORECASE=1} /^Retry-After:/ {print $2; exit}')"
            if [[ "$retry_after" =~ ^[0-9]+$ ]]; then
                delay="$retry_after"
            else
                delay=$((RETRY_DELAY * attempt))
            fi
            log "Transient HTTP failure (status=${HTTP_STATUS:-none}, curl=$curl_rc); retrying in ${delay}s."
            sleep "$delay"
            ((++attempt))
            continue
        fi
        break
    done

    local safe_body
    safe_body="$(printf '%s' "$HTTP_BODY" | tr '\r\n' ' ' | cut -c1-500)"
    log "HTTP request failed: method=$method status=${HTTP_STATUS:-none} url=$url response=$safe_body"
    return 1
}

get_graph_token() {
    local tenant client secret form
    tenant="$(urlencode "$ENTRA_TENANT_ID")"
    client="$(urlencode "$ENTRA_CLIENT_ID")"
    secret="$(urlencode "$ENTRA_CLIENT_SECRET")"
    form="client_id=${client}&client_secret=${secret}&scope=https%3A%2F%2Fgraph.microsoft.com%2F.default&grant_type=client_credentials"

    http_request POST "$LOGIN_ROOT/$tenant/oauth2/v2.0/token" "$form" "application/x-www-form-urlencoded" none \
        || fatal "Could not obtain a Microsoft Graph access token."
    GRAPH_TOKEN="$(printf '%s' "$HTTP_BODY" | "$JQ_BIN" -er '.access_token // empty')" \
        || fatal "Token response did not include access_token."
}

fetch_graph_collection() {
    local url="$1"
    local destination="$2"
    local next_url="$url"
    : >"$destination"

    while [[ -n "$next_url" ]]; do
        http_request GET "$next_url" "" "application/json" graph \
            || return 1
        printf '%s' "$HTTP_BODY" | "$JQ_BIN" -e '.value | arrays' >/dev/null \
            || {
                log "Graph response did not contain a value array: $next_url"
                return 1
            }
        printf '%s' "$HTTP_BODY" | "$JQ_BIN" -c '.value[]' >>"$destination"
        next_url="$(printf '%s' "$HTTP_BODY" | "$JQ_BIN" -r '."@odata.nextLink" // empty')"
    done
}

get_snipe_user() {
    local email="$1"
    local encoded_email
    encoded_email="$(urlencode "$email")"

    http_request GET "$SNIPEIT_URL/api/v1/users?email=$encoded_email&limit=50&offset=0" "" "application/json" snipe \
        || return 1
    printf '%s' "$HTTP_BODY" | "$JQ_BIN" -e '.rows | arrays' >/dev/null || return 1

    printf '%s' "$HTTP_BODY" | "$JQ_BIN" -c --arg email "$email" \
        '.rows[] | select((.email // "" | ascii_downcase) == ($email | ascii_downcase))'
}

get_snipe_user_assets() {
    local user_id="$1"
    local limit=100
    local offset=0
    local total=0
    local row_count=0
    local assigned_type='App%5CModels%5CUser'

    while true; do
        http_request GET "$SNIPEIT_URL/api/v1/hardware?assigned_to=$user_id&assigned_type=$assigned_type&limit=$limit&offset=$offset" "" "application/json" snipe \
            || return 1
        printf '%s' "$HTTP_BODY" | "$JQ_BIN" -e '.rows | arrays' >/dev/null || return 1
        printf '%s' "$HTTP_BODY" | "$JQ_BIN" -c '.rows[]'

        row_count="$(printf '%s' "$HTTP_BODY" | "$JQ_BIN" -r '.rows | length')"
        total="$(printf '%s' "$HTTP_BODY" | "$JQ_BIN" -r '.total // (.rows | length)')"
        ((row_count > 0)) || break
        offset=$((offset + row_count))
        ((offset < total)) || break
    done
}

get_primary_users() {
    local device_id="$1"
    local destination="$2"
    fetch_graph_collection "$GRAPH_ROOT/deviceManagement/managedDevices/$device_id/users?%24select=id,userPrincipalName" "$destination"
}

set_primary_user() {
    local device_id="$1"
    local user_id="$2"
    local body
    body="$("$JQ_BIN" -nc --arg url "$GRAPH_ROOT/users/$user_id" '{"@odata.id":$url}')"
    http_request POST "$GRAPH_ROOT/deviceManagement/managedDevices/$device_id/users/\$ref" "$body" "application/json" graph
}

confirm_bulk_apply() {
    local selected_count="$1"
    if [[ "$APPLY" != true || "$ASSUME_YES" == true || "$selected_count" -le 1 ]]; then
        return 0
    fi

    if [[ ! -t 0 ]]; then
        fatal "Bulk --apply selected $selected_count users. Re-run interactively or add --yes after reviewing a dry run."
    fi

    printf 'BULK CHANGE: process %s users and update matching Intune devices? Type APPLY to continue: ' "$selected_count" >&2
    local answer
    read -r answer
    [[ "$answer" == APPLY ]] || fatal "Bulk apply cancelled."
}

get_graph_token
log "Using transitive Entra group membership (nested-group users are included)."

GROUP_USERS_FILE="$TMP_DIR/group-users.jsonl"
SELECTED_USERS_FILE="$TMP_DIR/selected-users.jsonl"
INTUNE_DEVICES_FILE="$TMP_DIR/intune-devices.jsonl"

fetch_graph_collection \
    "$GRAPH_ROOT/groups/$ENTRA_GROUP_ID/transitiveMembers/microsoft.graph.user?%24select=id,mail,userPrincipalName,displayName&%24top=999" \
    "$GROUP_USERS_FILE" \
    || fatal "Could not retrieve transitive Entra group users."

: >"$SELECTED_USERS_FILE"
selected=0
while IFS= read -r user_json; do
    [[ -n "$user_json" ]] || continue
    email="$(printf '%s' "$user_json" | "$JQ_BIN" -r 'if (.mail // "") != "" then .mail else (.userPrincipalName // "") end')"
    [[ -n "$email" ]] || {
        audit "" "" "" "" "" "" "" "skipped-user-no-email" "Entra user has neither mail nor userPrincipalName."
        ((++ISSUE_COUNT))
        continue
    }
    if [[ -n "$USER_FILTER" && "${email,,}" != "${USER_FILTER,,}" ]]; then
        continue
    fi
    printf '%s\n' "$user_json" >>"$SELECTED_USERS_FILE"
    ((++selected))
    if [[ -n "$LIMIT" && "$selected" -ge "$LIMIT" ]]; then
        break
    fi
done <"$GROUP_USERS_FILE"

if [[ -n "$USER_FILTER" && "$selected" -eq 0 ]]; then
    fatal "No transitive member of group $ENTRA_GROUP_ID matched --user $USER_FILTER."
fi
if ((selected == 0)); then
    fatal "No Entra users were selected."
fi

confirm_bulk_apply "$selected"

fetch_graph_collection \
    "$GRAPH_ROOT/deviceManagement/managedDevices?%24select=id,deviceName,serialNumber,operatingSystem,azureADDeviceId,deviceEnrollmentType&%24top=999" \
    "$INTUNE_DEVICES_FILE" \
    || fatal "Could not retrieve Intune managed devices."

mode="DRY RUN"
[[ "$APPLY" == true ]] && mode="APPLY"
log "Mode: $mode | selected users: $selected | report: $REPORT_PATH"

while IFS= read -r user_json; do
    [[ -n "$user_json" ]] || continue
    ((++PROCESSED_USERS))
    entra_user_id="$(printf '%s' "$user_json" | "$JQ_BIN" -r '.id')"
    user_email="$(printf '%s' "$user_json" | "$JQ_BIN" -r 'if (.mail // "") != "" then .mail else .userPrincipalName end')"
    proposed_user="$user_email ($entra_user_id)"

    snipe_users_file="$TMP_DIR/snipe-users-$entra_user_id.jsonl"
    if ! get_snipe_user "$user_email" >"$snipe_users_file"; then
        audit "$user_email" "" "" "" "" "" "$proposed_user" "error-snipe-user-read" "Could not query Snipe-IT users by exact email."
        ((++ISSUE_COUNT))
        continue
    fi
    mapfile -t snipe_users <"$snipe_users_file"
    if ((${#snipe_users[@]} == 0)); then
        audit "$user_email" "" "" "" "" "" "$proposed_user" "skipped-snipe-user-not-found" "No exact Snipe-IT email match."
        ((++ISSUE_COUNT))
        continue
    fi
    if ((${#snipe_users[@]} > 1)); then
        audit "$user_email" "" "" "" "" "" "$proposed_user" "blocked-duplicate-snipe-users" "Multiple exact Snipe-IT email matches."
        ((++ISSUE_COUNT))
        continue
    fi

    snipe_user_id="$(printf '%s' "${snipe_users[0]}" | "$JQ_BIN" -r '.id')"
    assets_file="$TMP_DIR/assets-$snipe_user_id.jsonl"
    if ! get_snipe_user_assets "$snipe_user_id" >"$assets_file"; then
        audit "$user_email" "" "" "" "" "" "$proposed_user" "error-snipe-assets" "Could not retrieve Snipe-IT assets for user ID $snipe_user_id."
        ((++ISSUE_COUNT))
        continue
    fi

    if [[ ! -s "$assets_file" ]]; then
        audit "$user_email" "" "" "" "" "" "$proposed_user" "unchanged-no-assigned-hardware" "No hardware is directly assigned to this Snipe-IT user."
        ((++UNCHANGED_COUNT))
        continue
    fi

    while IFS= read -r asset_json; do
        [[ -n "$asset_json" ]] || continue
        asset_tag="$(printf '%s' "$asset_json" | "$JQ_BIN" -r '.asset_tag // ""')"
        serial="$(trim "$(printf '%s' "$asset_json" | "$JQ_BIN" -r '.serial // .serial_number // ""')")"
        assigned_type="$(printf '%s' "$asset_json" | "$JQ_BIN" -r '.assigned_to.type // "user"')"
        assigned_id="$(printf '%s' "$asset_json" | "$JQ_BIN" -r '.assigned_to.id // empty')"

        if [[ "${assigned_type,,}" != user || ( -n "$assigned_id" && "$assigned_id" != "$snipe_user_id" ) ]]; then
            audit "$user_email" "$asset_tag" "$serial" "" "" "" "$proposed_user" "blocked-not-direct-user-assignment" "Asset response was not assigned directly to the expected Snipe-IT user."
            ((++ISSUE_COUNT))
            continue
        fi
        if [[ -z "$serial" ]]; then
            audit "$user_email" "$asset_tag" "" "" "" "" "$proposed_user" "skipped-missing-serial" "Snipe-IT asset has no serial number."
            ((++ISSUE_COUNT))
            continue
        fi

        mapfile -t device_matches < <("$JQ_BIN" -c --arg serial "$serial" \
            'select(((.serialNumber // "") | gsub("^[[:space:]]+|[[:space:]]+$"; "") | ascii_downcase) == ($serial | ascii_downcase))' \
            "$INTUNE_DEVICES_FILE")

        if ((${#device_matches[@]} == 0)); then
            audit "$user_email" "$asset_tag" "$serial" "" "" "" "$proposed_user" "skipped-intune-device-not-found" "No exact Intune serial-number match."
            ((++ISSUE_COUNT))
            continue
        fi
        if ((${#device_matches[@]} > 1)); then
            audit "$user_email" "$asset_tag" "$serial" "" "" "" "$proposed_user" "blocked-duplicate-intune-serial" "Multiple Intune managed devices have this exact serial number."
            ((++ISSUE_COUNT))
            continue
        fi

        device_json="${device_matches[0]}"
        device_id="$(printf '%s' "$device_json" | "$JQ_BIN" -r '.id')"
        device_name="$(printf '%s' "$device_json" | "$JQ_BIN" -r '.deviceName // ""')"
        operating_system="$(printf '%s' "$device_json" | "$JQ_BIN" -r '.operatingSystem // ""')"
        entra_device_id="$(printf '%s' "$device_json" | "$JQ_BIN" -r '.azureADDeviceId // ""')"

        if [[ "${operating_system,,}" != windows ]]; then
            audit "$user_email" "$asset_tag" "$serial" "$device_id" "$device_name" "" "$proposed_user" "skipped-unsupported-platform" "Matched Intune device is not Windows."
            ((++ISSUE_COUNT))
            continue
        fi
        if [[ -z "$entra_device_id" || "$entra_device_id" == "00000000-0000-0000-0000-000000000000" ]]; then
            audit "$user_email" "$asset_tag" "$serial" "$device_id" "$device_name" "" "$proposed_user" "skipped-unsupported-registration" "Windows device has no Entra device ID; primary-user assignment is not attempted."
            ((++ISSUE_COUNT))
            continue
        fi

        primary_file="$TMP_DIR/primary-$device_id.jsonl"
        if ! get_primary_users "$device_id" "$primary_file"; then
            audit "$user_email" "$asset_tag" "$serial" "$device_id" "$device_name" "" "$proposed_user" "error-primary-user-read" "Could not read current Intune primary user."
            ((++ISSUE_COUNT))
            continue
        fi

        mapfile -t current_users <"$primary_file"
        previous_user=""
        if ((${#current_users[@]} > 0)); then
            previous_user="$(printf '%s\n' "${current_users[@]}" | "$JQ_BIN" -sr 'map((.userPrincipalName // "unknown") + " (" + .id + ")") | join("; ")')"
        fi

        target_present=false
        for current_user_json in "${current_users[@]}"; do
            current_id="$(printf '%s' "$current_user_json" | "$JQ_BIN" -r '.id')"
            if [[ "$current_id" == "$entra_user_id" ]]; then
                target_present=true
                break
            fi
        done

        if [[ "$target_present" == true ]]; then
            audit "$user_email" "$asset_tag" "$serial" "$device_id" "$device_name" "$previous_user" "$proposed_user" "unchanged-primary-user-correct" ""
            ((++UNCHANGED_COUNT))
            continue
        fi
        if ((${#current_users[@]} > 1)); then
            audit "$user_email" "$asset_tag" "$serial" "$device_id" "$device_name" "$previous_user" "$proposed_user" "blocked-multiple-current-primary-users" "Intune returned multiple existing primary users; no mutation attempted."
            ((++ISSUE_COUNT))
            continue
        fi

        if [[ "$APPLY" != true ]]; then
            audit "$user_email" "$asset_tag" "$serial" "$device_id" "$device_name" "$previous_user" "$proposed_user" "would-update-primary-user" "Dry run; no Graph mutation sent."
            ((++CHANGE_COUNT))
            continue
        fi

        if set_primary_user "$device_id" "$entra_user_id"; then
            audit "$user_email" "$asset_tag" "$serial" "$device_id" "$device_name" "$previous_user" "$proposed_user" "updated-primary-user" "Graph returned HTTP $HTTP_STATUS."
            ((++CHANGE_COUNT))
        else
            audit "$user_email" "$asset_tag" "$serial" "$device_id" "$device_name" "$previous_user" "$proposed_user" "error-primary-user-update" "Graph update failed with HTTP ${HTTP_STATUS:-unknown}."
            ((++ISSUE_COUNT))
        fi
    done <"$assets_file"
done <"$SELECTED_USERS_FILE"

log "Completed: users=$PROCESSED_USERS changes=$CHANGE_COUNT unchanged=$UNCHANGED_COUNT issues=$ISSUE_COUNT"
log "Audit report: $REPORT_PATH"

if ((ISSUE_COUNT > 0)); then
    exit 2
fi
exit 0
