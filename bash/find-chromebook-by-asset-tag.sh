#!/usr/bin/env bash
set -euo pipefail

# Find a ChromeOS device in Google Admin by NOMMA asset tag using GAM.
#
# Requirements:
#   - GAM/GAMADV-XTD3 installed and authenticated as a Google Workspace admin
#   - Permission to read ChromeOS devices in Google Admin
#   - python3 available for safe CSV parsing
#
# Usage:
#   ./find-chromebook-by-asset-tag.sh
#   ./find-chromebook-by-asset-tag.sh 12345
#
# Optional environment override:
#   GAM=/path/to/gam ./find-chromebook-by-asset-tag.sh 12345

GAM_BIN="${GAM:-gam}"
ASSET_TAG="${1:-}"

if ! command -v "$GAM_BIN" >/dev/null 2>&1; then
    echo "ERROR: GAM is not installed or not in PATH." >&2
    echo "Install/configure GAM, or run with GAM=/path/to/gam." >&2
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 is required for CSV parsing." >&2
    exit 1
fi

if [[ -z "$ASSET_TAG" ]]; then
    read -r -p "Enter asset tag: " ASSET_TAG
fi

if [[ -z "$ASSET_TAG" ]]; then
    echo "ERROR: Asset tag cannot be empty." >&2
    exit 1
fi

TMP_CSV="$(mktemp)"
trap 'rm -f "$TMP_CSV"' EXIT

echo "Searching Google Admin ChromeOS devices for asset tag: $ASSET_TAG" >&2

# ChromeOS asset tag is stored as annotatedAssetId in Google Admin.
# GAM query field is normally asset_id:<value>.
if ! "$GAM_BIN" print cros \
    query "asset_id:${ASSET_TAG}" \
    fields serialNumber,annotatedAssetId,model,orgUnitPath,lastSync,status \
    > "$TMP_CSV"; then
    echo "ERROR: GAM query failed." >&2
    exit 1
fi

python3 - "$TMP_CSV" "$ASSET_TAG" <<'PY'
import csv
import sys

csv_path = sys.argv[1]
asset_tag = sys.argv[2]

with open(csv_path, newline="", encoding="utf-8-sig") as handle:
    rows = list(csv.DictReader(handle))

if not rows:
    print(f"No ChromeOS device found with asset tag: {asset_tag}")
    sys.exit(1)

# Prefer exact annotatedAssetId matches if the query returns broader results.
exact_matches = [
    row for row in rows
    if row.get("annotatedAssetId", "").strip().lower() == asset_tag.lower()
]

matches = exact_matches or rows

for index, row in enumerate(matches, start=1):
    if len(matches) > 1:
        print(f"Result #{index}")

    print(f"Asset Tag:     {row.get('annotatedAssetId', '').strip() or 'N/A'}")
    print(f"Serial Number: {row.get('serialNumber', '').strip() or 'N/A'}")
    print(f"Model Number:  {row.get('model', '').strip() or 'N/A'}")
    print(f"Status:        {row.get('status', '').strip() or 'N/A'}")
    print(f"Org Unit:      {row.get('orgUnitPath', '').strip() or 'N/A'}")
    print(f"Last Sync:     {row.get('lastSync', '').strip() or 'N/A'}")

    if index != len(matches):
        print("-" * 40)
PY
