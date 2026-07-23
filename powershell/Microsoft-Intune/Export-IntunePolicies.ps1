<#
.SYNOPSIS
    Export Intune Configuration Profiles and Compliance Policies for review.

.DESCRIPTION
    Connects to Microsoft Graph, exports all device configuration policies
    (with full settings) and compliance policies to JSON files on the desktop.
    Designed for K-12 IT admins to share policy exports for review/planning.

.PARAMETER ExportPath
    Directory to export files to. Defaults to the user's Desktop.

.PARAMETER Clipboard
    Switch to copy the configuration profiles export to clipboard after completion.

.PARAMETER Scope
    Graph API scopes to request. Defaults to read-only device management scopes.

.EXAMPLE
    .\Export-IntunePolicies.ps1

    Exports to Desktop with default scopes.

.EXAMPLE
    .\Export-IntunePolicies.ps1 -ExportPath "C:\Exports" -Clipboard

    Exports to C:\Exports and copies config profiles to clipboard.

.NOTES
    Author: Liam Decareaux
    Repo:   https://github.com/l0cky12/NOMMA-SCRIPTS
    Requires: Microsoft.Graph module, Global Admin or Intune Admin rights
#>

[CmdletBinding()]
param (
    [Parameter()]
    [string]$ExportPath = "$env:USERPROFILE\Desktop",

    [Parameter()]
    [switch]$Clipboard
)

# ── Functions ──────────────────────────────────────────────────────────────────

function Write-Banner {
    Write-Host "╔══════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║        Intune Policy Exporter — NOMMA-SCRIPTS       ║" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
}

function Install-ModuleIfMissing {
    param([string]$ModuleName)
    if (-not (Get-Module -ListAvailable -Name $ModuleName)) {
        Write-Host "[*] Installing module: $ModuleName ..." -ForegroundColor Yellow
        Install-Module $ModuleName -Scope CurrentUser -Force -AllowClobber
    } else {
        Write-Host "[✓] Module $ModuleName is already installed." -ForegroundColor Green
    }
}

function Export-ConfigProfiles {
    param([string]$OutputPath)

    Write-Host "[*] Fetching device configuration policies ..." -ForegroundColor Cyan

    $profiles = Get-MgDeviceManagementConfigurationPolicy -ErrorAction Stop

    if (-not $profiles) {
        Write-Host "[!] No configuration policies found." -ForegroundColor Yellow
        return $null
    }

    Write-Host "[✓] Found $($profiles.Count) configuration profile(s)." -ForegroundColor Green

    $results = @()

    foreach ($p in $profiles) {
        Write-Host "    Processing: $($p.Name) ..." -ForegroundColor Gray
        try {
            $settings = Get-MgDeviceManagementConfigurationPolicySetting `
                -DeviceManagementConfigurationPolicyId $p.Id -ErrorAction Stop
        } catch {
            Write-Host "    [⚠] Could not fetch settings for $($p.Name): $_" -ForegroundColor Yellow
            $settings = $null
        }

        $results += [PSCustomObject]@{
            Id          = $p.Id
            Name        = $p.Name
            Description = $p.Description
            Technologies = $p.Technologies
            CreatedDateTime = $p.CreatedDateTime
            LastModifiedDateTime = $p.LastModifiedDateTime
            Settings    = if ($settings) { $settings | ConvertTo-Json -Depth 10 } else { "[]" }
        }
    }

    $jsonPath = Join-Path $OutputPath "intune-policies-export.json"
    $results | ConvertTo-Json -Depth 10 -Compress | Out-File $jsonPath -Encoding utf8
    Write-Host "[✓] Configuration profiles exported → $jsonPath" -ForegroundColor Green

    return $jsonPath
}

function Export-CompliancePolicies {
    param([string]$OutputPath)

    Write-Host "[*] Fetching device compliance policies ..." -ForegroundColor Cyan

    $policies = Get-MgDeviceManagementDeviceCompliancePolicy -ErrorAction Stop

    if (-not $policies) {
        Write-Host "[!] No compliance policies found." -ForegroundColor Yellow
        return $null
    }

    Write-Host "[✓] Found $($policies.Count) compliance polic(ies)." -ForegroundColor Green

    $jsonPath = Join-Path $OutputPath "intune-compliance-export.json"
    $policies | ConvertTo-Json -Depth 10 -Compress | Out-File $jsonPath -Encoding utf8
    Write-Host "[✓] Compliance policies exported → $jsonPath" -ForegroundColor Green

    return $jsonPath
}

function Show-Summary {
    param(
        [string]$ConfigPath,
        [string]$CompliancePath
    )
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║                     Export Summary                   ║" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""

    if ($ConfigPath -and (Test-Path $ConfigPath)) {
        $size = (Get-Item $ConfigPath).Length / 1KB
        Write-Host "  Configuration Profiles:" -ForegroundColor White
        Write-Host "    Path : $ConfigPath" -ForegroundColor Gray
        Write-Host "    Size : $([math]::Round($size, 1)) KB" -ForegroundColor Gray
    }

    if ($CompliancePath -and (Test-Path $CompliancePath)) {
        $size = (Get-Item $CompliancePath).Length / 1KB
        Write-Host "  Compliance Policies:" -ForegroundColor White
        Write-Host "    Path : $CompliancePath" -ForegroundColor Gray
        Write-Host "    Size : $([math]::Round($size, 1)) KB" -ForegroundColor Gray
    }

    Write-Host ""
    Write-Host "  Next steps:" -ForegroundColor Yellow
    Write-Host "    1. Open the JSON file(s) in VS Code or Notepad++" -ForegroundColor Gray
    Write-Host "    2. Copy the contents and paste into your Matrix chat" -ForegroundColor Gray
    Write-Host "    3. Use Set-Clipboard if you have the -Clipboard switch" -ForegroundColor Gray
    Write-Host ""
}

# ── Main ───────────────────────────────────────────────────────────────────────

Write-Banner

# Step 1 — Ensure export path exists
if (-not (Test-Path $ExportPath)) {
    New-Item -ItemType Directory -Path $ExportPath -Force | Out-Null
    Write-Host "[*] Created export directory: $ExportPath" -ForegroundColor Gray
}

# Step 2 — Install / verify Microsoft.Graph module
Install-ModuleIfMissing -ModuleName "Microsoft.Graph"

# Step 3 — Authenticate
Write-Host "[*] Connecting to Microsoft Graph ..." -ForegroundColor Cyan
Write-Host "    Scopes: DeviceManagementConfiguration.Read.All," -ForegroundColor Gray
Write-Host "            DeviceManagementApps.Read.All," -ForegroundColor Gray
Write-Host "            DeviceManagementServiceConfig.Read.All" -ForegroundColor Gray
Write-Host ""

try {
    Connect-MgGraph -Scopes @(
        "DeviceManagementConfiguration.Read.All",
        "DeviceManagementApps.Read.All",
        "DeviceManagementServiceConfig.Read.All"
    ) -ErrorAction Stop
    Write-Host "[✓] Connected to Microsoft Graph." -ForegroundColor Green
} catch {
    Write-Host "[✗] Authentication failed: $_" -ForegroundColor Red
    exit 1
}

Write-Host ""

# Step 4 — Export configuration profiles
$configPath = Export-ConfigProfiles -OutputPath $ExportPath

Write-Host ""

# Step 5 — Export compliance policies
$compliancePath = Export-CompliancePolicies -OutputPath $ExportPath

# Step 6 — Clipboard (optional)
if ($Clipboard -and $configPath -and (Test-Path $configPath)) {
    try {
        Get-Content $configPath -Raw | Set-Clipboard
        Write-Host "[✓] Configuration profiles copied to clipboard." -ForegroundColor Green
    } catch {
        Write-Host "[⚠] Could not copy to clipboard: $_" -ForegroundColor Yellow
        Write-Host "    Try running: Get-Content '$configPath' | Set-Clipboard" -ForegroundColor Gray
    }
}

# Step 7 — Summary
Show-Summary -ConfigPath $configPath -CompliancePath $compliancePath

Write-Host "Done." -ForegroundColor Cyan