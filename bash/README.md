# Bash Scripts

NOMMA IT helper scripts.

## combine-autopilot-csv.sh

Combines Windows Autopilot CSV files into one clean Intune-ready CSV.

```bash
./combine-autopilot-csv.sh
./combine-autopilot-csv.sh INPUT_FOLDER OUTPUT_FILE
./combine-autopilot-csv.sh INPUT_FOLDER OUTPUT_FILE "Group Tag"
```

## find-chromebook-by-asset-tag.sh

Uses GAM to search Google Admin ChromeOS devices by asset tag and print the laptop serial number and model number.

Requirements:

- GAM/GAMADV-XTD3 installed and authenticated as a Google Workspace admin
- Permission to read ChromeOS devices in Google Admin
- `python3` available for CSV parsing

Interactive use:

```bash
./find-chromebook-by-asset-tag.sh
```

Pass an asset tag directly:

```bash
./find-chromebook-by-asset-tag.sh 12345
```

If GAM is installed somewhere custom:

```bash
GAM=/path/to/gam ./find-chromebook-by-asset-tag.sh 12345
```
