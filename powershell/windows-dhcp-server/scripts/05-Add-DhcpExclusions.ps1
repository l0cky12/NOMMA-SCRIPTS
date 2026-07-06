<#
.SYNOPSIS
    Adds exclusion ranges (addresses DHCP must never lease out).

.WHEN TO USE
    After creating scopes, to protect gateways, servers, printers and
    other statically-assigned addresses. Safe to re-run: existing
    exclusions are skipped.

.HOW TO RUN
    As Administrator:
        # Apply all exclusions defined in CompanyDhcpConfig.ps1:
        .\05-Add-DhcpExclusions.ps1

        # Or add a single ad-hoc exclusion:
        .\05-Add-DhcpExclusions.ps1 -ScopeId 10.1.0.0 -StartRange 10.1.0.1 -EndRange 10.1.0.20
#>

#Requires -RunAsAdministrator
[CmdletBinding(DefaultParameterSetName = 'FromConfig')]
param(
    [Parameter(ParameterSetName = 'AdHoc', Mandatory)] [string]$ScopeId,
    [Parameter(ParameterSetName = 'AdHoc', Mandatory)] [string]$StartRange,
    [Parameter(ParameterSetName = 'AdHoc', Mandatory)] [string]$EndRange
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\CompanyDhcpConfig.ps1"
Import-Module DhcpServer

# Adds one exclusion if it doesn't already exist.
function Add-ExclusionIfMissing {
    param([string]$Scope, [string]$Start, [string]$End)

    if (-not (Get-DhcpServerv4Scope -ScopeId $Scope -ErrorAction SilentlyContinue)) {
        Write-Warning "Scope $Scope does not exist. Skipping exclusion $Start-$End."
        return
    }
    $existing = Get-DhcpServerv4ExclusionRange -ScopeId $Scope -ErrorAction SilentlyContinue |
        Where-Object { $_.StartRange.ToString() -eq $Start -and $_.EndRange.ToString() -eq $End }

    if ($existing) {
        Write-Host "Exclusion $Start-$End already exists in $Scope. Skipping." -ForegroundColor Yellow
    } else {
        Add-DhcpServerv4ExclusionRange -ScopeId $Scope -StartRange $Start -EndRange $End
        Write-Host "Added exclusion $Start - $End to scope $Scope." -ForegroundColor Green
    }
}

try {
    if ($PSCmdlet.ParameterSetName -eq 'AdHoc') {
        Add-ExclusionIfMissing -Scope $ScopeId -Start $StartRange -End $EndRange
    }
    else {
        # Apply every exclusion defined in the shared config file.
        $any = $false
        foreach ($scope in $CompanyDhcp.Scopes) {
            foreach ($excl in $scope.Exclusions) {
                $any = $true
                Add-ExclusionIfMissing -Scope $scope.ScopeId -Start $excl.Start -End $excl.End
            }
        }
        if (-not $any) {
            Write-Warning "No exclusions defined in CompanyDhcpConfig.ps1 (Exclusions arrays are empty)."
        }
    }

    # --- Verification -------------------------------------------------
    Write-Host "`n--- Current exclusion ranges ---" -ForegroundColor Cyan
    Get-DhcpServerv4ExclusionRange -ErrorAction SilentlyContinue |
        Format-Table ScopeId, StartRange, EndRange -AutoSize
}
catch {
    Write-Error "Failed to add exclusion: $($_.Exception.Message)"
    exit 1
}
