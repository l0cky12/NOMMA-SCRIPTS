#!/usr/bin/env bash
# shellcheck disable=SC2086,SC2317
set -euo pipefail

# =============================================================================
# sync_google_users_to_snipeit.sh
#
# One-way sync: Google Workspace users → Snipe-IT user accounts.
#
# Reads all users from the configured Google Workspace OU (default: /Cadets
# and all sub-OUs), extracts Employee ID and grade-level department, and
# creates/updates corresponding Snipe-IT users with random passwords and
# login disabled.
#
# Dry-run is the default. No Snipe-IT writes happen without --apply.
# =============================================================================

readonly VERSION="1.0.0"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ── Defaults ────────────────────────────────────────────────────────────────
APPLY=false
VALIDATE=false
LIMIT=""
DRY_RUN=true
LOG_FILE=""
GOOGLE_TOKEN=""
GOOGLE_TOKEN_EXPIRY=0
USER_CREATED=0
USER_UPDATED=0
USER_UNCHANGED=0
USER_SKIPPED=0
USER_ERRORS=0
DEPARTMENTS_CREATED=0

# ── Tool paths (override via env) ───────────────────────────────────────────
CURL_BIN="${CURL_BIN:-curl}"
JQ_BIN="${JQ_BIN:-jq}"
OPENSSL_BIN="${OPENSSL_BIN:-openssl}"

# ── Helpers ─────────────────────────────────────────────────────────────────
usage() {
    cat <<'EOF'
Usage:
  sync_google_users_to_snipeit.sh [options]

Options:
  --apply           Apply changes to Snipe-IT (default: dry-run)
  --validate-config Check config without calling APIs, then exit
  --limit N         Process only the first N users
  -h, --help        Show this help

Required env vars:
  GOOGLE_SERVICE_ACCOUNT_FILE   Path to Google service account JSON key
  GOOGLE_DELEGATED_ADMIN        Admin email for domain-wide delegation
  GOOGLE_CUSTOMER_ID            Google Workspace customer ID (or "my_customer")
  SNIPEIT_URL                   Snipe-IT base URL (e.g. https://inv.nomma.tech)
  SNIPEIT_API_TOKEN             Snipe-IT API bearer token

Optional env vars:
  GOOGLE_OU                     OU to sync (default: /Cadets)
  GOOGLE_DOMAIN                 Domain filter (default: nomma.net)
  GRADE_DEPT_MAPPING            Path to grade→department mapping JSON
  SNIPEIT_VERIFY_TLS            true/false (default: true)
  SNIPEIT_CA_BUNDLE             Custom CA cert bundle path
  LOG_FILE                      Log output path (default: stderr only)
  LOG_LEVEL                     0=quiet, 1=normal, 2=verbose (default: 1)
EOF
}

log() {
    local level="${1:-INFO}"
    shift
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] $*"
    if [ "$LOG_FILE" ]; then
        printf '%s\n' "$msg" >> "$LOG_FILE"
    fi
    if [ "${LOG_LEVEL:-1}" -ge 1 ] || [ "$level" = "ERROR" ]; then
        printf '%s\n' "$msg" >&2
    fi
}

die() {
    log "FATAL" "$*"
    exit 1
}

b64url() {
    # Base64url encode (no padding, URL-safe chars)
    printf '%s' "$1" | base64 -w0 | tr '+/' '-_' | tr -d '='
}

# ── Config loading ──────────────────────────────────────────────────────────
load_config() {
    # Load .env from script directory if present
    local env_file="${ENV_FILE:-$SCRIPT_DIR/.env}"
    if [ -f "$env_file" ]; then
        set -a
        # shellcheck disable=SC1090
        source "$env_file"
        set +a
    fi

    local missing=()
    [ -z "${GOOGLE_SERVICE_ACCOUNT_FILE:-}" ] && missing+=("GOOGLE_SERVICE_ACCOUNT_FILE")
    [ -z "${GOOGLE_DELEGATED_ADMIN:-}" ] && missing+=("GOOGLE_DELEGATED_ADMIN")
    [ -z "${GOOGLE_CUSTOMER_ID:-}" ] && missing+=("GOOGLE_CUSTOMER_ID")
    [ -z "${SNIPEIT_URL:-}" ] && missing+=("SNIPEIT_URL")
    [ -z "${SNIPEIT_API_TOKEN:-}" ] && missing+=("SNIPEIT_API_TOKEN")

    if [ ${#missing[@]} -gt 0 ]; then
        die "Missing required config: ${missing[*]}"
    fi

    # Defaults
    GOOGLE_OU="${GOOGLE_OU:-/Cadets}"
    GOOGLE_DOMAIN="${GOOGLE_DOMAIN:-nomma.net}"
    SNIPEIT_VERIFY_TLS="${SNIPEIT_VERIFY_TLS:-true}"
    LOG_LEVEL="${LOG_LEVEL:-1}"
    GRADE_DEPT_MAPPING="${GRADE_DEPT_MAPPING:-$SCRIPT_DIR/config/grade-department-mapping.json}"

    # Validate file paths
    [ ! -f "$GOOGLE_SERVICE_ACCOUNT_FILE" ] && die "Service account key not found: $GOOGLE_SERVICE_ACCOUNT_FILE"
    [ ! -f "$GRADE_DEPT_MAPPING" ] && die "Grade→department mapping not found: $GRADE_DEPT_MAPPING"

    local verify_tls
    if [ "${SNIPEIT_VERIFY_TLS,,}" = "false" ]; then
        verify_tls="-k"
    else
        verify_tls=""
    fi
    CURL_TLS_ARGS="${SNIPEIT_CA_BUNDLE:+--cacert $SNIPEIT_CA_BUNDLE} $verify_tls"

    SNIPEIT_URL="${SNIPEIT_URL%/}"

    log "INFO" "Configuration loaded"
    log "INFO" "  Google OU: $GOOGLE_OU"
    log "INFO" "  Google Domain: $GOOGLE_DOMAIN"
    log "INFO" "  Snipe-IT URL: $SNIPEIT_URL"
    log "INFO" "  Grade mapping: $GRADE_DEPT_MAPPING"
    [ "$APPLY" = true ] && log "INFO" "  Mode: LIVE (--apply enabled)" || log "INFO" "  Mode: DRY-RUN"
}

validate_config() {
    load_config

    # Check tools
    local missing_tools=()
    for tool in "$CURL_BIN" "$JQ_BIN" "$OPENSSL_BIN"; do
        command -v "$tool" >/dev/null 2>&1 || missing_tools+=("$tool")
    done
    if [ ${#missing_tools[@]} -gt 0 ]; then
        log "ERROR" "Missing required tools: ${missing_tools[*]}"
        return 1
    fi

    # Verify service account JSON is parseable
    if ! jq -e '.client_email, .private_key' "$GOOGLE_SERVICE_ACCOUNT_FILE" >/dev/null 2>&1; then
        log "ERROR" "Service account JSON missing required fields (client_email, private_key)"
        return 1
    fi

    # Verify grade mapping is valid
    if ! jq -e '. | objects' "$GRADE_DEPT_MAPPING" >/dev/null 2>&1; then
        log "ERROR" "Grade→department mapping is not a valid JSON object"
        return 1
    fi

    # Verify Snipe-IT URL format
    if ! printf '%s' "$SNIPEIT_URL" | grep -qE '^https?://'; then
        log "ERROR" "SNIPEIT_URL must start with http:// or https://"
        return 1
    fi

    log "INFO" "Configuration valid"
    return 0
}

# ── Google OAuth2 Token (service account JWT) ───────────────────────────────
google_get_token() {
    # Returns access token via stdout, caches in GOOGLE_TOKEN var
    local now
    now=$(date +%s)

    # Use cached token if still valid (5 min buffer)
    if [ -n "$GOOGLE_TOKEN" ] && [ "$now" -lt $((GOOGLE_TOKEN_EXPIRY - 300)) ]; then
        printf '%s' "$GOOGLE_TOKEN"
        return 0
    fi

    log "INFO" "Obtaining Google OAuth2 token..."

    local client_email delegated_admin scope now_epoch exp_epoch
    client_email=$(jq -r '.client_email' "$GOOGLE_SERVICE_ACCOUNT_FILE")
    now_epoch=$now
    exp_epoch=$((now_epoch + 3600))
    scope="https://www.googleapis.com/auth/admin.directory.user.readonly"

    # Build JWT claim set
    local jwt_header jwt_payload signature_input b64_header b64_payload signature jwt
    jwt_header='{"alg":"RS256","typ":"JWT"}'
    jwt_payload=$(cat <<JWTEOF
{"iss":"${client_email}","sub":"${GOOGLE_DELEGATED_ADMIN}","scope":"${scope}","aud":"https://oauth2.googleapis.com/token","iat":${now_epoch},"exp":${exp_epoch}}
JWTEOF
)

    b64_header=$(b64url "$jwt_header")
    b64_payload=$(b64url "$jwt_payload")
    signature_input="${b64_header}.${b64_payload}"

    # Sign with the service account's RSA private key
    signature=$(printf '%s' "$signature_input" \
        | $OPENSSL_BIN dgst -sha256 -sign <($JQ_BIN -r '.private_key' "$GOOGLE_SERVICE_ACCOUNT_FILE") \
        | base64 -w0 | tr '+/' '-_' | tr -d '=')

    jwt="${signature_input}.${signature}"

    # Exchange JWT for access token
    local token_response
    token_response=$($CURL_BIN -s -X POST "https://oauth2.googleapis.com/token" \
        -d "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=${jwt}")

    GOOGLE_TOKEN=$(printf '%s' "$token_response" | $JQ_BIN -r '.access_token // empty')
    local expires_in
    expires_in=$(printf '%s' "$token_response" | $JQ_BIN -r '.expires_in // 0')

    if [ -z "$GOOGLE_TOKEN" ]; then
        local error_desc
        error_desc=$(printf '%s' "$token_response" | $JQ_BIN -r '.error_description // "unknown"')
        die "Google token exchange failed: ${error_desc}"
    fi

    GOOGLE_TOKEN_EXPIRY=$((now + expires_in))
    log "INFO" "Google OAuth2 token obtained, expires in ${expires_in}s"
    printf '%s' "$GOOGLE_TOKEN"
}

# ── Google Directory API ─────────────────────────────────────────────────────
google_fetch_users() {
    local token
    token=$(google_get_token)
    local page_token=""
    local all_users="[]"

    log "INFO" "Fetching Google Workspace users from OU: ${GOOGLE_OU} (including sub-OUs)..."

    while : ; do
        local url="https://admin.googleapis.com/admin/directory/v1/users"
        url="${url}?domain=${GOOGLE_DOMAIN}&orgUnitPath=${GOOGLE_OU}&projection=full&maxResults=200"
        [ -n "$page_token" ] && url="${url}&pageToken=${page_token}"

        local response
        response=$($CURL_BIN -s -H "Authorization: Bearer ${token}" "$url")

        local users
        users=$(printf '%s' "$response" | $JQ_BIN -c '.users // []')
        all_users=$(printf '%s\n%s' "$all_users" "$users" | $JQ_BIN -s 'add')

        page_token=$(printf '%s' "$response" | $JQ_BIN -r '.nextPageToken // empty')
        [ -z "$page_token" ] && break

        log "INFO" "  Paginating (next page token)..."
    done

    local count
    count=$(printf '%s' "$all_users" | $JQ_BIN 'length')
    log "INFO" "  Found ${count} users in ${GOOGLE_OU} and sub-OUs"

    printf '%s' "$all_users"
}

google_extract_employee_id() {
    # Extract Employee ID from user JSON. Tries:
    # 1. externalIds where type = 'organization' → value
    # 2. customSchemas → any field that looks like employee id
    # Returns empty string if not found
    local user_json="$1"
    local eid

    eid=$(printf '%s' "$user_json" | $JQ_BIN -r '
        (.externalIds // [])[] | select(.type == "organization") | .value // empty
    ' 2>/dev/null || printf '')

    printf '%s' "$eid"
}

google_extract_grade() {
    # Extract grade level from the orgUnitPath.
    # OU path: /Cadets → root (no specific grade)
    # OU path: /Cadets/8th Grade → "8th Grade"
    # OU path: /Cadets/9th Grade → "9th Grade"
    local ou_path="$1"

    if [ "$ou_path" = "$GOOGLE_OU" ] || [ "$ou_path" = "${GOOGLE_OU}/" ]; then
        printf ''
        return 0
    fi

    # Remove the base OU prefix to get the sub-path
    local sub_path="${ou_path#"${GOOGLE_OU}/"}"
    # If there are deeper sub-OUs, take only the immediate child
    local grade
    grade=$(printf '%s' "$sub_path" | cut -d'/' -f1)
    printf '%s' "$grade"
}

# ── Snipe-IT API ────────────────────────────────────────────────────────────
snipeit_api() {
    local method="$1"
    local endpoint="$2"
    local data="${3:-}"
    local url="${SNIPEIT_URL}/api/v1${endpoint}"

    local response status_code http_code body
    if [ -n "$data" ]; then
        response=$($CURL_BIN -s -X "$method" $CURL_TLS_ARGS \
            -H "Authorization: Bearer ${SNIPEIT_API_TOKEN}" \
            -H "Accept: application/json" \
            -H "Content-Type: application/json" \
            -d "$data" \
            -w "\n%{http_code}" \
            "$url")
    else
        response=$($CURL_BIN -s -X "$method" $CURL_TLS_ARGS \
            -H "Authorization: Bearer ${SNIPEIT_API_TOKEN}" \
            -H "Accept: application/json" \
            -w "\n%{http_code}" \
            "$url")
    fi

    http_code=$(printf '%s' "$response" | tail -1)
    body=$(printf '%s' "$response" | sed '$d')

    if [ "$http_code" -ge 400 ]; then
        log "ERROR" "Snipe-IT ${method} ${endpoint}: HTTP ${http_code}: $(printf '%s' "$body" | $JQ_BIN -r '.messages // .error // .' | head -c 200)"
        return 1
    fi

    printf '%s' "$body"
}

snipeit_find_user() {
    local email="$1"
    local response
    response=$(snipeit_api "GET" "/users?search=$(printf '%s' "$email" | $JQ_BIN -sRr @uri)&limit=10") || return 1

    local user_id user_email
    user_id=$(printf '%s' "$response" | $JQ_BIN -r \
        --arg email "$email" \
        '.rows[] | select(.email == $email or .username == $email) | .id // empty' | head -1)

    [ -n "$user_id" ] && printf '%s' "$user_id" || printf ''
}

snipeit_find_or_create_department() {
    local dept_name="$1"
    local response dept_id

    # Search for existing department
    response=$(snipeit_api "GET" "/departments?search=$(printf '%s' "$dept_name" | $JQ_BIN -sRr @uri)&limit=10") || return 1
    dept_id=$(printf '%s' "$response" | $JQ_BIN -r \
        --arg name "$dept_name" \
        '.rows[] | select(.name == $name) | .id' | head -1)

    if [ -n "$dept_id" ] && [ "$dept_id" != "null" ]; then
        printf '%s' "$dept_id"
        return 0
    fi

    # Department doesn't exist - create it (even in dry-run, departments are needed)
    if [ "$APPLY" != true ]; then
        # In dry-run, we simulate creation by checking what the ID would be
        log "DRY-RUN" "Would create department: ${dept_name}"
        printf '0'  # sentinel for dry-run
        return 0
    fi

    response=$(snipeit_api "POST" "/departments" \
        "{\"name\":\"${dept_name}\",\"notes\":\"Auto-created by Google→Snipe-IT user sync\"}") || return 1

    dept_id=$(printf '%s' "$response" | $JQ_BIN -r '.payload.id // .id // empty')
    if [ -z "$dept_id" ]; then
        log "ERROR" "Failed to create department: ${dept_name}"
        return 1
    fi

    DEPARTMENTS_CREATED=$((DEPARTMENTS_CREATED + 1))
    log "INFO" "  Created department: ${dept_name} (ID: ${dept_id})"
    printf '%s' "$dept_id"
}

snipeit_create_user() {
    local first_name="$1"
    local last_name="$2"
    local email="$3"
    local employee_num="$4"
    local dept_id="$5"
    local password
    password=$($OPENSSL_BIN rand -base64 24)

    local dept_json="null"
    [ -n "$dept_id" ] && [ "$dept_id" != "0" ] && dept_json="{\"id\":${dept_id}}"

    local payload
    payload=$(cat <<PAYLOADEOF
{
  "first_name": $(printf '%s' "$first_name" | $JQ_BIN -sRr @json),
  "last_name": $(printf '%s' "$last_name" | $JQ_BIN -sRr @json),
  "username": $(printf '%s' "$email" | $JQ_BIN -sRr @json),
  "email": $(printf '%s' "$email" | $JQ_BIN -sRr @json),
  "password": $(printf '%s' "$password" | $JQ_BIN -sRr @json),
  "activated": false,
  "employee_num": $(printf '%s' "$employee_num" | $JQ_BIN -sRr @json),
  "department_id": ${dept_id:-null}
}
PAYLOADEOF
)

    if [ "$APPLY" != true ]; then
        log "DRY-RUN" "Would create user: ${email} (${first_name} ${last_name}) [dept=${dept_id}, emp=${employee_num}]"
        return 0
    fi

    local response
    response=$(snipeit_api "POST" "/users" "$payload") || return 1

    local user_id
    user_id=$(printf '%s' "$response" | $JQ_BIN -r '.payload.id // .id // empty')
    if [ -z "$user_id" ]; then
        log "ERROR" "Failed to create user ${email}: $(printf '%s' "$response" | $JQ_BIN -r '.messages // .' | head -c 200)"
        return 1
    fi

    USER_CREATED=$((USER_CREATED + 1))
    log "INFO" "  Created user: ${email} (ID: ${user_id}) — login disabled"
}

snipeit_update_user() {
    local user_id="$1"
    local first_name="$2"
    local last_name="$3"
    local email="$4"
    local employee_num="$5"
    local dept_id="$6"

    local payload
    payload=$(cat <<PAYLOADEOF
{
  "first_name": $(printf '%s' "$first_name" | $JQ_BIN -sRr @json),
  "last_name": $(printf '%s' "$last_name" | $JQ_BIN -sRr @json),
  "employee_num": $(printf '%s' "$employee_num" | $JQ_BIN -sRr @json)
}
PAYLOADEOF
)

    if [ -n "$dept_id" ] && [ "$dept_id" != "0" ]; then
        payload=$(printf '%s' "$payload" | $JQ_BIN -c --argjson did "$dept_id" '. + {department_id: $did}')
    fi

    if [ "$APPLY" != true ]; then
        log "DRY-RUN" "Would update user: ${email} (ID: ${user_id}) [dept=${dept_id}, emp=${employee_num}]"
        return 0
    fi

    # Fetch existing user to compare
    local existing
    existing=$(snipeit_api "GET" "/users/${user_id}") || return 1

    local existing_emp existing_dept_id
    existing_emp=$(printf '%s' "$existing" | $JQ_BIN -r '.employee_num // ""')
    existing_dept_id=$(printf '%s' "$existing" | $JQ_BIN -r '.department.id // .department_id // "null"')
    [ "$existing_dept_id" = "null" ] && existing_dept_id=""

    # Only update if something changed
    if [ "$existing_emp" = "$employee_num" ] && [ "$existing_dept_id" = "${dept_id:-}" ]; then
        USER_UNCHANGED=$((USER_UNCHANGED + 1))
        return 0
    fi

    local response
    response=$(snipeit_api "PATCH" "/users/${user_id}" "$payload") || return 1

    USER_UPDATED=$((USER_UPDATED + 1))
    log "INFO" "  Updated user: ${email} (ID: ${user_id})"
}

# ── Grade → Department resolution ──────────────────────────────────────────
resolve_department() {
    local grade="$1"
    [ -z "$grade" ] && { printf ''; return 0; }

    local dept_name
    dept_name=$($JQ_BIN -r --arg grade "$grade" '.[$grade] // empty' "$GRADE_DEPT_MAPPING")
    printf '%s' "${dept_name:-$grade}"
}

# ── Main sync logic ─────────────────────────────────────────────────────────
sync_users() {
    load_config

    local grade_mapping_count
    grade_mapping_count=$($JQ_BIN 'length' "$GRADE_DEPT_MAPPING")
    log "INFO" "Grade→Department mappings loaded: ${grade_mapping_count} entries"

    # Fetch Google users
    local users
    users=$(google_fetch_users)
    local total_count
    total_count=$(printf '%s' "$users" | $JQ_BIN 'length')
    [ "$total_count" -eq 0 ] && { log "WARN" "No users found in OU ${GOOGLE_OU}"; return 0; }

    # Apply limit
    if [ -n "$LIMIT" ]; then
        users=$(printf '%s' "$users" | $JQ_BIN -c ".[:$LIMIT]")
        log "INFO" "  Limited to first ${LIMIT} users"
    fi

    log "INFO" "Starting sync of ${total_count} users..."
    printf '%s\n' ""

    # Process each user (process substitution keeps the loop in the current shell)
    while read -r user_json; do
        local email first_name last_name ou_path employee_num grade dept_name dept_id user_id
        local display_name

        email=$(printf '%s' "$user_json" | $JQ_BIN -r '.primaryEmail // empty')
        first_name=$(printf '%s' "$user_json" | $JQ_BIN -r '.name.givenName // ""')
        last_name=$(printf '%s' "$user_json" | $JQ_BIN -r '.name.familyName // ""')
        display_name=$(printf '%s' "$user_json" | $JQ_BIN -r '.name.fullName // ""')
        ou_path=$(printf '%s' "$user_json" | $JQ_BIN -r '.orgUnitPath // ""')

        # Skip if missing critical fields
        if [ -z "$email" ]; then
            log "WARN" "  Skipping user with no email: ${display_name}"
            USER_SKIPPED=$((USER_SKIPPED + 1))
            continue
        fi

        # Extract Employee ID
        employee_num=$(google_extract_employee_id "$user_json")

        # Extract grade from OU path
        grade=$(google_extract_grade "$ou_path")
        dept_name=$(resolve_department "$grade")

        if [ -z "$grade" ]; then
            log "INFO" "  ${email} — No grade (root OU: ${ou_path})"
        else
            log "INFO" "  ${email} — Grade: ${grade} → Dept: ${dept_name:-${grade}}"
        fi

        if [ -n "$employee_num" ]; then
            log "INFO" "    Employee ID: ${employee_num}"
        else
            log "INFO" "    Employee ID: (not set)"
        fi

        # Find existing Snipe-IT user
        user_id=$(snipeit_find_user "$email" || printf '')

        # Resolve department ID in Snipe-IT
        dept_id=""
        if [ -n "$dept_name" ]; then
            dept_id=$(snipeit_find_or_create_department "$dept_name") || {
                log "ERROR" "  Failed to resolve/create department for ${email}"
                USER_ERRORS=$((USER_ERRORS + 1))
                continue
            }
        fi

        if [ -n "$user_id" ]; then
            # Update existing user
            log "INFO" "    Snipe-IT user exists (ID: ${user_id})"
            if ! snipeit_update_user "$user_id" "$first_name" "$last_name" "$email" "$employee_num" "$dept_id"; then
                USER_ERRORS=$((USER_ERRORS + 1))
            fi
        else
            # Create new user
            if [ "$APPLY" = true ] || [ "${DRY_RUN}" = true ]; then
                if snipeit_create_user "$first_name" "$last_name" "$email" "$employee_num" "$dept_id"; then
                    :  # counter incremented inside snipeit_create_user
                else
                    USER_ERRORS=$((USER_ERRORS + 1))
                fi
            fi
        fi

        printf '%s\n' ""
    done < <(printf '%s' "$users" | $JQ_BIN -c '.[]')
}

# ── Reporting (after subshell) ──────────────────────────────────────────────
print_summary() {
    cat <<SUMMAIREOF

╔══════════════════════════════════════════════════════════╗
║                 Google → Snipe-IT User Sync             ║
╠══════════════════════════════════════════════════════════╣
SUMMAIREOF
    printf '║  %-50s ║\n' "Mode: $( [ "$APPLY" = true ] && printf 'LIVE (--apply)' || printf 'DRY-RUN' )"
    printf '║  %-50s ║\n' "Status: $( [ "$USER_ERRORS" -gt 0 ] && printf 'COMPLETED WITH ERRORS' || printf 'SUCCESS' )"
    printf '╠══════════════════════════════════════════════════════════╣\n'
    printf '║  %-50s ║\n' "Users created:   ${USER_CREATED}"
    printf '║  %-50s ║\n' "Users updated:   ${USER_UPDATED}"
    printf '║  %-50s ║\n' "Users unchanged: ${USER_UNCHANGED}"
    printf '║  %-50s ║\n' "Users skipped:   ${USER_SKIPPED}"
    printf '║  %-50s ║\n' "User errors:     ${USER_ERRORS}"
    printf '║  %-50s ║\n' "Depts created:   ${DEPARTMENTS_CREATED}"
    printf '╚══════════════════════════════════════════════════════════╝\n'
}

# ── Main ────────────────────────────────────────────────────────────────────
main() {
    # Parse arguments
    while [ $# -gt 0 ]; do
        case "$1" in
            --apply) APPLY=true; DRY_RUN=false; shift ;;
            --validate-config) VALIDATE=true; shift ;;
            --limit) LIMIT="$2"; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *) die "Unknown option: $1 (use --help)" ;;
        esac
    done

    if [ "$VALIDATE" = true ]; then
        validate_config && exit 0 || exit 1
    fi

    sync_users
    print_summary

    if [ "$USER_ERRORS" -gt 0 ]; then
        exit 1
    fi
}

main "$@"