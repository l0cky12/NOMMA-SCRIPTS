<#
.SYNOPSIS
    Export Intune Configuration Profiles and Compliance Policies for review.

.DESCRIPTION
    Connects to Microsoft Graph, exports all device configuration policies
    (with full settings) and compliance policies to JSON files on the desktop.
    Uses the Graph REST API directly via Invoke-MgGraphRequest — no beta
    cmdlets required. Designed for K-12 IT admins to share policy exports
    for review/planning.

.PARAMETER ExportPath
    Directory to export files to. Defaults to the user's Desktop.

.PARAMETER Clipboard
    Switch to copy the configuration profiles export to clipboard after completion.

.PARAMETER ClientId
    Custom Azure AD app Client ID for authentication. If omitted, uses the
    Microsoft Graph PowerShell default app ID.

.PARAMETER DisableWAM
    Switch to disable WAM (Web Account Manager) login. Recommended for most
    environments.

.EXAMPLE
    .\Export-IntunePolicies.ps1 -DisableWAM

    Exports to Desktop, disables WAM login.

.EXAMPLE
    .\Export-IntunePolicies.ps1 -DisableWAM -Clipboard

    Exports to Desktop and copies config profiles to clipboard.

.EXAMPLE
    .\Export-IntunePolicies.ps1 -DisableWAM -ClientId "12345678-1234-1234-1234-123456789abc"

    Uses a custom Azure AD app for authentication.

.NOTES
    Author: Liam Decareaux
    Repo:   https://github.com/l0cky12/NOMMA-SCRIPTS
    Requires: Microsoft.Graph.Authentication module (auto-installed)
    Graph API: /beta/deviceManagement/configurationPolicies
               /beta/deviceManagement/deviceCompliancePolicies
    Changelog:
      2026-07-23 - Rewrote to use Invoke-MgGraphRequest (REST API) instead of
                   beta cmdlets for broader compatibility
#>

[CmdletBinding()]
param (
    [Parameter()]
    [string]$ExportPath = "$env:USERPROFILE\Desktop",

    [Parameter()]
    [switch]$Clipboard,

    [Parameter()]
    [string]$ClientId,

    [Parameter()]
    [switch]$DisableWAM
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

function Invoke-GraphGet {
    <#
    .SYNOPSIS
        Calls Invoke-MgGraphRequest with pagination support.
        Graph API returns @odata.nextLink when there are more results.
        This function follows the chain until all pages are collected.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Uri
    )

    $allItems = @()
    $nextLink = $Uri

    do {
        Write-Host "    Fetching page ..." -ForegroundColor Gray
        $response = Invoke-MgGraphRequest -Uri $nextLink -Method GET -OutputType PSObject
        $pageItems = $response.value
        if ($pageItems) {
            $allItems += $pageItems
            Write-Host "    Got $($pageItems.Count) items (total: $($allItems.Count))" -ForegroundColor Gray
        }
        $nextLink = $response.'@odata.nextLink'
    } while ($nextLink)

    return $allItems
}

function Connect-ToGraph {
    Write-Host "[*] Connecting to Microsoft Graph ..." -ForegroundColor Cyan

    $scopes = @(
        "DeviceManagementConfiguration.Read.All",
        "DeviceManagementApps.Read.All",
        "DeviceManagementServiceConfig.Read.All"
    )

    Write-Host "    Scopes:" -ForegroundColor Gray
    $scopes | ForEach-Object { Write-Host "      • $_" -ForegroundColor Gray }

    $connectParams = @{
        Scopes      = $scopes
        ErrorAction = "Stop"
    }

    if ($ClientId) {
        $connectParams.ClientId = $ClientId
        Write-Host "    Using custom ClientId: $ClientId" -ForegroundColor Gray
    }

    if ($DisableWAM) {
        Write-Host "    Disabling WAM login ..." -ForegroundColor Gray
        $connectParams.DisableLoginByWAM = $true
    }

    try {
        Connect-MgGraph @connectParams
        Write-Host "[✓] Connected to Microsoft Graph." -ForegroundColor Green
        Write-Host ""
        Write-Host "    Authenticated user:" -ForegroundColor Gray
        Get-MgContext | Select-Object Account, ClientId, AuthType | Format-List
    } catch {
        Write-Host "[✗] Authentication failed: $_" -ForegroundColor Red
        Write-Host ""
        Write-Host "    Troubleshooting:" -ForegroundColor Yellow
        Write-Host "      1. If you see 'WAM' errors, re-run with: -DisableWAM" -ForegroundColor Gray
        Write-Host "      2. If you need a custom app, use: -ClientId YOUR_APP_ID" -ForegroundColor Gray
        Write-Host "      3. Make sure you have Global Admin or Intune Admin rights" -ForegroundColor Gray
        exit 1
    }
}

function Export-ConfigProfiles {
    param([string]$OutputPath)

    Write-Host "[*] Fetching device configuration policies (Graph API) ..." -ForegroundColor Cyan

    try {
        $profiles = Invoke-GraphGet -Uri "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies"
    } catch {
        Write-Host "[✗] Failed to fetch configuration policies: $_" -ForegroundColor Red
        return $null
    }

    if (-not $profiles -or $profiles.Count -eq 0) {
        Write-Host "[!] No configuration policies found." -ForegroundColor Yellow
        return $null
    }

    Write-Host "[✓] Found $($profiles.Count) configuration profile(s)." -ForegroundColor Green

    $results = @()

    foreach ($p in $profiles) {
        Write-Host "    Processing: $($p.name) ..." -ForegroundColor Gray
        try {
            $settingsUri = "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies/$($p.id)/settings"
            $settings = Invoke-MgGraphRequest -Uri $settingsUri -Method GET -OutputType PSObject
            $settingsJson = $settings | ConvertTo-Json -Depth 10
        } catch {
            Write-Host "    [⚠] Could not fetch settings for $($p.name): $_" -ForegroundColor Yellow
            $settingsJson = "[]"
        }

        $results += [PSCustomObject]@{
            Id                  = $p.id
            Name                = $p.name
            Description         = $p.description
            Technologies        = $p.technologies -join "; "
            CreatedDateTime     = $p.createdDateTime
            LastModifiedDateTime = $p.lastModifiedDateTime
            Settings            = $settingsJson
        }
    }

    $jsonPath = Join-Path $OutputPath "intune-policies-export.json"
    $results | ConvertTo-Json -Depth 10 | Out-File $jsonPath -Encoding utf8
    Write-Host "[✓] Configuration profiles exported → $jsonPath" -ForegroundColor Green

    return $jsonPath
}

function Export-CompliancePolicies {
    param([string]$OutputPath)

    Write-Host "[*] Fetching device compliance policies (Graph API) ..." -ForegroundColor Cyan

    try {
        $policies = Invoke-GraphGet -Uri "https://graph.microsoft.com/beta/deviceManagement/deviceCompliancePolicies"
    } catch {
        Write-Host "[✗] Failed to fetch compliance policies: $_" -ForegroundColor Red
        return $null
    }

    if (-not $policies -or $policies.Count -eq 0) {
        Write-Host "[!] No compliance policies found." -ForegroundColor Yellow
        return $null
    }

    Write-Host "[✓] Found $($policies.Count) compliance polic(ies)." -ForegroundColor Green

    $jsonPath = Join-Path $OutputPath "intune-compliance-export.json"
    $policies | ConvertTo-Json -Depth 10 | Out-File $jsonPath -Encoding utf8
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
        Write-Host "    Items: $(@(Get-Content $ConfigPath -Raw | ConvertFrom-Json).Count)" -ForegroundColor Gray
    }

    if ($CompliancePath -and (Test-Path $CompliancePath)) {
        $size = (Get-Item $CompliancePath).Length / 1KB
        Write-Host "  Compliance Policies:" -ForegroundColor White
        Write-Host "    Path : $CompliancePath" -ForegroundColor Gray
        Write-Host "    Size : $([math]::Round($size, 1)) KB" -ForegroundColor Gray
        Write-Host "    Items: $(@(Get-Content $CompliancePath -Raw | ConvertFrom-Json).Count)" -ForegroundColor Gray
    }

    Write-Host ""
    Write-Host "  Next steps:" -ForegroundColor Yellow
    Write-Host "    1. Copy the config profiles JSON and paste into your Matrix chat" -ForegroundColor Gray
    Write-Host "    2. Use: .\Export-IntunePolicies.ps1 -DisableWAM -Clipboard" -ForegroundColor Gray
    Write-Host "    3. Then paste here (Ctrl+V)" -ForegroundColor Gray
    Write-Host ""
}

# ── Main ───────────────────────────────────────────────────────────────────────

Write-Banner

# Step 1 — Ensure export path exists
if (-not (Test-Path $ExportPath)) {
    New-Item -ItemType Directory -Path $ExportPath -Force | Out-Null
    Write-Host "[*] Created export directory: $ExportPath" -ForegroundColor Gray
}

# Step 2 — Install / verify Microsoft.Graph.Authentication module
Write-Host "[*] Checking required module ..." -ForegroundColor Cyan
Install-ModuleIfMissing -ModuleName "Microsoft.Graph.Authentication"
Write-Host ""

# Step 3 — Authenticate
Connect-ToGraph
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
        Write-Host "    Try: Get-Content '$configPath' | Set-Clipboard" -ForegroundColor Gray
    }
}

# Step 7 — Summary
Show-Summary -ConfigPath $configPath -CompliancePath $compliancePath

Write-Host "Done." -ForegroundColor Cyan