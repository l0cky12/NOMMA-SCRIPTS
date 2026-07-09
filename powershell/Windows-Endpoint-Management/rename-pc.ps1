# rename-pc.ps1
# Renames a PC during Autopilot enrollment based on serial number and asset tag from CSV
# New name format: L5-SERIAL(7)-ASSETTAG(4)
#
# Usage:
#   .\rename-pc.ps1 -CsvPath "C:\ProgramData\Intune\rename-list.csv"
#
# CSV format:
#   SerialNumber,AssetTag
#   ABC1234567890,1001
#   DEF5678901234,1002

param(
    [string]$CsvPath = "C:\ProgramData\Intune\rename-list.csv",
    [string]$LogPath = "C:\ProgramData\Intune\rename-pc.log",
    [switch]$WhatIf
)

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] $Message"
    Write-Host $line
    $line | Out-File -FilePath $LogPath -Append -Encoding UTF8
}

# Check for admin rights
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Log "ERROR: This script must run as Administrator"
    exit 1
}

# Check CSV exists
if (-not (Test-Path $CsvPath)) {
    Write-Log "ERROR: CSV not found at $CsvPath"
    exit 1
}

# Get current device serial number
try {
    $serial = (Get-WmiObject Win32_BIOS).SerialNumber.Trim()
    if ([string]::IsNullOrWhiteSpace($serial)) {
        Write-Log "ERROR: Could not read serial number from BIOS"
        exit 1
    }
    Write-Log "Current serial number: $serial"
} catch {
    Write-Log "ERROR: Failed to read serial number: $_"
    exit 1
}

# Import CSV and find match
try {
    $csv = Import-Csv $CsvPath
    Write-Log "Loaded CSV with $($csv.Count) entries"
} catch {
    Write-Log "ERROR: Failed to import CSV: $_"
    exit 1
}

$match = $csv | Where-Object { $_.SerialNumber.Trim() -eq $serial }

if (-not $match) {
    Write-Log "No match found for serial: $serial — skipping rename"
    exit 0
}

# Build new name: L5-SERIAL(last 7)-ASSETTAG(last 4)
$assetTag = $match.AssetTag.Trim()
$shortSerial = if ($serial.Length -ge 7) { $serial.Substring($serial.Length - 7) } else { $serial }
$shortAsset = if ($assetTag.Length -ge 4) { $assetTag.Substring($assetTag.Length - 4) } else { $assetTag }
$newName = "L5-$shortSerial-$shortAsset"

# Validate name length (NetBIOS limit is 15 characters)
if ($newName.Length -gt 15) {
    Write-Log "WARNING: Name '$newName' is $($newName.Length) chars, truncating to 15"
    $newName = $newName.Substring(0, 15)
}

Write-Log "Match found: Serial=$serial, AssetTag=$assetTag"
Write-Log "New computer name: $newName"

# Check if already named correctly
$currentName = [System.Net.Dns]::GetHostName()
if ($currentName -eq $newName) {
    Write-Log "Computer is already named '$newName' — no action needed"
    exit 0
}

if ($WhatIf) {
    Write-Log "WHATIF: Would rename from '$currentName' to '$newName' and restart"
    exit 0
}

# Rename and restart
try {
    Write-Log "Renaming computer from '$currentName' to '$newName'..."
    Rename-Computer -NewName $newName -Force
    Write-Log "Rename successful. Restarting in 30 seconds..."
    shutdown /r /t 30 /c "Computer renamed to $newName by Autopilot script"
} catch {
    Write-Log "ERROR: Rename failed: $_"
    exit 1
}
