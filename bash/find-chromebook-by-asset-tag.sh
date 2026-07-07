#!/usr/bin/env bash
#
# find-chromebook-by-asset-tag.sh
#
# Interactively look up Google Admin ChromeOS devices by 4-digit asset tag
# using GAM (GAM7 / GAMADV-XTD3), confirm the match, and log results to CSV.
#
# Workflow (repeats until Ctrl+C):
#   1. Prompt for a 4-digit asset tag.
#   2. Search Google Admin ChromeOS devices (annotatedAssetId) via GAM.
#   3. Print asset tag, serial number, model, and device ID.
#   4. Press Enter to save tag + serial + model to the CSV log, or type
#      anything else to save the asset tag alone.
#
# Requirements:
#   - GAM / GAMADV-XTD3 installed and authenticated as a Workspace admin
#   - Admin permission to read ChromeOS devices ("Manage Devices and Settings"
#     or equivalent Chrome device read privilege)
#
# Configuration (override via environment, no edits required):
#   GAM=/path/to/gam           GAM executable       (default: gam)
#   OUTPUT_CSV=/path/to/file   CSV results log      (default: device_lookup_results.csv)

set -u -o pipefail
# Deliberately NOT using `set -e`: this is an interactive loop and individual
# failures (bad GAM query, no match, write error) are handled explicitly.

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
GAM_BIN="${GAM:-gam}"
OUTPUT_CSV="${OUTPUT_CSV:-device_lookup_results.csv}"
CSV_HEADER="AssetTag,SerialNumber,Model"

# Fields requested from GAM. deviceId is display-only; the CSV log keeps
# only asset tag, serial number, and model.
GAM_FIELDS="deviceId,serialNumber,model,annotatedAssetId"

# ---------------------------------------------------------------------------
# Housekeeping: temp files and clean exits
# ---------------------------------------------------------------------------
TMP_OUT="$(mktemp)" || { echo "ERROR: mktemp failed." >&2; exit 1; }
TMP_ERR="$(mktemp)" || { echo "ERROR: mktemp failed." >&2; exit 1; }

cleanup() { rm -f "$TMP_OUT" "$TMP_ERR"; }
trap cleanup EXIT
trap 'printf "\n\nInterrupted -- goodbye!\n"; exit 0' INT

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

# trim STRING -- print STRING without leading/trailing whitespace.
trim() {
    local s=$1
    s=${s#"${s%%[![:space:]]*}"}
    s=${s%"${s##*[![:space:]]}"}
    printf '%s' "$s"
}

# prompt_read PROMPT VARNAME -- print PROMPT, read one line into VARNAME.
# Exits cleanly if input ends (Ctrl+D) so the script never spins on EOF.
prompt_read() {
    local __prompt=$1 __var=$2 __line
    printf '%s' "$__prompt"
    if ! IFS= read -r __line; then
        printf '\nGoodbye!\n'
        exit 0
    fi
    printf -v "$__var" '%s' "$__line"
}

# parse_csv_line LINE -- split one CSV line into the global CSV_FIELDS array,
# honoring RFC 4180 quoting (embedded commas and doubled quotes). Pure Bash,
# so there is no dependency on gawk FPAT or python.
parse_csv_line() {
    local line=$1 field="" in_quotes=0 i char
    CSV_FIELDS=()
    for ((i = 0; i < ${#line}; i++)); do
        char=${line:i:1}
        if ((in_quotes)); then
            if [[ $char == '"' ]]; then
                if [[ ${line:i+1:1} == '"' ]]; then
                    field+='"'        # doubled quote -> literal quote
                    ((i++))
                else
                    in_quotes=0       # closing quote
                fi
            else
                field+=$char
            fi
        else
            case $char in
                '"') in_quotes=1 ;;
                ',') CSV_FIELDS+=("$field"); field="" ;;
                *)   field+=$char ;;
            esac
        fi
    done
    CSV_FIELDS+=("$field")
}

# csv_escape VALUE -- print VALUE quoted/escaped per RFC 4180 when needed.
csv_escape() {
    local value=$1
    if [[ $value == *','* || $value == *'"'* || $value == *$'\n'* ]]; then
        value=${value//\"/\"\"}
        printf '"%s"' "$value"
    else
        printf '%s' "$value"
    fi
}

# find_column NAME -- print the index of NAME in HEADER_FIELDS (case
# insensitive) so we never depend on GAM's column order. Fails if absent.
find_column() {
    local name=$1 i
    for i in "${!HEADER_FIELDS[@]}"; do
        if [[ ${HEADER_FIELDS[i],,} == "${name,,}" ]]; then
            printf '%s' "$i"
            return 0
        fi
    done
    return 1
}

# ---------------------------------------------------------------------------
# CSV results log
# ---------------------------------------------------------------------------

# row_exists TAG SERIAL -- return 0 if OUTPUT_CSV already contains a row with
# this AssetTag + SerialNumber pair. Pass SERIAL="" to check for an existing
# asset-tag-only row.
row_exists() {
    local tag=$1 serial=$2 line first=1
    [[ -f "$OUTPUT_CSV" ]] || return 1
    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%$'\r'}
        if ((first)); then first=0; continue; fi   # skip header row
        [[ -n $line ]] || continue
        parse_csv_line "$line"
        if [[ ${CSV_FIELDS[0]:-} == "$tag" && ${CSV_FIELDS[1]:-} == "$serial" ]]; then
            return 0
        fi
    done < "$OUTPUT_CSV"
    return 1
}

# append_row TAG SERIAL MODEL -- append one escaped row, writing the header
# first if the file is missing or empty.
append_row() {
    local tag=$1 serial=$2 model=$3
    if [[ ! -s "$OUTPUT_CSV" ]]; then
        printf '%s\n' "$CSV_HEADER" > "$OUTPUT_CSV" || return 1
    fi
    printf '%s,%s,%s\n' \
        "$(csv_escape "$tag")" \
        "$(csv_escape "$serial")" \
        "$(csv_escape "$model")" >> "$OUTPUT_CSV"
}

# save_row TAG SERIAL MODEL -- append with duplicate protection: an existing
# row with the same AssetTag + SerialNumber (including tag-only rows) needs
# explicit confirmation before a duplicate is written.
save_row() {
    local tag=$1 serial=$2 model=$3 answer
    if row_exists "$tag" "$serial"; then
        if [[ -n $serial ]]; then
            echo "A row for asset tag ${tag} / serial ${serial} already exists in ${OUTPUT_CSV}."
        else
            echo "An asset-tag-only row for ${tag} already exists in ${OUTPUT_CSV}."
        fi
        prompt_read 'Save a duplicate row anyway? [y/N]: ' answer
        if [[ ! $answer =~ ^[Yy] ]]; then
            echo "Skipped -- nothing saved."
            return 0
        fi
    fi
    if append_row "$tag" "$serial" "$model"; then
        if [[ -n $serial ]]; then
            echo "Saved: ${tag},${serial},${model} -> ${OUTPUT_CSV}"
        else
            echo "Saved asset tag only: ${tag} -> ${OUTPUT_CSV}"
        fi
    else
        echo "ERROR: could not write to ${OUTPUT_CSV}." >&2
    fi
}

# ---------------------------------------------------------------------------
# GAM lookup
# ---------------------------------------------------------------------------

# search_devices TAG -- query Google Admin and fill the DEV_* arrays with
# every device whose annotatedAssetId exactly matches TAG. Query hits whose
# tag merely starts with TAG (Google prefix matching, e.g. "12345") are
# collected in NEAR_TAGS so they can be reported without being auto-selected.
search_devices() {
    local tag=$1 line first=1
    local col_tag col_serial col_model col_id row_tag
    DEV_TAG=(); DEV_SERIAL=(); DEV_MODEL=(); DEV_ID=(); NEAR_TAGS=()

    # asset_id: searches the annotatedAssetId field. `gam print` emits CSV
    # with a header row, which parses far more reliably than `gam info`.
    if ! "$GAM_BIN" print cros query "asset_id:${tag}" fields "$GAM_FIELDS" \
            > "$TMP_OUT" 2> "$TMP_ERR"; then
        echo "ERROR: GAM query failed:" >&2
        cat "$TMP_ERR" >&2
        return 1
    fi

    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%$'\r'}
        [[ -n $line ]] || continue
        if ((first)); then
            first=0
            line=${line#$'\xef\xbb\xbf'}          # strip UTF-8 BOM if present
            parse_csv_line "$line"
            HEADER_FIELDS=("${CSV_FIELDS[@]}")
            if ! col_id=$(find_column deviceId) ||
               ! col_serial=$(find_column serialNumber) ||
               ! col_model=$(find_column model) ||
               ! col_tag=$(find_column annotatedAssetId); then
                echo "ERROR: unexpected GAM output format (missing expected columns)." >&2
                return 1
            fi
            continue
        fi
        parse_csv_line "$line"
        row_tag=$(trim "${CSV_FIELDS[col_tag]:-}")
        if [[ $row_tag == "$tag" ]]; then
            DEV_TAG+=("$row_tag")
            DEV_SERIAL+=("$(trim "${CSV_FIELDS[col_serial]:-}")")
            DEV_MODEL+=("$(trim "${CSV_FIELDS[col_model]:-}")")
            DEV_ID+=("$(trim "${CSV_FIELDS[col_id]:-}")")
        else
            NEAR_TAGS+=("$row_tag")
        fi
    done < "$TMP_OUT"
    return 0
}

# display_device INDEX -- pretty-print one matched device from the DEV_* arrays.
display_device() {
    local i=$1
    echo
    echo "Device found:"
    echo "----------------------------------------------"
    printf '  Asset Tag     : %s\n' "${DEV_TAG[i]:-N/A}"
    printf '  Serial Number : %s\n' "${DEV_SERIAL[i]:-N/A}"
    printf '  Model         : %s\n' "${DEV_MODEL[i]:-N/A}"
    printf '  Device ID     : %s\n' "${DEV_ID[i]:-N/A}"
    echo "----------------------------------------------"
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
main() {
    if ! command -v "$GAM_BIN" >/dev/null 2>&1; then
        echo "ERROR: GAM ('${GAM_BIN}') is not installed or not in PATH." >&2
        echo "Install GAM, or point at it with: GAM=/path/to/gam $0" >&2
        exit 1
    fi

    echo "ChromeOS device lookup by asset tag (GAM: ${GAM_BIN})"
    echo "Results log: ${OUTPUT_CSV}"
    echo "Press Ctrl+C at any time to quit."
    echo

    local asset_tag reply index choice serial model _pause

    while true; do
        prompt_read 'Enter 4-digit asset tag: ' asset_tag
        asset_tag=$(trim "$asset_tag")

        if [[ ! $asset_tag =~ ^[0-9]{4}$ ]]; then
            echo "Invalid input: the asset tag must be exactly 4 digits (e.g. 0042)."
            echo
            continue
        fi

        echo "Searching Google Admin for asset tag ${asset_tag}..."
        if ! search_devices "$asset_tag"; then
            echo
            continue
        fi

        if ((${#DEV_SERIAL[@]} == 0)); then
            echo "No device found with asset tag: ${asset_tag}"
            if ((${#NEAR_TAGS[@]} > 0)); then
                # Google's query does prefix matching; mention non-exact hits
                # so a mistyped or padded tag is easy to spot.
                echo "(GAM returned similar tags, none exact: ${NEAR_TAGS[*]:0:5})"
            fi
            echo
            continue
        fi

        # More than one device with the same tag is unusual but possible in
        # Google Admin -- let the admin pick which one is being logged.
        index=0
        if ((${#DEV_SERIAL[@]} > 1)); then
            echo "Multiple devices share asset tag ${asset_tag}:"
            for index in "${!DEV_SERIAL[@]}"; do
                printf '  %d) serial %s -- %s\n' "$((index + 1))" \
                    "${DEV_SERIAL[index]:-N/A}" "${DEV_MODEL[index]:-N/A}"
            done
            while true; do
                prompt_read "Select a device [1-${#DEV_SERIAL[@]}]: " choice
                if [[ $choice =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#DEV_SERIAL[@]})); then
                    index=$((choice - 1))
                    break
                fi
                echo "Please enter a number between 1 and ${#DEV_SERIAL[@]}."
            done
        fi

        display_device "$index"

        prompt_read 'Is this the correct device? Press Enter to save asset tag, serial number, and model. Type anything else to save only the asset tag: ' reply
        if [[ -z $reply ]]; then
            serial=${DEV_SERIAL[index]}
            model=${DEV_MODEL[index]}
        else
            serial=""
            model=""
        fi

        save_row "$asset_tag" "$serial" "$model"

        prompt_read 'Press Enter to search again (Ctrl+C to quit): ' _pause
        echo
    done
}

main "$@"
