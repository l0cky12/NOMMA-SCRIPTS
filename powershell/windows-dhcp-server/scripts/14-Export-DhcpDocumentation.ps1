<#
.SYNOPSIS
    Documents the full DHCP configuration - scopes, options, exclusions,
    reservations - to a timestamped text report (plus CSVs).

.WHEN TO USE
    Change documentation, audits, handover to colleagues, or before/after
    comparisons. Read-only - always safe to run.

.HOW TO RUN
    As Administrator:
        .\14-Export-DhcpDocumentation.ps1
        .\14-Export-DhcpDocumentation.ps1 -OutputFolder C:\Docs\DHCP
#>

#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$OutputFolder    # default: <ReportRoot>\Documentation-<timestamp>
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\CompanyDhcpConfig.ps1"
Import-Module DhcpServer

try {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    if (-not $OutputFolder) {
        $OutputFolder = Join-Path $CompanyDhcp.ReportRoot "Documentation-$stamp"
    }
    New-Item -Path $OutputFolder -ItemType Directory -Force | Out-Null
    $reportFile = Join-Path $OutputFolder 'DhcpDocumentation.txt'

    # Everything written inside this block lands in the text report.
    $doc = & {
        "==================================================================="
        " DHCP SERVER DOCUMENTATION - $env:COMPUTERNAME"
        " Generated: $(Get-Date)"
        "==================================================================="

        "`n--- AUTHORIZED SERVERS IN AD ---"
        try   { Get-DhcpServerInDC | Format-Table DnsName, IPAddress -AutoSize | Out-String }
        catch { "  (unavailable: $($_.Exception.Message))" }

        "`n--- SERVER-LEVEL OPTIONS ---"
        Get-DhcpServerv4OptionValue -ErrorAction SilentlyContinue |
            Format-Table OptionId, Name, Value -AutoSize | Out-String

        $scopes = Get-DhcpServerv4Scope
        "`n--- SCOPES ($($scopes.Count)) ---"
        $scopes | Format-Table ScopeId, Name, StartRange, EndRange, SubnetMask, LeaseDuration, State -AutoSize | Out-String

        foreach ($s in $scopes) {
            "`n==================== SCOPE $($s.ScopeId) - $($s.Name) ===================="

            "`n  Options:"
            Get-DhcpServerv4OptionValue -ScopeId $s.ScopeId -ErrorAction SilentlyContinue |
                Format-Table OptionId, Name, Value -AutoSize | Out-String

            "`n  Exclusion ranges:"
            $excl = Get-DhcpServerv4ExclusionRange -ScopeId $s.ScopeId -ErrorAction SilentlyContinue
            if ($excl) { $excl | Format-Table StartRange, EndRange -AutoSize | Out-String }
            else       { "    (none)" }

            "`n  Reservations:"
            $res = Get-DhcpServerv4Reservation -ScopeId $s.ScopeId -ErrorAction SilentlyContinue
            if ($res) { $res | Format-Table IPAddress, ClientId, Name, Description -AutoSize | Out-String }
            else      { "    (none)" }

            "`n  Utilization:"
            Get-DhcpServerv4ScopeStatistics -ScopeId $s.ScopeId |
                Format-Table Free, InUse, Reserved, PercentageInUse -AutoSize | Out-String
        }
    }
    $doc | Out-File -FilePath $reportFile -Encoding UTF8

    # Machine-readable CSV companions for spreadsheets/CMDB import.
    Get-DhcpServerv4Scope |
        Export-Csv (Join-Path $OutputFolder 'Scopes.csv') -NoTypeInformation -Encoding UTF8
    Get-DhcpServerv4ExclusionRange -ErrorAction SilentlyContinue |
        Export-Csv (Join-Path $OutputFolder 'Exclusions.csv') -NoTypeInformation -Encoding UTF8
    $allRes = foreach ($s in Get-DhcpServerv4Scope) {
        Get-DhcpServerv4Reservation -ScopeId $s.ScopeId -ErrorAction SilentlyContinue
    }
    if ($allRes) {
        $allRes | Export-Csv (Join-Path $OutputFolder 'Reservations.csv') -NoTypeInformation -Encoding UTF8
    }

    Write-Host "Documentation written to: $OutputFolder" -ForegroundColor Green
    Get-ChildItem $OutputFolder | Format-Table Name, Length -AutoSize
}
catch {
    Write-Error "Documentation export failed: $($_.Exception.Message)"
    exit 1
}
