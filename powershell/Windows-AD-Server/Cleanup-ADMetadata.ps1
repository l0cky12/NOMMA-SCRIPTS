<#
.SYNOPSIS
    Safely detects and removes stale Active Directory metadata left behind by a
    failed or incomplete domain controller demotion.

.DESCRIPTION
    When a domain controller (DC) is removed without a clean demotion (hardware
    failure, failed Uninstall-ADDSDomainController / dcpromo, a deleted VM), its
    metadata remains in Active Directory and DNS. That stale metadata causes
    replication errors, KCC/topology problems, failed authentication referrals
    and misleading monitoring alerts.

    This script performs the equivalent of "metadata cleanup" in a controlled,
    auditable way:

      Phase 1 - Pre-flight safety checks
        * Verifies the ActiveDirectory module (and DnsServer module when
          -CleanupDNS is used) is available.
        * Verifies the operator appears to have Domain Admins / Enterprise
          Admins rights (config-partition deletions require them).
        * Refuses to run on the stale DC itself.
        * Verifies the target DC is NOT reachable (LDAP/TCP 389 answering is a
          hard stop; ping/SMB answering requires -Force to proceed, because it
          may indicate IP or name reuse).
        * Detects whether the stale DC holds any FSMO roles and stops with
          seizure guidance if it does.
        * Refuses to run if the stale DC is the only DC in the domain.

      Phase 2 - Discovery and "before" report
        * Inventories every piece of metadata related to the stale DC:
          replication connection objects on other DCs (nTDSConnection),
          the NTDS Settings object (nTDSDSA), the server object in AD Sites
          and Services, the DC computer account, legacy FRS and DFSR SYSVOL
          membership objects, and (optionally) DNS records.
        * Exports the inventory to a timestamped "Before" CSV.

      Phase 3 - Removal (only with confirmation)
        * Each deletion is individually gated by SupportsShouldProcess with
          ConfirmImpact = High: nothing is deleted by default without an
          explicit confirmation, and -WhatIf performs a full dry run.
        * Anything that cannot be verified safely (e.g. a computer account
          that does not look like a DC account, domain-apex DNS records when
          the stale DC's IP could not be determined) is flagged for MANUAL
          review instead of being deleted.

      Phase 4 - "After" report and follow-up guidance
        * Exports a timestamped "After" CSV with the outcome of every item
          and prints the post-cleanup verification steps.

    All console output is also written to a timestamped log file.

.PARAMETER StaleDCName
    Name of the stale/orphaned domain controller. Short (NetBIOS) name or
    FQDN. Mandatory - the script never guesses a target.

.PARAMETER DomainName
    DNS name of the AD domain the stale DC belonged to. Defaults to the
    domain discovered from the machine's current domain context.

.PARAMETER SiteName
    AD site the stale DC's server object lives in. Optional; when omitted the
    script searches every site. Required only when server objects with the
    same name exist in more than one site.

.PARAMETER LogPath
    Directory for the timestamped log file.
    Defaults to "$env:ProgramData\ADMetadataCleanup\Logs".

.PARAMETER ReportPath
    Directory for the Before/After CSV reports.
    Defaults to "$env:ProgramData\ADMetadataCleanup\Reports".

.PARAMETER CleanupDNS
    Also detect and (with confirmation) remove DNS records that reference the
    stale DC: its A/AAAA host records, the CNAME GUID alias in _msdcs, SRV
    records whose target is the stale DC, NS records naming it, and
    well-known records (@ / gc / DomainDnsZones / ForestDnsZones) that carry
    the stale DC's IP address. Requires the DnsServer RSAT module.

.PARAMETER Force
    Suppresses the interactive confirmation prompts (sets ConfirmPreference
    to None and skips the final "are you sure" gate) and allows the run to
    continue when the stale DC answers ping/SMB (possible IP reuse).
    -Force NEVER overrides the hard stops: a target answering on LDAP/389, a
    target holding FSMO roles, or the target being the last DC in the domain.

.EXAMPLE
    PS> .\Cleanup-ADMetadata.ps1 -StaleDCName 'OLDDC01' -WhatIf

    DRY RUN. Runs every safety check and the full discovery, exports the
    "Before" CSV, and shows exactly what WOULD be deleted. Nothing is changed.

.EXAMPLE
    PS> .\Cleanup-ADMetadata.ps1 -StaleDCName 'OLDDC01' -CleanupDNS

    Interactive cleanup including DNS. Every deletion prompts for
    confirmation (answer per item, or [A] Yes to All).

.EXAMPLE
    PS> .\Cleanup-ADMetadata.ps1 -StaleDCName 'OLDDC01' -DomainName 'corp.example.com' `
            -SiteName 'Branch-01' -CleanupDNS -Force

    Unattended cleanup for a DC in a known site. Use only after a successful
    -WhatIf run has been reviewed.

.NOTES
    Requires : Windows PowerShell 5.1, RSAT ActiveDirectory module
               (DnsServer module additionally for -CleanupDNS)
    Run as   : Domain Admins (Enterprise Admins for configuration-partition
               objects in some delegation models)
    Run from : Any domain-joined admin workstation or a HEALTHY DC -
               never from the stale DC itself.

    The fully Microsoft-supported alternative for the directory part of this
    cleanup is "ntdsutil: metadata cleanup" or deleting the DC's computer
    object from Active Directory Users and Computers (which triggers the
    same server-side cleanup on Windows Server 2008+). This script automates
    the same object removals with logging and reporting around them.
#>

#Requires -Version 5.1

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true,
               HelpMessage = 'Short name or FQDN of the stale domain controller to clean up.')]
    [ValidateNotNullOrEmpty()]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9\-\.]*$')]
    [string]$StaleDCName,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$DomainName,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$SiteName,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$LogPath = (Join-Path -Path $env:ProgramData -ChildPath 'ADMetadataCleanup\Logs'),

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ReportPath = (Join-Path -Path $env:ProgramData -ChildPath 'ADMetadataCleanup\Reports'),

    [Parameter()]
    [switch]$CleanupDNS,

    [Parameter()]
    [switch]$Force
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# -Force means "do not prompt per item" - but only if the operator did not
# explicitly ask for confirmation with -Confirm.
if ($Force -and -not $PSBoundParameters.ContainsKey('Confirm')) {
    $ConfirmPreference = 'None'
}

#region ===================== Helper functions ================================

function Write-Log {
    <# Writes a timestamped line to the console and to the log file. #>
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'ACTION', 'OK')][string]$Level = 'INFO'
    )
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line  = '[{0}] [{1,-6}] {2}' -f $stamp, $Level, $Message
    if ($script:LogFile) {
        Add-Content -Path $script:LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    }
    switch ($Level) {
        'ERROR'  { Write-Host $line -ForegroundColor Red }
        'WARN'   { Write-Host $line -ForegroundColor Yellow }
        'ACTION' { Write-Host $line -ForegroundColor Cyan }
        'OK'     { Write-Host $line -ForegroundColor Green }
        default  { Write-Host $line }
    }
}

function Stop-Fatal {
    <# Logs a fatal pre-flight/validation failure and aborts the script. #>
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Log -Message $Message -Level 'ERROR'
    throw "ABORTED: $Message"
}

function New-Finding {
    <# Registers one discovered piece of stale metadata in the report list. #>
    param(
        [Parameter(Mandatory = $true)][string]$Category,
        [Parameter(Mandatory = $true)][string]$ObjectType,
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Identity = '',
        [string]$Zone = '',
        [string]$Details = '',
        [string]$Status = 'Detected',
        [object]$DnsRecord = $null
    )
    $finding = [pscustomobject]@{
        Category     = $Category
        ObjectType   = $ObjectType
        Name         = $Name
        Identity     = $Identity
        Zone         = $Zone
        Details      = $Details
        Status       = $Status
        Result       = ''
        TimeDetected = (Get-Date -Format 's')
        TimeActioned = ''
        DnsRecord    = $DnsRecord   # raw record object; excluded from CSV
    }
    [void]$script:Findings.Add($finding)
    return $finding
}

function ConvertTo-LdapFilterValue {
    <# Escapes a string for safe use inside an LDAP filter (RFC 4515). #>
    param([Parameter(Mandatory = $true)][string]$Value)
    return ($Value -replace '\\', '\5c' -replace '\*', '\2a' -replace '\(', '\28' -replace '\)', '\29')
}

function Test-TcpPort {
    <# Returns $true when a TCP connection to the port succeeds within the timeout. #>
    param(
        [Parameter(Mandatory = $true)][string]$ComputerName,
        [Parameter(Mandatory = $true)][int]$Port,
        [int]$TimeoutMs = 3000
    )
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($ComputerName, $Port, $null, $null)
        if ($async.AsyncWaitHandle.WaitOne($TimeoutMs, $false) -and $client.Connected) {
            $client.EndConnect($async)
            return $true
        }
        return $false
    }
    catch { return $false }
    finally { $client.Close() }
}

function Remove-StaleADObject {
    <#
        Deletes one AD object with full ShouldProcess gating, clearing
        accidental-deletion protection on the subtree first. Updates the
        finding's Status/Result so the After CSV reflects what happened.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory = $true)][object]$Finding,
        [switch]$Recursive
    )
    $dn = $Finding.Identity
    if ($PSCmdlet.ShouldProcess($dn, "DELETE AD object ($($Finding.ObjectType))")) {
        try {
            # Clear ProtectedFromAccidentalDeletion on the object and any
            # children, otherwise the delete is rejected by the deny ACE.
            try {
                Get-ADObject -SearchBase $dn -SearchScope Subtree -Filter * `
                             -Properties ProtectedFromAccidentalDeletion -Server $script:TargetServer |
                    Where-Object { $_.ProtectedFromAccidentalDeletion } |
                    ForEach-Object {
                        Set-ADObject -Identity $_.DistinguishedName `
                                     -ProtectedFromAccidentalDeletion:$false `
                                     -Server $script:TargetServer -Confirm:$false
                    }
            }
            catch {
                Write-Log "Could not evaluate deletion protection on '$dn': $($_.Exception.Message)" 'WARN'
            }

            $removeParams = @{
                Identity    = $dn
                Server      = $script:TargetServer
                Confirm     = $false
                ErrorAction = 'Stop'
            }
            if ($Recursive) { $removeParams['Recursive'] = $true }
            Remove-ADObject @removeParams

            $Finding.Status       = 'Removed'
            $Finding.Result       = 'Deleted successfully'
            $Finding.TimeActioned = (Get-Date -Format 's')
            Write-Log "Removed: $dn" 'OK'
        }
        catch {
            $Finding.Status       = 'Failed'
            $Finding.Result       = $_.Exception.Message
            $Finding.TimeActioned = (Get-Date -Format 's')
            $script:ErrorCount++
            Write-Log "FAILED to remove '$dn': $($_.Exception.Message)" 'ERROR'
        }
    }
    else {
        if ($WhatIfPreference) { $Finding.Status = 'WhatIf'   ; $Finding.Result = 'Dry run - not deleted' }
        else                   { $Finding.Status = 'Declined' ; $Finding.Result = 'Operator declined confirmation' }
        Write-Log "Skipped (no confirmation): $dn" 'INFO'
    }
}

function Remove-StaleDnsRecord {
    <# Deletes one DNS resource record with full ShouldProcess gating. #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param([Parameter(Mandatory = $true)][object]$Finding)

    $target = "'$($Finding.Name)' [$($Finding.ObjectType)] in zone '$($Finding.Zone)'"
    if ($PSCmdlet.ShouldProcess($target, 'DELETE DNS record')) {
        try {
            Remove-DnsServerResourceRecord -ZoneName $Finding.Zone `
                                           -InputObject $Finding.DnsRecord `
                                           -ComputerName $script:DnsServer `
                                           -Force -Confirm:$false -ErrorAction Stop
            $Finding.Status       = 'Removed'
            $Finding.Result       = 'Deleted successfully'
            $Finding.TimeActioned = (Get-Date -Format 's')
            Write-Log "Removed DNS record: $target" 'OK'
        }
        catch {
            $Finding.Status       = 'Failed'
            $Finding.Result       = $_.Exception.Message
            $Finding.TimeActioned = (Get-Date -Format 's')
            $script:ErrorCount++
            Write-Log "FAILED to remove DNS record ${target}: $($_.Exception.Message)" 'ERROR'
        }
    }
    else {
        if ($WhatIfPreference) { $Finding.Status = 'WhatIf'   ; $Finding.Result = 'Dry run - not deleted' }
        else                   { $Finding.Status = 'Declined' ; $Finding.Result = 'Operator declined confirmation' }
        Write-Log "Skipped (no confirmation): $target" 'INFO'
    }
}

#endregion

#region ===================== Initialisation ==================================

# Normalise the target name: accept short name or FQDN.
$StaleDCShort = ($StaleDCName -split '\.')[0]
$timestamp    = Get-Date -Format 'yyyyMMdd-HHmmss'

# Create log/report directories and open the log before anything else so that
# every check - including failed ones - is captured.
foreach ($dir in @($LogPath, $ReportPath)) {
    if (-not (Test-Path -LiteralPath $dir)) {
        try   { $null = New-Item -Path $dir -ItemType Directory -Force -ErrorAction Stop }
        catch { throw "Cannot create directory '$dir': $($_.Exception.Message)" }
    }
}
$script:LogFile = Join-Path -Path $LogPath -ChildPath ("Cleanup-ADMetadata_{0}_{1}.log" -f $StaleDCShort, $timestamp)
$beforeCsv      = Join-Path -Path $ReportPath -ChildPath ("ADMetadataCleanup_{0}_Before_{1}.csv" -f $StaleDCShort, $timestamp)
$afterCsv       = Join-Path -Path $ReportPath -ChildPath ("ADMetadataCleanup_{0}_After_{1}.csv"  -f $StaleDCShort, $timestamp)

$script:Findings   = New-Object System.Collections.Generic.List[object]
$script:ErrorCount = 0
$reportColumns     = @('Category', 'ObjectType', 'Name', 'Identity', 'Zone', 'Details', 'Status', 'Result', 'TimeDetected', 'TimeActioned')

Write-Log "=== Cleanup-ADMetadata started ==="
Write-Log "Target stale DC : $StaleDCName"
Write-Log "Operator        : $env:USERDOMAIN\$env:USERNAME on $env:COMPUTERNAME"
Write-Log "Log file        : $script:LogFile"
Write-Log "Mode            : $(if ($WhatIfPreference) { 'DRY RUN (-WhatIf)' } elseif ($Force) { 'FORCE (no prompts)' } else { 'Interactive (confirm each deletion)' })"

#endregion

try {

    #region ================= Phase 1: Pre-flight safety checks ===============

    Write-Log '--- Phase 1: pre-flight safety checks ---' 'ACTION'

    # --- 1.1 Required modules -------------------------------------------------
    if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
        Stop-Fatal ("The ActiveDirectory module is not installed. Install RSAT: " +
                    "'Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0' " +
                    "(client OS) or 'Install-WindowsFeature RSAT-AD-PowerShell' (server OS).")
    }
    Import-Module -Name ActiveDirectory -ErrorAction Stop
    Write-Log 'ActiveDirectory module loaded.' 'OK'

    $dnsModuleAvailable = [bool](Get-Module -ListAvailable -Name DnsServer)
    if ($CleanupDNS -and -not $dnsModuleAvailable) {
        Stop-Fatal ("-CleanupDNS was requested but the DnsServer module is not installed. Install RSAT DNS " +
                    "tools ('Install-WindowsFeature RSAT-DNS-Server' / 'Add-WindowsCapability -Online -Name " +
                    "Rsat.Dns.Tools~~~~0.0.1.0') or re-run without -CleanupDNS and clean DNS manually.")
    }

    # --- 1.2 Never run this on the stale DC itself ----------------------------
    if ($env:COMPUTERNAME -ieq $StaleDCShort) {
        Stop-Fatal "This machine IS '$StaleDCShort'. Run the cleanup from a healthy DC or admin workstation."
    }

    # --- 1.3 Locate a healthy DC to perform all operations against ------------
    # Every AD call below pins -Server to this DC so we never bind to the stale
    # one and all reads/writes hit a single consistent replica.
    try {
        $discoverParams = @{ Writable = $true; Service = 'ADWS'; ErrorAction = 'Stop' }
        if ($DomainName) { $discoverParams['DomainName'] = $DomainName }
        $discovered          = Get-ADDomainController -Discover @discoverParams
        $script:TargetServer = [string]($discovered.HostName | Select-Object -First 1)
    }
    catch {
        Stop-Fatal "Could not discover a writable domain controller$(if ($DomainName) { " for domain '$DomainName'" }): $($_.Exception.Message)"
    }

    if (($script:TargetServer -split '\.')[0] -ieq $StaleDCShort) {
        # Discovery handed us the stale DC - find any other writable DC instead.
        $alternate = Get-ADDomainController -Filter * -Server $script:TargetServer |
                         Where-Object { $_.Name -ine $StaleDCShort -and $_.IsReadOnly -eq $false } |
                         Select-Object -First 1
        if (-not $alternate) { Stop-Fatal "No healthy writable DC other than '$StaleDCShort' could be located." }
        $script:TargetServer = $alternate.HostName
    }
    Write-Log "Using healthy DC for all operations: $script:TargetServer" 'OK'

    # --- 1.4 Resolve domain/forest context ------------------------------------
    $domain = Get-ADDomain -Server $script:TargetServer
    $forest = Get-ADForest -Server $script:TargetServer
    if (-not $DomainName) {
        $DomainName = $domain.DNSRoot
        Write-Log "Domain not specified; using discovered domain: $DomainName"
    }
    $domainDN = $domain.DistinguishedName
    $configNC = (Get-ADRootDSE -Server $script:TargetServer).configurationNamingContext

    # Build the FQDN we will use for reachability and DNS matching. If the
    # operator passed an FQDN, honour it; otherwise compose it from the domain.
    if ($StaleDCName -like '*.*') { $StaleDCFqdn = $StaleDCName.ToLower() }
    else                          { $StaleDCFqdn = ("$StaleDCShort.$DomainName").ToLower() }
    Write-Log "Domain: $DomainName | Forest: $($forest.RootDomain) | Stale DC FQDN: $StaleDCFqdn"

    # --- 1.5 Privilege check ---------------------------------------------------
    # Metadata cleanup deletes objects in the domain AND configuration naming
    # contexts; that normally requires Domain Admins (and Enterprise Admins in
    # some delegation models). Warn-and-stop rather than fail halfway through.
    $identity  = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)

    if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Log 'Session is not elevated. AD operations may still work, but log/report paths under ProgramData may not be writable.' 'WARN'
    }

    $isDomainAdmin = $false
    $isEnterpriseAdmin = $false
    try {
        $daSid = New-Object System.Security.Principal.SecurityIdentifier("$($domain.DomainSID.Value)-512")
        $isDomainAdmin = $principal.IsInRole($daSid)
        $rootDomainSid = (Get-ADDomain -Identity $forest.RootDomain -Server $script:TargetServer).DomainSID.Value
        $eaSid = New-Object System.Security.Principal.SecurityIdentifier("$rootDomainSid-519")
        $isEnterpriseAdmin = $principal.IsInRole($eaSid)
    }
    catch {
        Write-Log "Could not fully evaluate group membership: $($_.Exception.Message)" 'WARN'
    }

    if ($isDomainAdmin -or $isEnterpriseAdmin) {
        Write-Log ("Privilege check passed (Domain Admins: {0}, Enterprise Admins: {1})." -f $isDomainAdmin, $isEnterpriseAdmin) 'OK'
    }
    elseif ($Force) {
        Write-Log 'Operator is not in Domain Admins/Enterprise Admins. Continuing because -Force was specified (delegated rights assumed).' 'WARN'
    }
    else {
        Stop-Fatal ('Current user does not appear to be a member of Domain Admins or Enterprise Admins. ' +
                    'Deletions in the configuration partition will very likely fail. Re-run as a privileged ' +
                    'account, or use -Force if you hold equivalent delegated rights.')
    }

    # --- 1.6 The stale DC must NOT be reachable --------------------------------
    # A live LDAP answer means a functioning DC (or another machine that has
    # taken its name) - scrubbing its metadata would be destructive. Hard stop.
    Write-Log "Checking reachability of $StaleDCFqdn (this can take a few seconds)..."
    $ldapAlive = Test-TcpPort -ComputerName $StaleDCFqdn -Port 389
    if (-not $ldapAlive) { $ldapAlive = Test-TcpPort -ComputerName $StaleDCShort -Port 389 }
    if ($ldapAlive) {
        Stop-Fatal ("'$StaleDCFqdn' is ANSWERING on LDAP (TCP 389). It appears to be a live domain " +
                    "controller. Demote it properly (Uninstall-ADDSDomainController) instead of scrubbing " +
                    "its metadata. This check cannot be overridden with -Force.")
    }

    $pingAlive = $false
    try { $pingAlive = Test-Connection -ComputerName $StaleDCFqdn -Count 2 -Quiet -ErrorAction SilentlyContinue } catch { }
    $smbAlive = Test-TcpPort -ComputerName $StaleDCFqdn -Port 445
    if ($pingAlive -or $smbAlive) {
        if ($Force) {
            Write-Log ("'$StaleDCFqdn' answers ping/SMB but not LDAP. Continuing because -Force was " +
                       'specified - verify this is not IP/name reuse by another machine.') 'WARN'
        }
        else {
            Stop-Fatal ("'$StaleDCFqdn' responds to ping or SMB (TCP 445) although LDAP is down. This can " +
                        'mean its IP address or name has been reused by another machine, or the DC is only ' +
                        'partially down. Investigate first; re-run with -Force only when you are certain ' +
                        'the DC is permanently gone.')
        }
    }
    else {
        Write-Log "'$StaleDCFqdn' is unreachable (no LDAP, no ping, no SMB) - consistent with a dead DC." 'OK'
    }

    # --- 1.7 FSMO role check ----------------------------------------------------
    # Never delete the metadata of a FSMO role holder. Roles must be seized to
    # a healthy DC first; this is deliberately not automated here.
    $fsmoRoles = [ordered]@{
        'Schema Master'         = $forest.SchemaMaster
        'Domain Naming Master'  = $forest.DomainNamingMaster
        'PDC Emulator'          = $domain.PDCEmulator
        'RID Master'            = $domain.RIDMaster
        'Infrastructure Master' = $domain.InfrastructureMaster
    }
    $heldRoles = @()
    foreach ($role in $fsmoRoles.GetEnumerator()) {
        if ([string]::IsNullOrEmpty([string]$role.Value)) {
            Write-Log "FSMO role '$($role.Key)' has NO current holder recorded - the forest/domain may already be degraded. Investigate before continuing." 'WARN'
        }
        elseif ((([string]$role.Value) -split '\.')[0] -ieq $StaleDCShort) {
            $heldRoles += $role.Key
        }
    }
    if ($heldRoles.Count -gt 0) {
        Stop-Fatal (("'{0}' still holds FSMO role(s): {1}. Seize them to a healthy DC first, e.g.: " +
                     "Move-ADDirectoryServerOperationMasterRole -Identity <HealthyDC> -OperationMasterRole {2} -Force " +
                     "- then re-run this script. This check cannot be overridden with -Force.") -f
                     $StaleDCShort, ($heldRoles -join ', '), (($heldRoles -replace ' ', '') -join ','))
    }
    Write-Log 'FSMO check passed: stale DC holds no operations master roles.' 'OK'

    # --- 1.8 Never remove the last DC of the domain -----------------------------
    $allDCs   = @(Get-ADDomainController -Filter * -Server $script:TargetServer)
    $otherDCs = @($allDCs | Where-Object { $_.Name -ine $StaleDCShort })
    if ($otherDCs.Count -eq 0) {
        Stop-Fatal "'$StaleDCShort' is the only domain controller known in '$DomainName'. Removing its metadata would orphan the domain. This check cannot be overridden."
    }
    Write-Log ("Domain has {0} other DC(s): {1}" -f $otherDCs.Count, (($otherDCs | ForEach-Object { $_.Name }) -join ', ')) 'OK'

    #endregion

    #region ================= Phase 2: Discovery ("before" report) =============

    Write-Log '--- Phase 2: discovering stale metadata ---' 'ACTION'
    $escShort = ConvertTo-LdapFilterValue -Value $StaleDCShort

    # --- 2.1 Server object(s) in AD Sites and Services --------------------------
    # CN=<DC>,CN=Servers,CN=<Site>,CN=Sites,CN=Configuration,...
    $sitesBase = "CN=Sites,$configNC"
    if ($SiteName) {
        $siteDN = "CN=$SiteName,$sitesBase"
        try   { $null = Get-ADObject -Identity $siteDN -Server $script:TargetServer }
        catch { Stop-Fatal "Site '$SiteName' was not found at '$siteDN'. Check -SiteName." }
        $serverSearchBase = $siteDN
    }
    else {
        $serverSearchBase = $sitesBase
    }

    $serverObjects = @(Get-ADObject -SearchBase $serverSearchBase -SearchScope Subtree `
                                    -LDAPFilter "(&(objectClass=server)(cn=$escShort))" `
                                    -Server $script:TargetServer)
    if ($serverObjects.Count -gt 1 -and -not $SiteName) {
        $dnList = ($serverObjects | ForEach-Object { $_.DistinguishedName }) -join '; '
        Stop-Fatal "Multiple server objects named '$StaleDCShort' were found ($dnList). Re-run with -SiteName to disambiguate."
    }
    $serverObject  = $serverObjects | Select-Object -First 1
    $serverFinding = $null
    $ntdsFinding   = $null
    $ntdsDsa       = $null

    if ($serverObject) {
        $serverFinding = New-Finding -Category 'Sites and Services' -ObjectType 'server' `
                                     -Name $StaleDCShort -Identity $serverObject.DistinguishedName `
                                     -Details 'Server object in the configuration partition'
        Write-Log "Found server object: $($serverObject.DistinguishedName)"

        # --- 2.2 NTDS Settings object (nTDSDSA) under the server object --------
        $ntdsDsa = Get-ADObject -SearchBase $serverObject.DistinguishedName -SearchScope OneLevel `
                                -LDAPFilter '(objectClass=nTDSDSA)' -Server $script:TargetServer |
                       Select-Object -First 1
        if ($ntdsDsa) {
            $ntdsFinding = New-Finding -Category 'Sites and Services' -ObjectType 'nTDSDSA (NTDS Settings)' `
                                       -Name 'NTDS Settings' -Identity $ntdsDsa.DistinguishedName `
                                       -Details 'Directory System Agent object - its presence marks the server as a DC'
            Write-Log "Found NTDS Settings object: $($ntdsDsa.DistinguishedName)"
        }
        else {
            New-Finding -Category 'Sites and Services' -ObjectType 'nTDSDSA (NTDS Settings)' `
                        -Name 'NTDS Settings' -Status 'NotFound' `
                        -Details 'No NTDS Settings object under the server object (may already be cleaned)' | Out-Null
            Write-Log 'No NTDS Settings object found under the server object (may already be cleaned).'
        }
    }
    else {
        New-Finding -Category 'Sites and Services' -ObjectType 'server' -Name $StaleDCShort `
                    -Status 'NotFound' -Details 'No server object found in any site (may already be cleaned)' | Out-Null
        Write-Log "No server object named '$StaleDCShort' found under $serverSearchBase."
    }

    # --- 2.3 Replication connections on OTHER DCs referencing the stale DC ------
    # Inbound nTDSConnection objects whose fromServer points at the stale DC's
    # NTDS Settings object. The KCC normally prunes these, but not always.
    $connectionFindings = @()
    if ($ntdsDsa) {
        $escNtdsDn   = ConvertTo-LdapFilterValue -Value $ntdsDsa.DistinguishedName
        $connections = @(Get-ADObject -SearchBase $sitesBase -SearchScope Subtree `
                                      -LDAPFilter "(&(objectClass=nTDSConnection)(fromServer=$escNtdsDn))" `
                                      -Server $script:TargetServer)
        foreach ($conn in $connections) {
            $connectionFindings += New-Finding -Category 'Replication' -ObjectType 'nTDSConnection' `
                                               -Name $conn.Name -Identity $conn.DistinguishedName `
                                               -Details 'Inbound replication connection on another DC that sources from the stale DC'
            Write-Log "Found replication connection referencing stale DC: $($conn.DistinguishedName)"
        }
        if ($connections.Count -eq 0) {
            New-Finding -Category 'Replication' -ObjectType 'nTDSConnection' -Name 'None' `
                        -Status 'NotFound' -Details 'No connection objects reference the stale DC' | Out-Null
            Write-Log 'No replication connection objects reference the stale DC.'
        }
    }

    # --- 2.4 The DC computer account in the domain partition --------------------
    $computerFinding = $null
    $staleComputer = Get-ADComputer -LDAPFilter "(sAMAccountName=$escShort`$)" -SearchBase $domainDN `
                                    -Properties userAccountControl, primaryGroupID, distinguishedName `
                                    -Server $script:TargetServer | Select-Object -First 1
    if ($staleComputer) {
        # SERVER_TRUST_ACCOUNT (0x2000) or primary group 516 (DCs) / 521 (RODCs)
        # marks a genuine DC account. Anything else could be a name collision -
        # flag it for manual review instead of deleting it.
        $looksLikeDC = (($staleComputer.userAccountControl -band 0x2000) -ne 0) -or
                       ($staleComputer.primaryGroupID -in 516, 521)
        if ($looksLikeDC) {
            $computerFinding = New-Finding -Category 'Domain Partition' -ObjectType 'computer (DC account)' `
                                           -Name $staleComputer.Name -Identity $staleComputer.DistinguishedName `
                                           -Details 'Domain controller computer account (SERVER_TRUST_ACCOUNT / DC primary group)'
            Write-Log "Found DC computer account: $($staleComputer.DistinguishedName)"
        }
        else {
            New-Finding -Category 'Domain Partition' -ObjectType 'computer' `
                        -Name $staleComputer.Name -Identity $staleComputer.DistinguishedName `
                        -Status 'ManualReview' `
                        -Details ('Computer account exists but does NOT look like a DC account ' +
                                  '(no SERVER_TRUST_ACCOUNT flag, primary group not 516/521). Possible name ' +
                                  'collision - NOT deleting. Verify and remove manually if appropriate.') | Out-Null
            Write-Log "Computer account '$($staleComputer.DistinguishedName)' does not look like a DC account - flagged for MANUAL review, will not delete." 'WARN'
        }
    }
    else {
        New-Finding -Category 'Domain Partition' -ObjectType 'computer (DC account)' -Name $StaleDCShort `
                    -Status 'NotFound' -Details 'No computer account found (may already be cleaned)' | Out-Null
        Write-Log "No computer account named '$StaleDCShort' found in the domain."
    }

    # --- 2.5 Legacy FRS SYSVOL member object -------------------------------------
    $frsFinding = $null
    $frsBase = "CN=Domain System Volume (SYSVOL share),CN=File Replication Service,CN=System,$domainDN"
    try {
        $frsMember = Get-ADObject -SearchBase $frsBase -SearchScope Subtree `
                                  -LDAPFilter "(&(objectClass=nTFRSMember)(cn=$escShort))" `
                                  -Server $script:TargetServer | Select-Object -First 1
        if ($frsMember) {
            $frsFinding = New-Finding -Category 'SYSVOL Replication' -ObjectType 'nTFRSMember (FRS)' `
                                      -Name $frsMember.Name -Identity $frsMember.DistinguishedName `
                                      -Details 'Legacy FRS SYSVOL replica set membership'
            Write-Log "Found legacy FRS member object: $($frsMember.DistinguishedName)"
        }
    }
    catch {
        # The FRS container does not exist in domains that were born on / fully
        # migrated to DFSR - that is normal.
        Write-Log 'No legacy FRS SYSVOL container present (normal for DFSR-based domains).'
    }

    # --- 2.6 DFSR SYSVOL member object -------------------------------------------
    $dfsrFinding = $null
    $dfsrBase = "CN=Topology,CN=Domain System Volume,CN=DFSR-GlobalSettings,CN=System,$domainDN"
    try {
        $dfsrMember = Get-ADObject -SearchBase $dfsrBase -SearchScope Subtree `
                                   -LDAPFilter "(&(objectClass=msDFSR-Member)(cn=$escShort))" `
                                   -Server $script:TargetServer | Select-Object -First 1
        if ($dfsrMember) {
            $dfsrFinding = New-Finding -Category 'SYSVOL Replication' -ObjectType 'msDFSR-Member (DFSR)' `
                                       -Name $dfsrMember.Name -Identity $dfsrMember.DistinguishedName `
                                       -Details 'DFSR SYSVOL replication group membership'
            Write-Log "Found DFSR member object: $($dfsrMember.DistinguishedName)"
        }
    }
    catch {
        Write-Log 'No DFSR SYSVOL topology container present (normal for FRS-based domains).'
    }

    # --- 2.7 DNS records (optional) -----------------------------------------------
    # Records are matched strictly by the stale DC's name/FQDN, and by its IP
    # only for the well-known auto-registered names (@, gc, DomainDnsZones,
    # ForestDnsZones). Anything ambiguous is flagged for manual review.
    $script:DnsServer = $script:TargetServer
    $staleIPs = @()
    if ($CleanupDNS) {
        Write-Log "Scanning DNS on '$script:DnsServer' for records referencing the stale DC..."
        $zonesToScan = @()
        foreach ($zoneName in @($DomainName, "_msdcs.$($forest.RootDomain)") | Select-Object -Unique) {
            try {
                $null = Get-DnsServerZone -Name $zoneName -ComputerName $script:DnsServer -ErrorAction Stop
                $zonesToScan += $zoneName
            }
            catch {
                Write-Log "DNS zone '$zoneName' not found on '$script:DnsServer' - skipping. Check other DNS servers manually if this zone exists elsewhere." 'WARN'
                New-Finding -Category 'DNS' -ObjectType 'zone' -Name $zoneName -Zone $zoneName `
                            -Status 'ManualReview' -Details "Zone not hosted on $script:DnsServer - verify and clean manually where it is hosted" | Out-Null
            }
        }

        # Pass 1: name-based matches (safe - they unambiguously belong to the DC).
        $allRecords = @()
        foreach ($zoneName in $zonesToScan) {
            try {
                Get-DnsServerResourceRecord -ZoneName $zoneName -ComputerName $script:DnsServer -ErrorAction Stop |
                    ForEach-Object { $allRecords += [pscustomobject]@{ Zone = $zoneName; Record = $_ } }
            }
            catch {
                Write-Log "Could not enumerate records in zone '$zoneName': $($_.Exception.Message)" 'ERROR'
                $script:ErrorCount++
            }
        }

        foreach ($entry in $allRecords) {
            $rec = $entry.Record
            $matchDetail = $null
            switch ($rec.RecordType) {
                'A' {
                    if ($rec.HostName -ieq $StaleDCShort -or $rec.HostName.TrimEnd('.') -ieq $StaleDCFqdn) {
                        $matchDetail = 'Host (A) record registered by the stale DC'
                        $staleIPs += $rec.RecordData.IPv4Address.IPAddressToString
                    }
                }
                'AAAA' {
                    if ($rec.HostName -ieq $StaleDCShort -or $rec.HostName.TrimEnd('.') -ieq $StaleDCFqdn) {
                        $matchDetail = 'Host (AAAA) record registered by the stale DC'
                        $staleIPs += $rec.RecordData.IPv6Address.IPAddressToString
                    }
                }
                'CNAME' {
                    if ($rec.RecordData.HostNameAlias.TrimEnd('.') -ieq $StaleDCFqdn) {
                        $matchDetail = 'CNAME alias (DSA GUID record in _msdcs) pointing at the stale DC'
                    }
                }
                'SRV' {
                    if ($rec.RecordData.DomainName.TrimEnd('.') -ieq $StaleDCFqdn) {
                        $matchDetail = 'SRV locator record targeting the stale DC'
                    }
                }
                'NS' {
                    if ($rec.RecordData.NameServer.TrimEnd('.') -ieq $StaleDCFqdn) {
                        $matchDetail = 'NS record naming the stale DC as a name server'
                    }
                }
            }
            if ($matchDetail) {
                New-Finding -Category 'DNS' -ObjectType $rec.RecordType -Name $rec.HostName `
                            -Zone $entry.Zone -Details $matchDetail -DnsRecord $rec | Out-Null
                Write-Log "Found DNS record: [$($rec.RecordType)] '$($rec.HostName)' in zone '$($entry.Zone)' ($matchDetail)"
            }
        }

        # Pass 2: well-known auto-registered names carrying the stale DC's IP.
        # These are only safe to match once we know the DC's IP from pass 1.
        $staleIPs = @($staleIPs | Select-Object -Unique)
        if ($staleIPs.Count -gt 0) {
            $wellKnownHosts = @('@', 'gc', 'DomainDnsZones', 'ForestDnsZones')
            foreach ($entry in $allRecords) {
                $rec = $entry.Record
                if ($rec.RecordType -notin @('A', 'AAAA')) { continue }
                if ($rec.HostName -notin $wellKnownHosts)  { continue }
                $ip = if ($rec.RecordType -eq 'A') { $rec.RecordData.IPv4Address.IPAddressToString }
                      else                         { $rec.RecordData.IPv6Address.IPAddressToString }
                if ($ip -in $staleIPs) {
                    New-Finding -Category 'DNS' -ObjectType $rec.RecordType -Name $rec.HostName `
                                -Zone $entry.Zone -DnsRecord $rec `
                                -Details "Well-known record '$($rec.HostName)' carrying the stale DC's IP $ip" | Out-Null
                    Write-Log "Found DNS record: [$($rec.RecordType)] '$($rec.HostName)' in zone '$($entry.Zone)' carries stale IP $ip"
                }
            }
        }
        else {
            New-Finding -Category 'DNS' -ObjectType 'A/AAAA' -Name '@ / gc / DomainDnsZones / ForestDnsZones' `
                        -Status 'ManualReview' `
                        -Details ('The stale DC''s IP address could not be determined from its host records, so ' +
                                  'domain-apex and gc records could not be matched safely. Review them manually ' +
                                  'for entries pointing at the dead DC''s old IP.') | Out-Null
            Write-Log 'Stale DC IP unknown - apex/gc DNS records flagged for MANUAL review only.' 'WARN'
        }
    }
    else {
        Write-Log 'DNS cleanup not requested (-CleanupDNS omitted). Remember to review DNS manually.' 'WARN'
        New-Finding -Category 'DNS' -ObjectType 'n/a' -Name 'DNS not scanned' -Status 'ManualReview' `
                    -Details 'Run again with -CleanupDNS, or manually remove A/AAAA, CNAME (_msdcs GUID), SRV and NS records referencing the stale DC' | Out-Null
    }

    # --- 2.8 Export the "before" report and show a summary -------------------------
    $script:Findings | Select-Object $reportColumns |
        Export-Csv -Path $beforeCsv -NoTypeInformation -Encoding UTF8
    Write-Log "Before report exported: $beforeCsv" 'OK'

    $actionable = @($script:Findings | Where-Object { $_.Status -eq 'Detected' })
    Write-Host ''
    Write-Host '================ DISCOVERY SUMMARY ================' -ForegroundColor Cyan
    $script:Findings |
        Format-Table -Property Category, ObjectType, Name, Status -AutoSize |
        Out-String | Write-Host
    Write-Host ("Items eligible for removal: {0}" -f $actionable.Count) -ForegroundColor Cyan
    Write-Host '===================================================' -ForegroundColor Cyan
    Write-Host ''

    if ($actionable.Count -eq 0) {
        Write-Log 'Nothing eligible for removal was found. Review any ManualReview items above; no changes made.' 'OK'
        return
    }

    #endregion

    #region ================= Phase 3: Removal =================================

    # Final gate before any destructive work. Skipped for -WhatIf (nothing will
    # be deleted anyway) and for -Force (explicitly unattended).
    if (-not $WhatIfPreference -and -not $Force) {
        $gateMessage = ("You are about to remove {0} metadata item(s) for stale DC '{1}' in domain '{2}'. " +
                        "The Before report is at: {3}") -f $actionable.Count, $StaleDCShort, $DomainName, $beforeCsv
        if (-not $PSCmdlet.ShouldContinue($gateMessage, "Proceed with metadata cleanup for '$StaleDCShort'?")) {
            Write-Log 'Operator declined the final confirmation gate. No changes made.' 'WARN'
            return
        }
    }

    Write-Log '--- Phase 3: removing stale metadata ---' 'ACTION'

    # Removal order matters:
    #   1. Connection objects on other DCs that reference the stale DC
    #      (so no object holds a dangling fromServer once the DSA is gone).
    #   2. The NTDS Settings (nTDSDSA) object - this is the actual "metadata
    #      cleanup"; deleting it de-registers the machine as a DC.
    #   3. The server object in Sites and Services (recursively, for any
    #      remaining children).
    #   4. The DC computer account (recursively - RID Set, DFSR-LocalSettings
    #      and SYSVOL subscription children live underneath it).
    #   5. FRS / DFSR SYSVOL membership objects.
    foreach ($connFinding in $connectionFindings) {
        Remove-StaleADObject -Finding $connFinding
    }
    if ($ntdsFinding)     { Remove-StaleADObject -Finding $ntdsFinding -Recursive }
    if ($serverFinding)   { Remove-StaleADObject -Finding $serverFinding -Recursive }
    if ($computerFinding) { Remove-StaleADObject -Finding $computerFinding -Recursive }
    if ($frsFinding)      { Remove-StaleADObject -Finding $frsFinding -Recursive }
    if ($dfsrFinding)     { Remove-StaleADObject -Finding $dfsrFinding -Recursive }

    # DNS records last - directory metadata is the primary cleanup; DNS is
    # cosmetic by comparison and easiest to re-check.
    foreach ($dnsFinding in @($script:Findings | Where-Object { $_.Category -eq 'DNS' -and $_.Status -eq 'Detected' })) {
        Remove-StaleDnsRecord -Finding $dnsFinding
    }

    #endregion

    #region ================= Phase 4: Post-run guidance =======================

    Write-Log '--- Phase 4: post-cleanup guidance ---' 'ACTION'
    Write-Log 'Recommended verification steps (run from a healthy DC):'
    Write-Log '  1. repadmin /replsummary          - overall replication health'
    Write-Log '  2. repadmin /showrepl * /errorsonly - remaining replication errors'
    Write-Log "  3. dcdiag /q                       - directory service health (quiet: errors only)"
    Write-Log "  4. dcdiag /test:dns /q             - DNS locator health"
    Write-Log "  5. repadmin /kcc *                 - force KCC to recalculate the topology"
    Write-Log "  6. nltest /dsgetdc:$DomainName     - confirm DC locator no longer returns '$StaleDCShort'"
    Write-Log 'Also review: DHCP scope option 006 (DNS servers), client static DNS settings,'
    Write-Log 'monitoring/backup systems, and any application configs that referenced the dead DC.'

    #endregion
}
catch {
    $script:ErrorCount++
    Write-Log "FATAL: $($_.Exception.Message)" 'ERROR'
    throw
}
finally {
    # Always export the "after" report so even an aborted run is auditable.
    if ($script:Findings.Count -gt 0) {
        try {
            $script:Findings | Select-Object $reportColumns |
                Export-Csv -Path $afterCsv -NoTypeInformation -Encoding UTF8
            Write-Log "After report exported: $afterCsv" 'OK'
        }
        catch {
            Write-Log "Could not export after report: $($_.Exception.Message)" 'ERROR'
        }
    }
    Write-Log ("=== Cleanup-ADMetadata finished. Errors: {0}. Log: {1} ===" -f $script:ErrorCount, $script:LogFile) `
              -Level $(if ($script:ErrorCount -gt 0) { 'WARN' } else { 'OK' })
}
