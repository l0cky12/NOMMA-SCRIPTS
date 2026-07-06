<#
.SYNOPSIS
    Shared configuration for all Company DHCP scripts.

.DESCRIPTION
    Central place for company-specific values. Every other script
    dot-sources this file:  . "$PSScriptRoot\CompanyDhcpConfig.ps1"

    EDIT ALL 'CHANGE_ME' PLACEHOLDERS BEFORE PRODUCTION USE.
    Scripts detect unreplaced placeholders and skip that setting
    with a warning instead of applying a bogus value.
#>

$CompanyDhcp = @{

    # --- DNS settings (applied to every scope) ----------------------
    DnsServers    = @('CHANGE_ME', 'CHANGE_ME')   # e.g. @('10.1.0.10','10.1.0.11')
    DnsDomain     = 'CHANGE_ME'                    # e.g. 'corp.company.com'

    # --- Lease duration (applied to every scope) --------------------
    LeaseDuration = New-TimeSpan -Days 8           # PLACEHOLDER: adjust to policy

    # --- File locations ----------------------------------------------
    BackupRoot    = 'C:\DhcpBackups'               # PLACEHOLDER: prefer a non-system drive / UNC copy job
    ReportRoot    = 'C:\DhcpReports'               # CSV exports, health checks, documentation

    # --- Scope definitions --------------------------------------------
    # Router     : default gateway handed to clients (PLACEHOLDER)
    # Exclusions : array of @{Start='x'; End='y'} hashtables, @() for none
    Scopes = @(
        @{
            Name        = 'Company-Scope-10.1.0.0-22'
            Description = 'Company network 10.1.0.0/22'
            ScopeId     = '10.1.0.0'
            StartRange  = '10.1.0.1'
            EndRange    = '10.1.3.254'
            SubnetMask  = '255.255.252.0'
            Router      = 'CHANGE_ME'              # e.g. '10.1.0.1'
            Exclusions  = @(
                # @{ Start = '10.1.0.1'; End = '10.1.0.20' }   # example: gateway + infrastructure
            )
        },
        @{
            Name        = 'Company-Scope-10.6.4.0-22'
            Description = 'Company network 10.6.4.0/22'
            ScopeId     = '10.6.4.0'
            StartRange  = '10.6.4.1'
            EndRange    = '10.6.7.254'
            SubnetMask  = '255.255.252.0'
            Router      = 'CHANGE_ME'              # e.g. '10.6.4.1'
            Exclusions  = @(
                # @{ Start = '10.6.4.1'; End = '10.6.4.20' }
            )
        },
        @{
            Name        = 'Company-Scope-10.6.12.0-22'
            Description = 'Company network 10.6.12.0/22'
            ScopeId     = '10.6.12.0'
            StartRange  = '10.6.12.1'
            EndRange    = '10.6.15.254'
            SubnetMask  = '255.255.252.0'
            Router      = 'CHANGE_ME'              # e.g. '10.6.12.1'
            Exclusions  = @(
                # @{ Start = '10.6.12.1'; End = '10.6.12.20' }
            )
        }
    )
}

# Helper used by all scripts: $true only when a placeholder was replaced.
function Test-DhcpConfigured {
    param([object]$Value)
    if ($null -eq $Value) { return $false }
    foreach ($v in @($Value)) {
        if ([string]$v -eq 'CHANGE_ME' -or [string]::IsNullOrWhiteSpace([string]$v)) {
            return $false
        }
    }
    return $true
}
