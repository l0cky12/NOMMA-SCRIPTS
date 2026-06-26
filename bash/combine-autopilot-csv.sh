#!/usr/bin/env bash
set -euo pipefail

# Combines Windows Autopilot CSV files into one clean Intune-ready CSV.
#
# Usage:
#   ./combine-autopilot-csv.sh
#   ./combine-autopilot-csv.sh INPUT_FOLDER OUTPUT_FILE
#   ./combine-autopilot-csv.sh INPUT_FOLDER OUTPUT_FILE "Group Tag"
#
# Examples:
#   ./combine-autopilot-csv.sh
#   ./combine-autopilot-csv.sh . combined-autopilot.csv
#   ./combine-autopilot-csv.sh . combined-autopilot.csv "School Administrator Devices"

INPUT_DIR="${1:-.}"
OUTPUT_FILE="${2:-combined-autopilot.csv}"
GROUP_TAG="${3:-}"

if [[ ! -d "$INPUT_DIR" ]]; then
    echo "ERROR: Input folder does not exist: $INPUT_DIR"
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 is required but not installed."
    exit 1
fi

python3 - "$INPUT_DIR" "$OUTPUT_FILE" "$GROUP_TAG" <<'PY'
import csv
import os
import re
import sys
from pathlib import Path

input_dir = Path(sys.argv[1])
output_file = Path(sys.argv[2])
group_tag = sys.argv[3]

header_3 = ["Device Serial Number", "Windows Product ID", "Hardware Hash"]
header_4 = ["Device Serial Number", "Windows Product ID", "Hardware Hash", "Group Tag"]

hash_re = re.compile(r"^[A-Za-z0-9+/=]+$")

csv_files = sorted([
    p for p in input_dir.glob("*.csv")
    if p.resolve() != output_file.resolve()
])

if not csv_files:
    print(f"ERROR: No CSV files found in: {input_dir}")
    sys.exit(1)

def decode_file(path: Path) -> str:
    data = path.read_bytes()

    encodings = [
        "utf-8-sig",
        "utf-16",
        "utf-16-le",
        "utf-16-be",
        "cp1252",
        "latin-1",
    ]

    best_text = None

    for enc in encodings:
        try:
            text = data.decode(enc)
            if "Device Serial Number" in text or "Hardware Hash" in text:
                return text
            if best_text is None:
                best_text = text
        except UnicodeDecodeError:
            continue

    return data.decode("utf-8", errors="replace")

def clean_cell(value: str) -> str:
    if value is None:
        return ""

    return (
        value
        .replace("\ufeff", "")
        .replace("\ufffd", "")
        .replace("\x00", "")
        .replace("\r", "")
        .replace("\n", "")
        .strip()
    )

devices = {}
bad_rows = []

for file in csv_files:
    text = decode_file(file)

    # Remove nulls and replacement characters caused by bad encoding.
    text = text.replace("\x00", "")
    text = text.replace("\ufffd", "")

    lines = []
    for raw_line in text.splitlines():
        line = raw_line.strip()
        line = line.replace("\ufeff", "").replace("\ufffd", "").replace("\x00", "")

        if not line:
            continue

        # Skip repeated Autopilot headers.
        if "Device Serial Number" in line and "Hardware Hash" in line:
            continue

        lines.append(line)

    reader = csv.reader(lines)

    for row_number, row in enumerate(reader, start=1):
        row = [clean_cell(x) for x in row]

        if not row:
            continue

        serial = ""
        hardware_hash = ""

        # Correct format:
        # Serial,,HardwareHash
        if len(row) >= 3:
            serial = row[0]
            hardware_hash = row[2]

        # Repair bad format:
        # Serial,HardwareHash
        elif len(row) == 2:
            serial = row[0]
            hardware_hash = row[1]

        serial = clean_cell(serial)
        hardware_hash = clean_cell(hardware_hash)

        # Force Windows Product ID to blank.
        # This avoids the Intune "Duplicate productId" error.
        product_id = ""

        if not serial or not hardware_hash:
            bad_rows.append((file.name, row_number, "Missing serial or hardware hash", row))
            continue

        # Autopilot hardware hashes are long base64-like strings.
        if len(hardware_hash) < 1000 or not hash_re.match(hardware_hash):
            bad_rows.append((file.name, row_number, "Bad hardware hash format", row))
            continue

        # Deduplicate by serial number.
        if serial not in devices:
            devices[serial] = {
                "serial": serial,
                "product_id": product_id,
                "hardware_hash": hardware_hash,
            }

with output_file.open("w", newline="", encoding="utf-8") as f:
    writer = csv.writer(f, lineterminator="\n", quoting=csv.QUOTE_MINIMAL)

    if group_tag:
        writer.writerow(header_4)
        for device in devices.values():
            writer.writerow([
                device["serial"],
                "",
                device["hardware_hash"],
                group_tag,
            ])
    else:
        writer.writerow(header_3)
        for device in devices.values():
            writer.writerow([
                device["serial"],
                "",
                device["hardware_hash"],
            ])

bad_file = output_file.with_name("bad-autopilot-rows.txt")
with bad_file.open("w", encoding="utf-8") as f:
    for item in bad_rows:
        f.write(str(item) + "\n")

print("Done.")
print(f"Created: {output_file}")
print(f"Device count: {len(devices)}")
print(f"Skipped bad rows: {len(bad_rows)}")
print(f"Bad row log: {bad_file}")

if len(devices) == 0:
    print("ERROR: No valid Autopilot devices were found.")
    sys.exit(1)
PY
