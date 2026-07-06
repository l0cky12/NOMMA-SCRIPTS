<#
.SYNOPSIS
    Installs, authorizes, and configures a DHCP Server on Windows Server 2019
    with three /22 scopes. Safe to run multiple times (idempotent).

.DESCRIPTION
    1. Checks whether the DHCP Server role is installed; installs it (with
       management tools) if missing.
    2. Authorizes the DHCP server in Active Directory if the server is
       domain-joined.
    3. Creates three DHCP scopes (10.1.0.0/22, 10.6.4.0/22, 10.6.12.0/22),
       skipping any scope that already exists.
    4. Applies scope options (router, DNS, domain name) and optional
       exclusion ranges — all driven by placeholders in the CONFIGURATION
       section below.
    5. Activates each scope and prints verification output at the end.

.NOTES
    Run from an elevated (Run as Administrator) PowerShell session.
    Requires: Windows Server 2019, DhcpServer PowerShell module
    (installed automatically with the role's management tools).
#>

#Requires -RunAsAdministrator

# Stop on any unhandled error so failures are not silently ignored.
$ErrorActionPreference = 'Stop'

# =====================================================================
# CONFIGURATION - EDIT THE PLACEHOLDERS BELOW BEFORE RUNNING
# =====================================================================
# Any value left as 'CHANGE_ME' is treated as "not configured": the
# script will skip that setting and print a warning instead of applying
# a bogus value. This keeps the script safe to run even if you forget
# to fill something in.

# --- DNS settings (applied to every scope) --------------------------
$DnsServers   = @('CHANGE_ME', 'CHANGE_ME')   # e.g. @('10.1.0.10','10.1.0.11')
$DnsDomain    = 'CHANGE_ME'                    # e.g. 'corp.contoso.com'

# --- Lease duration (applied to every scope) ------------------------
$LeaseDuration = New-TimeSpan -Days 8          # PLACEHOLDER: adjust as needed

# --- Scope definitions -----------------------------------------------
# Router          : default gateway handed to clients (PLACEHOLDER)
# ExclusionRanges : optional; array of @{Start='x';End='y'} hashtables,
#                   or an empty array @() for no exclusions (PLACEHOLDER)
$Scopes = @(
    @{
        Name            = 'Scope-10.1.0.0'
        Description     = 'DHCP scope for 10.1.0.0/22 network'
        ScopeId         = '10.1.0.0'
        StartRange      = '10.1.0.1'
        EndRange        = '10.1.3.254'
        SubnetMask      = '255.255.252.0'
        Router          = 'CHANGE_ME'          # e.g. '10.1.0.1'
        ExclusionRanges = @(
            # @{ Start = '10.1.0.1'; End = '10.1.0.20' }   # example
        )
    },
    @{
        Name            = 'Scope-10.6.4.0'
        Description     = 'DHCP scope for 10.6.4.0/22 network'
        ScopeId         = '10.6.4.0'
        StartRange      = '10.6.4.1'
        EndRange        = '10.6.7.254'
        SubnetMask      = '255.255.252.0'
        Router          = 'CHANGE_ME'          # e.g. '10.6.4.1'
        ExclusionRanges = @(
            # @{ Start = '10.6.4.1'; End = '10.6.4.20' }   # example
        )
    },
    @{
        Name            = 'Scope-10.6.12.0'
        Description     = 'DHCP scope for 10.6.12.0/22 network'
        ScopeId         = '10.6.12.0'
        StartRange      = '10.6.12.1'
        EndRange        = '10.6.15.254'
        SubnetMask      = '255.255.252.0'
        Router          = 'CHANGE_ME'          # e.g. '10.6.12.1'
        ExclusionRanges = @(
            # @{ Start = '10.6.12.1'; End = '10.6.12.20' } # example
        )
    }
)

# Helper: returns $true when a placeholder value has been replaced.
function Test-Configured {
    param([object]$Value)
    if ($null -eq $Value) { return $false }
    foreach ($v in @($Value)) {
        if ([string]$v -eq 'CHANGE_ME' -or [string]::IsNullOrWhiteSpace([string]$v)) {
            return $false
        }
    }
    return $true
}

# =====================================================================
# SECTION 1: DHCP SERVER ROLE - CHECK AND INSTALL
# =====================================================================
Write-Host "`n=== [1/5] Checking DHCP Server role ===" -ForegroundColor Cyan
try {
    $dhcpFeature = Get-WindowsFeature -Name DHCP

    if ($dhcpFeature.Installed) {
        Write-Host "DHCP Server role is already installed." -ForegroundColor Green
    }
    else {
        Write-Host "DHCP Server role not found. Installing role and management tools..."
        $result = Install-WindowsFeature -Name DHCP -IncludeManagementTools
        if (-not $result.Success) {
            throw "Install-WindowsFeature reported failure (ExitCode: $($result.ExitCode))."
        }
        Write-Host "DHCP Server role installed successfully." -ForegroundColor Green
        if ($result.RestartNeeded -eq 'Yes') {
            Write-Warning "A restart is required to complete the role installation. Reboot, then re-run this script."
        }
    }

    # Import the DhcpServer module (available once the role/tools exist).
    Import-Module DhcpServer -ErrorAction Stop

    # Create the local DHCP Administrators / DHCP Users security groups
    # (harmless if they already exist).
    Add-DhcpServerSecurityGroup -ErrorAction SilentlyContinue

    # Tell Server Manager that post-install configuration is complete,
    # which clears the "Complete DHCP configuration" alert flag.
    $smRegPath = 'HKLM:\SOFTWARE\Microsoft\ServerManager\Roles\12'
    if (Test-Path $smRegPath) {
        Set-ItemProperty -Path $smRegPath -Name ConfigurationState -Value 2
    }

    # Make sure the DHCP Server service is running and starts automatically.
    Set-Service  -Name DHCPServer -StartupType Automatic
    Start-Service -Name DHCPServer
}
catch {
    Write-Error "Failed during role installation/check: $($_.Exception.Message)"
    exit 1
}

# =====================================================================
# SECTION 2: AUTHORIZE DHCP SERVER IN ACTIVE DIRECTORY
# =====================================================================
Write-Host "`n=== [2/5] Checking Active Directory authorization ===" -ForegroundColor Cyan
try {
    $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem

    if ($computerSystem.PartOfDomain) {
        $serverFqdn = ('{0}.{1}' -f $env:COMPUTERNAME, $computerSystem.Domain).ToLower()

        # Get the list of DHCP servers already authorized in AD.
        $authorized = Get-DhcpServerInDC -ErrorAction Stop

        if ($authorized.DnsName -contains $serverFqdn) {
            Write-Host "Server '$serverFqdn' is already authorized in Active Directory." -ForegroundColor Green
        }
        else {
            Write-Host "Authorizing '$serverFqdn' in Active Directory..."
            Add-DhcpServerInDC -DnsName $serverFqdn
            Write-Host "Server authorized successfully." -ForegroundColor Green
            # Restart the service so authorization takes effect immediately.
            Restart-Service -Name DHCPServer -Force
        }
    }
    else {
        Write-Warning "Server is not domain-joined. Skipping AD authorization (standalone DHCP server)."
    }
}
catch {
    # Authorization requires Enterprise Admin (or delegated) rights;
    # warn but continue so scopes can still be created.
    Write-Warning "AD authorization step failed: $($_.Exception.Message)"
    Write-Warning "You may need to authorize manually with an Enterprise Admin account: Add-DhcpServerInDC"
}

# =====================================================================
# SECTION 3: CREATE DHCP SCOPES (SKIP DUPLICATES)
# =====================================================================
Write-Host "`n=== [3/5] Creating DHCP scopes ===" -ForegroundColor Cyan
foreach ($scope in $Scopes) {
    try {
        # Check whether this scope already exists (idempotency guard).
        $existing = Get-DhcpServerv4Scope -ScopeId $scope.ScopeId -ErrorAction SilentlyContinue

        if ($existing) {
            Write-Host "Scope $($scope.ScopeId) ('$($existing.Name)') already exists. Skipping creation." -ForegroundColor Yellow
        }
        else {
            Write-Host "Creating scope $($scope.ScopeId) [$($scope.StartRange) - $($scope.EndRange)]..."
            Add-DhcpServerv4Scope `
                -Name          $scope.Name `
                -Description   $scope.Description `
                -StartRange    $scope.StartRange `
                -EndRange      $scope.EndRange `
                -SubnetMask    $scope.SubnetMask `
                -LeaseDuration $LeaseDuration `
                -State         InActive   # activated in Section 5, after options are set
            Write-Host "Scope $($scope.ScopeId) created." -ForegroundColor Green
        }

        # --- Optional exclusion ranges (idempotent) ------------------
        foreach ($excl in $scope.ExclusionRanges) {
            $existingExcl = Get-DhcpServerv4ExclusionRange -ScopeId $scope.ScopeId -ErrorAction SilentlyContinue |
                Where-Object { $_.StartRange.ToString() -eq $excl.Start -and $_.EndRange.ToString() -eq $excl.End }

            if ($existingExcl) {
                Write-Host "  Exclusion $($excl.Start)-$($excl.End) already exists in $($scope.ScopeId). Skipping." -ForegroundColor Yellow
            }
            else {
                Add-DhcpServerv4ExclusionRange -ScopeId $scope.ScopeId `
                    -StartRange $excl.Start -EndRange $excl.End
                Write-Host "  Added exclusion range $($excl.Start) - $($excl.End)." -ForegroundColor Green
            }
        }
    }
    catch {
        Write-Error "Failed to create/configure scope $($scope.ScopeId): $($_.Exception.Message)"
    }
}

# =====================================================================
# SECTION 4: SCOPE OPTIONS (ROUTER, DNS, DOMAIN NAME)
# =====================================================================
Write-Host "`n=== [4/5] Applying scope options ===" -ForegroundColor Cyan
foreach ($scope in $Scopes) {
    try {
        # Skip option configuration if the scope was never created.
        if (-not (Get-DhcpServerv4Scope -ScopeId $scope.ScopeId -ErrorAction SilentlyContinue)) {
            Write-Warning "Scope $($scope.ScopeId) does not exist; skipping options."
            continue
        }

        # Option 003: default gateway / router (per scope).
        if (Test-Configured $scope.Router) {
            Set-DhcpServerv4OptionValue -ScopeId $scope.ScopeId -Router $scope.Router
            Write-Host "Scope $($scope.ScopeId): router set to $($scope.Router)." -ForegroundColor Green
        }
        else {
            Write-Warning "Scope $($scope.ScopeId): Router is still a placeholder (CHANGE_ME). Gateway option NOT set."
        }

        # Options 006 (DNS servers) and 015 (DNS domain name), per scope.
        if (Test-Configured $DnsServers) {
            Set-DhcpServerv4OptionValue -ScopeId $scope.ScopeId -DnsServer $DnsServers -Force
            Write-Host "Scope $($scope.ScopeId): DNS servers set to $($DnsServers -join ', ')." -ForegroundColor Green
        }
        else {
            Write-Warning "Scope $($scope.ScopeId): DnsServers still placeholders. DNS option NOT set."
        }

        if (Test-Configured $DnsDomain) {
            Set-DhcpServerv4OptionValue -ScopeId $scope.ScopeId -DnsDomain $DnsDomain
            Write-Host "Scope $($scope.ScopeId): DNS domain set to $DnsDomain." -ForegroundColor Green
        }
        else {
            Write-Warning "Scope $($scope.ScopeId): DnsDomain still a placeholder. Domain option NOT set."
        }

        # Keep lease duration in sync on re-runs (idempotent update).
        Set-DhcpServerv4Scope -ScopeId $scope.ScopeId -LeaseDuration $LeaseDuration
    }
    catch {
        Write-Error "Failed to set options on scope $($scope.ScopeId): $($_.Exception.Message)"
    }
}

# =====================================================================
# SECTION 5: ACTIVATE SCOPES
# =====================================================================
Write-Host "`n=== [5/5] Activating scopes ===" -ForegroundColor Cyan
foreach ($scope in $Scopes) {
    try {
        $current = Get-DhcpServerv4Scope -ScopeId $scope.ScopeId -ErrorAction SilentlyContinue
        if (-not $current) { continue }

        if ($current.State -eq 'Active') {
            Write-Host "Scope $($scope.ScopeId) is already active." -ForegroundColor Green
        }
        else {
            Set-DhcpServerv4Scope -ScopeId $scope.ScopeId -State Active
            Write-Host "Scope $($scope.ScopeId) activated." -ForegroundColor Green
        }
    }
    catch {
        Write-Error "Failed to activate scope $($scope.ScopeId): $($_.Exception.Message)"
    }
}

# =====================================================================
# VERIFICATION
# =====================================================================
Write-Host "`n=== VERIFICATION ===" -ForegroundColor Cyan

Write-Host "`n--- DHCP Server role state ---"
Get-WindowsFeature -Name DHCP, RSAT-DHCP | Format-Table Name, InstallState -AutoSize

Write-Host "--- DHCP Server service ---"
Get-Service -Name DHCPServer | Format-Table Name, Status, StartType -AutoSize

Write-Host "--- Authorized DHCP servers in AD ---"
try   { Get-DhcpServerInDC | Format-Table DnsName, IPAddress -AutoSize }
catch { Write-Warning "Could not query AD authorization: $($_.Exception.Message)" }

Write-Host "--- Configured scopes ---"
Get-DhcpServerv4Scope |
    Format-Table ScopeId, Name, SubnetMask, StartRange, EndRange, LeaseDuration, State -AutoSize

Write-Host "--- Scope options ---"
foreach ($scope in $Scopes) {
    if (Get-DhcpServerv4Scope -ScopeId $scope.ScopeId -ErrorAction SilentlyContinue) {
        Write-Host "Options for $($scope.ScopeId):"
        Get-DhcpServerv4OptionValue -ScopeId $scope.ScopeId -ErrorAction SilentlyContinue |
            Format-Table OptionId, Name, Value -AutoSize
    }
}

Write-Host "--- Exclusion ranges ---"
Get-DhcpServerv4ExclusionRange -ErrorAction SilentlyContinue |
    Format-Table ScopeId, StartRange, EndRange -AutoSize

Write-Host "`nDHCP configuration script completed." -ForegroundColor Cyan
