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

Interactive loop that uses GAM to look up Google Admin ChromeOS devices by
4-digit asset tag, prints the serial number / model / device ID, and logs
confirmed results to a CSV file (`device_lookup_results.csv` by default).

For each lookup, press Enter at the confirmation prompt to save the asset
tag, serial number, and model — or type anything else to save only the asset
tag. Duplicate rows require explicit confirmation. Quit with `Ctrl+C`.

Requirements:

- GAM/GAMADV-XTD3 installed and authenticated as a Google Workspace admin
- Permission to read ChromeOS devices in Google Admin

Run it:

```bash
./find-chromebook-by-asset-tag.sh
```

If GAM is installed somewhere custom, or you want a different CSV file:

```bash
GAM=/path/to/gam OUTPUT_CSV=/path/to/results.csv ./find-chromebook-by-asset-tag.sh
```
