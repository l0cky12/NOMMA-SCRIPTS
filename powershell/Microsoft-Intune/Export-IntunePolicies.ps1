#Requires -Version 7.0

<#
.SYNOPSIS
Exports major Microsoft Intune policy categories to JSON files,
including assignments, and creates a ZIP archive.

.NOTES
Uses Microsoft Graph beta because some Intune policy types are not
fully exposed through Microsoft Graph v1.0.
#>

$ErrorActionPreference = "Continue"

$TimeStamp  = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$ExportRoot = Join-Path $PWD "Intune-Policy-Export-$TimeStamp"
$ZipPath    = "$ExportRoot.zip"

New-Item -Path $ExportRoot -ItemType Directory -Force | Out-Null

Import-Module Microsoft.Graph.Authentication

Write-Host "Signing in to Microsoft Graph..." -ForegroundColor Cyan

$Scopes = @(
    "DeviceManagementConfiguration.Read.All",
    "DeviceManagementServiceConfig.Read.All",
    "DeviceManagementApps.Read.All",
    "DeviceManagementScripts.Read.All",
    "Group.Read.All"
)

Connect-MgGraph `
    -Scopes $Scopes `
    -UseDeviceCode `
    -ContextScope Process `
    -NoWelcome `
    -ErrorAction Stop

$Context = Get-MgContext

if (-not $Context) {
    throw "Microsoft Graph authentication failed."
}

Write-Host "Connected as $($Context.Account)" -ForegroundColor Green

function Get-SafeFileName {
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    $InvalidCharacters = [System.IO.Path]::GetInvalidFileNameChars()

    foreach ($Character in $InvalidCharacters) {
        $Name = $Name.Replace($Character, "_")
    }

    $Name = $Name.Trim()

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return "Unnamed-Policy"
    }

    return $Name
}

function Invoke-GraphCollection {
    param(
        [Parameter(Mandatory)]
        [string]$Uri
    )

    $Items   = @()
    $NextUri = $Uri

    while ($NextUri) {
        try {
            $Response = Invoke-MgGraphRequest `
                -Method GET `
                -Uri $NextUri `
                -OutputType PSObject

            if ($null -ne $Response.value) {
                $Items += @($Response.value)
            }
            else {
                $Items += $Response
            }

            $NextUri = $Response.'@odata.nextLink'
        }
        catch {
            Write-Warning "Graph request failed: $NextUri"
            Write-Warning $_.Exception.Message
            break
        }
    }

    return $Items
}

function Export-GraphPolicies {
    param(
        [Parameter(Mandatory)]
        [string]$Category,

        [Parameter(Mandatory)]
        [string]$ListUri,

        [string]$DetailUriTemplate,

        [string[]]$RelatedPaths = @("assignments")
    )

    $CategoryDirectory = Join-Path $ExportRoot $Category
    New-Item -Path $CategoryDirectory -ItemType Directory -Force | Out-Null

    Write-Host "`nExporting $Category..." -ForegroundColor Cyan

    $Policies = @(Invoke-GraphCollection -Uri $ListUri)

    if ($Policies.Count -eq 0) {
        Write-Warning "No policies were returned for $Category."
        return
    }

    $Index = 0

    foreach ($PolicySummary in $Policies) {
        $Index++

        $PolicyId = $PolicySummary.id

        $PolicyName = @(
            $PolicySummary.name
            $PolicySummary.displayName
            $PolicySummary.description
            $PolicyId
        ) | Where-Object {
            -not [string]::IsNullOrWhiteSpace([string]$_)
        } | Select-Object -First 1

        $SafeName = Get-SafeFileName -Name ([string]$PolicyName)

        Write-Host "[$Index/$($Policies.Count)] $PolicyName"

        if ($DetailUriTemplate -and $PolicyId) {
            $DetailUri = $DetailUriTemplate.Replace("{id}", $PolicyId)

            try {
                $Policy = Invoke-MgGraphRequest `
                    -Method GET `
                    -Uri $DetailUri `
                    -OutputType PSObject
            }
            catch {
                Write-Warning "Could not retrieve details for $PolicyName"
                $Policy = $PolicySummary
            }
        }
        else {
            $Policy = $PolicySummary
        }

        $RelatedData = [ordered]@{}

        foreach ($RelatedPath in $RelatedPaths) {
            if (-not $PolicyId) {
                continue
            }

            $BaseUri = if ($DetailUriTemplate) {
                $DetailUriTemplate.Replace("/{id}", "")
            }
            else {
                $ListUri.Split("?")[0]
            }

            $RelatedUri = "$BaseUri/$PolicyId/$RelatedPath"

            try {
                $RelatedData[$RelatedPath] = @(
                    Invoke-GraphCollection -Uri $RelatedUri
                )
            }
            catch {
                $RelatedData[$RelatedPath] = @()
            }
        }

        $ExportObject = [ordered]@{
            exportMetadata = [ordered]@{
                category       = $Category
                exportedAtUtc  = (Get-Date).ToUniversalTime().ToString("o")
                tenantId       = $Context.TenantId
                exportedBy     = $Context.Account
                graphEndpoint  = $ListUri
            }
            policy         = $Policy
            relatedData    = $RelatedData
        }

        $OutputFile = Join-Path `
            $CategoryDirectory `
            "$SafeName-$PolicyId.json"

        $ExportObject |
            ConvertTo-Json -Depth 100 |
            Set-Content -Path $OutputFile -Encoding UTF8
    }

    $Policies |
        ConvertTo-Json -Depth 100 |
        Set-Content `
            -Path (Join-Path $CategoryDirectory "_Policy-Index.json") `
            -Encoding UTF8
}

$PolicyCategories = @(
    @{
        Category          = "Settings-Catalog"
        ListUri           = "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies"
        DetailUriTemplate = "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies/{id}?`$expand=settings"
        RelatedPaths      = @("assignments")
    },
    @{
        Category          = "Device-Configurations"
        ListUri           = "https://graph.microsoft.com/beta/deviceManagement/deviceConfigurations"
        DetailUriTemplate = "https://graph.microsoft.com/beta/deviceManagement/deviceConfigurations/{id}"
        RelatedPaths      = @("assignments")
    },
    @{
        Category          = "Compliance-Policies"
        ListUri           = "https://graph.microsoft.com/beta/deviceManagement/deviceCompliancePolicies"
        DetailUriTemplate = "https://graph.microsoft.com/beta/deviceManagement/deviceCompliancePolicies/{id}"
        RelatedPaths      = @("assignments")
    },
    @{
        Category          = "Endpoint-Security-Intents"
        ListUri           = "https://graph.microsoft.com/beta/deviceManagement/intents"
        DetailUriTemplate = "https://graph.microsoft.com/beta/deviceManagement/intents/{id}"
        RelatedPaths      = @("assignments", "settings")
    },
    @{
        Category          = "Administrative-Templates"
        ListUri           = "https://graph.microsoft.com/beta/deviceManagement/groupPolicyConfigurations"
        DetailUriTemplate = "https://graph.microsoft.com/beta/deviceManagement/groupPolicyConfigurations/{id}"
        RelatedPaths      = @("assignments", "definitionValues")
    },
    @{
        Category          = "Enrollment-Configurations"
        ListUri           = "https://graph.microsoft.com/beta/deviceManagement/deviceEnrollmentConfigurations"
        DetailUriTemplate = "https://graph.microsoft.com/beta/deviceManagement/deviceEnrollmentConfigurations/{id}"
        RelatedPaths      = @("assignments")
    },
    @{
        Category          = "Autopilot-Deployment-Profiles"
        ListUri           = "https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeploymentProfiles"
        DetailUriTemplate = "https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeploymentProfiles/{id}"
        RelatedPaths      = @("assignments")
    },
    @{
        Category          = "PowerShell-Scripts"
        ListUri           = "https://graph.microsoft.com/beta/deviceManagement/deviceManagementScripts"
        DetailUriTemplate = "https://graph.microsoft.com/beta/deviceManagement/deviceManagementScripts/{id}"
        RelatedPaths      = @("assignments")
    },
    @{
        Category          = "Shell-Scripts"
        ListUri           = "https://graph.microsoft.com/beta/deviceManagement/deviceShellScripts"
        DetailUriTemplate = "https://graph.microsoft.com/beta/deviceManagement/deviceShellScripts/{id}"
        RelatedPaths      = @("assignments")
    },
    @{
        Category          = "Remediation-Scripts"
        ListUri           = "https://graph.microsoft.com/beta/deviceManagement/deviceHealthScripts"
        DetailUriTemplate = "https://graph.microsoft.com/beta/deviceManagement/deviceHealthScripts/{id}"
        RelatedPaths      = @("assignments")
    }
)

foreach ($PolicyCategory in $PolicyCategories) {
    Export-GraphPolicies @PolicyCategory
}

$ExportSummary = [ordered]@{
    exportedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    tenantId      = $Context.TenantId
    exportedBy    = $Context.Account
    categories    = $PolicyCategories.Category
    warning       = @(
        "This archive may contain sensitive configuration data.",
        "Review its contents before sharing.",
        "Some endpoints use Microsoft Graph beta and may change."
    )
}

$ExportSummary |
    ConvertTo-Json -Depth 10 |
    Set-Content `
        -Path (Join-Path $ExportRoot "EXPORT-SUMMARY.json") `
        -Encoding UTF8

Write-Host "`nCompressing export..." -ForegroundColor Cyan

Compress-Archive `
    -Path "$ExportRoot\*" `
    -DestinationPath $ZipPath `
    -CompressionLevel Optimal `
    -Force

Disconnect-MgGraph | Out-Null

Write-Host "`nExport complete." -ForegroundColor Green
Write-Host "Folder: $ExportRoot"
Write-Host "ZIP:    $ZipPath" -ForegroundColor Yellow