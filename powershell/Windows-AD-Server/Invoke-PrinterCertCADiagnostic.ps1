<#
.SYNOPSIS
    Read-only diagnostic for a Windows Server Issuing CA: checks DNS, connectivity,
    CA health, and certificate-chain reachability for a printer hostname.
.DESCRIPTION
    Runs six diagnostic sections against a target printer hostname (default:
    b-4024.nomma.tech) from the Issuing CA server. Does NOT modify any
    configuration -- DNS, AD CS, firewall, certificates, or network settings are
    untouched. Every check produces a PASS, WARN, or FAIL result and an
    actionable next step.

    Sections:
      1. DNS resolution  (A / AAAA / CNAME via configured servers)
      2. Connectivity     (ICMP + TCP ports 80, 443, 515, 631, 9100)
      3. CA configuration (CertSvc service, CA name, type, config)
      4. CA certificate   (validity, CRL & AIA URL reachability)
      5. DNS client       (server list, NRPT, suffix search order)
      6. Route table      (matching routes for the printer subnet)

    Requires: Windows PowerShell 5.1, Administrator (to reach certutil -CAInfo).
    No extra modules needed.
.PARAMETER PrinterHost
    Fully-qualified hostname of the printer. Default: b-4024.nomma.tech
.PARAMETER OutputPath
    Optional file path for a plain-text transcript. If omitted the transcript is
    written to $env:TEMP\PrinterCertCADiagnostic_<timestamp>.log
.PARAMETER IcmpCount
    Number of pings to send. Default: 4
.PARAMETER TcpTimeoutMs
    TCP connect timeout in milliseconds. Default: 3000
.EXAMPLE
    .\Invoke-PrinterCertCADiagnostic.ps1

    Uses the default printer host b-4024.nomma.tech and writes output to
    $env:TEMP.
.EXAMPLE
    .\Invoke-PrinterCertCADiagnostic.ps1 -PrinterHost "floor2-printer.school.internal"
.EXAMPLE
    .\Invoke-PrinterCertCADiagnostic.ps1 -OutputPath "C:\Logs\ca-diag.log"
.NOTES
    Author:  NOMMA IT (Elliot Alderson agent)
    Version: 1.0
    Date:    2026-07-14

    === HOW TO RUN ===
    1. Copy this script to the Windows Server hosting the Issuing CA.
    2. Open PowerShell ISE or an elevated PowerShell console (Run as Administrator).
    3. If execution policy blocks it:
         PowerShell -ExecutionPolicy Bypass -File .\Invoke-PrinterCertCADiagnostic.ps1
    4. Default run (no arguments):
         .\Invoke-PrinterCertCADiagnostic.ps1
    5. Custom printer host:
         .\Invoke-PrinterCertCADiagnostic.ps1 -PrinterHost "host.domain.tld"
    6. Review the on-screen PASS/WARN/FAIL summary and any *.log transcript.
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$PrinterHost = 'b-4024.nomma.tech',

    [Parameter(Position = 1)]
    [string]$OutputPath,

    [ValidateRange(1, 30)]
    [int]$IcmpCount = 4,

    [ValidateRange(500, 30000)]
    [int]$TcpTimeoutMs = 3000
)

# ── Transcript ───────────────────────────────────────────────────────────────
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if (-not $OutputPath) {
    $OutputPath = Join-Path $env:TEMP "PrinterCertCADiagnostic_${timestamp}.log"
}
try {
    Start-Transcript -Path $OutputPath -Force -ErrorAction Stop | Out-Null
}
catch {
    Write-Warning "Could not start transcript at $OutputPath : $_"
}

# ── Banner ───────────────────────────────────────────────────────────────────
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " NOMMA IT - Printer Certificate CA Diagnostic"               -ForegroundColor Cyan
Write-Host " Target Printer  : $PrinterHost"                              -ForegroundColor Cyan
Write-Host " Local Machine    : $env:COMPUTERNAME"                        -ForegroundColor Cyan
Write-Host " Started At      : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Cyan
Write-Host " Output Log      : $OutputPath"                               -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# ══════════════════════════════════════════════════════════════════════════════
# Helper Functions
# ══════════════════════════════════════════════════════════════════════════════

$Results = [System.Collections.ArrayList]::new()

function Add-Result {
    param(
        [string]$Section,
        [string]$Check,
        [ValidateSet('PASS','WARN','FAIL','INFO')]
        [string]$Verdict,
        [string]$Detail,
        [string]$NextAction
    )
    [void]$Results.Add([PSCustomObject]@{
        Timestamp  = Get-Date -Format 'HH:mm:ss'
        Section    = $Section
        Check      = $Check
        Verdict    = $Verdict
        Detail     = $Detail
        NextAction = $NextAction
    })

    $color = switch ($Verdict) {
        'PASS' { 'Green'  }
        'WARN' { 'Yellow' }
        'FAIL' { 'Red'    }
        default { 'White' }
    }
    Write-Host ("{0} [{1}] {2} : {3}" -f $Verdict.PadRight(4), $Section, $Check, $Detail) -ForegroundColor $color
    if ($NextAction) {
        Write-Host "        → Next: $NextAction" -ForegroundColor DarkGray
    }
}

function Test-TcpPort {
    param([string]$HostName, [int]$Port, [int]$TimeoutMs)
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $ar     = $client.BeginConnect($HostName, $Port, $null, $null)
        $ok     = $ar.AsyncWaitHandle.WaitOne($TimeoutMs)
        if ($ok -and $client.Connected) {
            $client.Close()
            return $true
        }
        $client.Close()
        return $false
    }
    catch {
        return $false
    }
}

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 1 — DNS Resolution
# ══════════════════════════════════════════════════════════════════════════════
Write-Host "────────────────────────────────────────────────────────────" -ForegroundColor DarkCyan
Write-Host " SECTION 1: DNS Resolution for $PrinterHost"                 -ForegroundColor DarkCyan
Write-Host "────────────────────────────────────────────────────────────" -ForegroundColor DarkCyan

$dnsSection = "1-DNS"

# 1a — A record
try {
    $aRecords = [System.Net.Dns]::GetHostEntry($PrinterHost).AddressList |
        Where-Object { $_.AddressFamily -eq 'InterNetwork' }
    if ($aRecords) {
        Add-Result -Section $dnsSection -Check "A record" -Verdict PASS `
            -Detail ("Resolved to: {0}" -f ($aRecords.IPAddressToString -join ', ')) `
            -NextAction "Ping the resolved IP to confirm L2/L3 reachability."
    }
    else {
        Add-Result -Section $dnsSection -Check "A record" -Verdict FAIL `
            -Detail "No IPv4 address returned by GetHostEntry." `
            -NextAction "Check the A record for $PrinterHost in the authoritative DNS zone."
    }
}
catch {
    Add-Result -Section $dnsSection -Check "A record" -Verdict FAIL `
        -Detail ("DNS resolution error: {0}" -f $_.Exception.Message) `
        -NextAction "Verify that $PrinterHost exists in DNS. Check the forward lookup zone."
}

# 1b — AAAA record
try {
    $aaaaRecords = [System.Net.Dns]::GetHostEntry($PrinterHost).AddressList |
        Where-Object { $_.AddressFamily -eq 'InterNetworkV6' }
    if ($aaaaRecords) {
        Add-Result -Section $dnsSection -Check "AAAA record" -Verdict INFO `
            -Detail ("Resolved to: {0}" -f ($aaaaRecords.IPAddressToString -join ', '))
    }
    else {
        Add-Result -Section $dnsSection -Check "AAAA record" -Verdict INFO `
            -Detail "No IPv6 address — expected if IPv6 is not configured for this printer."
    }
}
catch {
    Add-Result -Section $dnsSection -Check "AAAA record" -Verdict INFO `
        -Detail "No AAAA record (skipped after A-record failure)."
}

# 1c — CNAME check (via .NET resolve in reverse)
try {
    $cnameResult = [System.Net.Dns]::GetHostEntry($PrinterHost)
    if ($cnameResult.HostName -ne $PrinterHost) {
        Add-Result -Section $dnsSection -Check "CNAME" -Verdict INFO `
            -Detail ("CNAME chain → {0}" -f $cnameResult.HostName)
    }
    else {
        Add-Result -Section $dnsSection -Check "CNAME" -Verdict PASS `
            -Detail "No CNAME indirection; hostname is the A-record target."
    }
}
catch {
    Add-Result -Section $dnsSection -Check "CNAME" -Verdict INFO `
        -Detail "Could not evaluate CNAME chain (resolution failed)."
}

# 1d — Reverse lookup of the resolved IP
try {
    $ip = ($aRecords | Select-Object -First 1).IPAddressToString
    if ($ip) {
        $reverse = [System.Net.Dns]::GetHostEntry($ip)
        Add-Result -Section $dnsSection -Check "PTR (reverse)" -Verdict INFO `
            -Detail ("{0} → {1}" -f $ip, $reverse.HostName)
    }
}
catch {
    Add-Result -Section $dnsSection -Check "PTR (reverse)" -Verdict WARN `
        -Detail "No PTR record — not critical for cert issuance, but may confuse logging."
}

Write-Host ""

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 2 — Connectivity (ICMP + TCP)
# ══════════════════════════════════════════════════════════════════════════════
Write-Host "────────────────────────────────────────────────────────────" -ForegroundColor DarkCyan
Write-Host " SECTION 2: Connectivity to $PrinterHost"                     -ForegroundColor DarkCyan
Write-Host "────────────────────────────────────────────────────────────" -ForegroundColor DarkCyan

$connSection = "2-Connectivity"

# 2a — ICMP
$pingResult = Test-Connection -ComputerName $PrinterHost -Count $IcmpCount -Quiet -ErrorAction SilentlyContinue
if ($pingResult) {
    Add-Result -Section $connSection -Check "ICMP ping" -Verdict PASS `
        -Detail "Host replied to $IcmpCount pings." `
        -NextAction "ICMP replies confirm Layer 3 reachability."
}
else {
    $pingDetail = Test-Connection -ComputerName $PrinterHost -Count 1 -ErrorAction SilentlyContinue
    if (-not $pingDetail) {
        Add-Result -Section $connSection -Check "ICMP ping" -Verdict WARN `
            -Detail "No ICMP reply — firewall or network ACL may be dropping ICMP." `
            -NextAction "Try a TCP port test. If TCP also fails, check the switch port / VLAN assignment."
    }
    else {
        Add-Result -Section $connSection -Check "ICMP ping" -Verdict WARN `
            -Detail ("Packet loss: {0}/{1} replies" -f ($pingDetail | Where-Object { $_.StatusCode -eq 0 }).Count, $IcmpCount) `
            -NextAction "Intermittent connectivity — check switch port errors."
    }
}

# 2b — TCP ports
$tcpPorts = @(
    @{ Port=80;   Service="HTTP (web interface)" },
    @{ Port=443;  Service="HTTPS (secure web / IPPS)" },
    @{ Port=515;  Service="LPR/LPD (Line Printer Daemon)" },
    @{ Port=631;  Service="IPP (Internet Printing Protocol)" },
    @{ Port=9100; Service="Raw/JetDirect (standard print)" }
)

foreach ($entry in $tcpPorts) {
    $port = $entry.Port
    $svc  = $entry.Service
    $open = Test-TcpPort -HostName $PrinterHost -Port $port -TimeoutMs $TcpTimeoutMs
    if ($open) {
        Add-Result -Section $connSection -Check "TCP $port ($svc)" -Verdict PASS `
            -Detail "Port $port accepted connection."
    }
    else {
        # Distinguish FAIL from expected-closed
        if ($port -in @(80, 443, 9100)) {
            Add-Result -Section $connSection -Check "TCP $port ($svc)" -Verdict FAIL `
                -Detail "Port $port refused or timed out." `
                -NextAction "Check printer web UI (HTTP/HTTPS) settings and that raw port 9100 is enabled."
        }
        else {
            Add-Result -Section $connSection -Check "TCP $port ($svc)" -Verdict WARN `
                -Detail "Port $port is closed — may be disabled by default on this printer model."
        }
    }
}

Write-Host ""

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 3 — Local CA Configuration & CertSvc Status
# ══════════════════════════════════════════════════════════════════════════════
Write-Host "────────────────────────────────────────────────────────────" -ForegroundColor DarkCyan
Write-Host " SECTION 3: Local CA Configuration"                          -ForegroundColor DarkCyan
Write-Host "────────────────────────────────────────────────────────────" -ForegroundColor DarkCyan

$caSection = "3-CA-Config"

# 3a — CertSvc service status
$certSvc = Get-Service -Name CertSvc -ErrorAction SilentlyContinue
if ($certSvc -and $certSvc.Status -eq 'Running') {
    Add-Result -Section $caSection -Check "CertSvc service" -Verdict PASS `
        -Detail "Active Directory Certificate Services is Running." `
        -NextAction "Proceed to inspect CA configuration."
}
elseif ($certSvc) {
    Add-Result -Section $caSection -Check "CertSvc service" -Verdict FAIL `
        -Detail ("CertSvc status is '{0}'" -f $certSvc.Status) `
        -NextAction "Start the AD CS service: Start-Service CertSvc or sc start certsvc"
}
else {
    Add-Result -Section $caSection -Check "CertSvc service" -Verdict FAIL `
        -Detail "CertSvc service not found — is AD CS installed on this server?" `
        -NextAction "Run this script ONLY on the Issuing CA. Verify with: Get-WindowsFeature AD-Certificate"
}

# 3b — CA name and type via certutil (works without ADCS module)
try {
    $caInfo = & certutil -CAInfo 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0) {
        # Extract CA name
        $caNameMatch = [regex]::Match($caInfo, 'CA\s+name\s*:\s*(.+)')
        $caTypeMatch = [regex]::Match($caInfo, 'CA\s+type\s*:\s*(.+)')
        $caName = if ($caNameMatch.Success) { $caNameMatch.Groups[1].Value.Trim() } else { "Unknown" }
        $caType = if ($caTypeMatch.Success) { $caTypeMatch.Groups[1].Value.Trim() } else { "Unknown" }

        Add-Result -Section $caSection -Check "CA identity" -Verdict PASS `
            -Detail ("Name: {0}, Type: {1}" -f $caName, $caType) `
            -NextAction "Confirm this is the Issuing CA (type should be 'Enterprise Subordinate' or 'Enterprise Root')."

        # 3c — CRL distribution point config
        $crlMatch = [regex]::Matches($caInfo, 'CRL\s+Distribution\s+Point\s*\[(\d+)\]\s*:\s*(.+)')
        if ($crlMatch.Count -gt 0) {
            $crlUrls = ($crlMatch | ForEach-Object { $_.Groups[2].Value.Trim() }) -join ' | '
            Add-Result -Section $caSection -Check "CRL publication" -Verdict PASS `
                -Detail ("{0} CDP(s): {1}" -f $crlMatch.Count, $crlUrls) `
                -NextAction "Verify these URLs are reachable from client machines (Section 4 will test from this server)."
        }
        else {
            Add-Result -Section $caSection -Check "CRL publication" -Verdict WARN `
                -Detail "No CRL Distribution Points found in CA Info." `
                -NextAction "Check the CA extension configuration in the Certification Authority MMC."
        }

        # 3d — AIA config
        $aiaMatch = [regex]::Matches($caInfo, 'Authority\s+Information\s+Access\s*\[(\d+)\]\s*:\s*(.+)')
        if ($aiaMatch.Count -gt 0) {
            $aiaUrls = ($aiaMatch | ForEach-Object { $_.Groups[2].Value.Trim() }) -join ' | '
            Add-Result -Section $caSection -Check "AIA publication" -Verdict PASS `
                -Detail ("{0} AIA(s): {1}" -f $aiaMatch.Count, $aiaUrls)
        }
        else {
            Add-Result -Section $caSection -Check "AIA publication" -Verdict WARN `
                -Detail "No AIA URLs found — clients may not be able to build the chain."
        }
    }
    else {
        Add-Result -Section $caSection -Check "certutil -CAInfo" -Verdict FAIL `
            -Detail "certutil -CAInfo returned exit code $LASTEXITCODE" `
            -NextAction "Run certutil -CAInfo manually in an elevated prompt and review errors."
    }
}
catch {
    Add-Result -Section $caSection -Check "certutil -CAInfo" -Verdict FAIL `
        -Detail ("Exception: {0}" -f $_.Exception.Message) `
        -NextAction "Ensure certutil is available and you are running as Administrator."
}

# 3e — AD CS module checks (optional, may not be loaded)
try {
    $caModule = Get-Module -Name ADCSAdministration -ListAvailable -ErrorAction Stop
    if ($caModule) {
        Add-Result -Section $caSection -Check "ADCSAdministration module" -Verdict PASS `
            -Detail ("Module available: {0}" -f $caModule.Version)
    }
    else {
        Add-Result -Section $caSection -Check "ADCSAdministration module" -Verdict INFO `
            -Detail "Module not found; certutil is sufficient for diagnostics."
    }
}
catch {
    # Not critical
}

Write-Host ""

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 4 — CA Certificate Validity & CRL/AIA Reachability
# ══════════════════════════════════════════════════════════════════════════════
Write-Host "────────────────────────────────────────────────────────────" -ForegroundColor DarkCyan
Write-Host " SECTION 4: CA Certificate & CRL/AIA Reachability"           -ForegroundColor DarkCyan
Write-Host "────────────────────────────────────────────────────────────" -ForegroundColor DarkCyan

$certSection = "4-CA-Cert"

# 4a — Retrieve the CA certificate from the local store
try {
    $caCerts = Get-ChildItem -Path Cert:\LocalMachine\CA -ErrorAction Stop |
        Where-Object { $_.Subject -like "*CN=*" }

    if (-not $caCerts) {
        $caCerts = Get-ChildItem -Path Cert:\LocalMachine\Root -ErrorAction SilentlyContinue |
            Where-Object { $_.Subject -like "*CN=*" -and $_.Subject -match 'CA' }
    }

    if ($caCerts) {
        # Pick the most-recently issued CA cert
        $caCert = $caCerts | Sort-Object NotAfter -Descending | Select-Object -First 1

        $now  = Get-Date
        $days = ($caCert.NotAfter - $now).Days
        if ($days -gt 90) {
            Add-Result -Section $certSection -Check "CA cert validity" -Verdict PASS `
                -Detail ("DN: {0}, Expires: {1:yyyy-MM-dd} ({2} days)" -f $caCert.Subject, $caCert.NotAfter, $days)
        }
        elseif ($days -gt 0) {
            Add-Result -Section $certSection -Check "CA cert validity" -Verdict WARN `
                -Detail ("DN: {0}, Expires: {1:yyyy-MM-dd} (ONLY {2} days!)" -f $caCert.Subject, $caCert.NotAfter, $days) `
                -NextAction "Schedule CA certificate renewal — less than 90 days remaining."
        }
        else {
            Add-Result -Section $certSection -Check "CA cert validity" -Verdict FAIL `
                -Detail ("DN: {0}, EXPIRED: {1:yyyy-MM-dd}" -f $caCert.Subject, $caCert.NotAfter) `
                -NextAction "The CA certificate has EXPIRED. Renew it immediately."
        }

        # 4b — Extract CRL Distribution Points from the CA certificate
        $crlExt = $caCert.Extensions | Where-Object { $_.Oid.FriendlyName -eq 'CRL Distribution Points' }
        if ($crlExt) {
            $crlUrls = [regex]::Matches($crlExt.Format($true), 'URL=(.+)') |
                ForEach-Object { $_.Groups[1].Value.Trim() }

            if ($crlUrls) {
                foreach ($url in $crlUrls) {
                    # Normalize: strip ldap:// for reachability tests (we test HTTP only)
                    $httpUrls = $url -split '\|' | Where-Object { $_ -match '^https?://' }
                    if (-not $httpUrls) {
                        Add-Result -Section $certSection -Check "CRL URL ($url)" -Verdict INFO `
                            -Detail "LDAP-only CDP — HTTP reachability cannot be tested from script." `
                            -NextAction "Verify LDAP CDP is accessible from domain clients."
                        continue
                    }
                    foreach ($httpUrl in $httpUrls) {
                        $httpUrl = $httpUrl.Trim()
                        try {
                            $crlReq = Invoke-WebRequest -Uri $httpUrl -Method Head -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop
                            Add-Result -Section $certSection -Check "CRL reachable ($httpUrl)" -Verdict PASS `
                                -Detail ("HTTP {0}, {1} bytes" -f $crlReq.StatusCode, $crlReq.RawContentLength)
                        }
                        catch {
                            Add-Result -Section $certSection -Check "CRL reachable ($httpUrl)" -Verdict FAIL `
                                -Detail ("HTTP request failed: {0}" -f $_.Exception.Message) `
                                -NextAction "Check IIS on the CA, firewall rules, and that the CDP virtual directory exists."
                        }
                    }
                }
            }
        }
        else {
            Add-Result -Section $certSection -Check "CA cert CDP extension" -Verdict WARN `
                -Detail "No CRL Distribution Points extension found on the CA certificate."
        }

        # 4c — Extract AIA from the CA certificate
        $aiaExt = $caCert.Extensions | Where-Object { $_.Oid.FriendlyName -eq 'Authority Information Access' }
        if ($aiaExt) {
            $aiaUrls = [regex]::Matches($aiaExt.Format($true), 'URL=(.+)') |
                ForEach-Object { $_.Groups[1].Value.Trim() }

            if ($aiaUrls) {
                foreach ($url in $aiaUrls) {
                    $httpOnly = $url -split '\|' | Where-Object { $_ -match '^https?://' }
                    if (-not $httpOnly) { continue }
                    foreach ($httpUrl in $httpOnly) {
                        $httpUrl = $httpUrl.Trim()
                        try {
                            $aiaReq = Invoke-WebRequest -Uri $httpUrl -Method Head -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop
                            Add-Result -Section $certSection -Check "AIA reachable ($httpUrl)" -Verdict PASS `
                                -Detail ("HTTP {0}, {1} bytes" -f $aiaReq.StatusCode, $aiaReq.RawContentLength)
                        }
                        catch {
                            Add-Result -Section $certSection -Check "AIA reachable ($httpUrl)" -Verdict FAIL `
                                -Detail ("HTTP request failed: {0}" -f $_.Exception.Message) `
                                -NextAction "Check IIS / OCSP responder on the CA and firewall rules."
                        }
                    }
                }
            }
        }
        else {
            Add-Result -Section $certSection -Check "CA cert AIA extension" -Verdict WARN `
                -Detail "No AIA extension found on CA certificate — chain building may fail for external clients."
        }
    }
    else {
        Add-Result -Section $certSection -Check "CA certificate" -Verdict FAIL `
            -Detail "No CA certificate found in Cert:\LocalMachine\CA or Root." `
            -NextAction "Run certlm.msc and verify the CA certificate is present under Intermediate Certification Authorities."
    }
}
catch {
    Add-Result -Section $certSection -Check "CA cert inspection" -Verdict FAIL `
        -Detail ("Exception: {0}" -f $_.Exception.Message)
}

Write-Host ""

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 5 — DNS Client Configuration
# ══════════════════════════════════════════════════════════════════════════════
Write-Host "────────────────────────────────────────────────────────────" -ForegroundColor DarkCyan
Write-Host " SECTION 5: DNS Client Configuration"                         -ForegroundColor DarkCyan
Write-Host "────────────────────────────────────────────────────────────" -ForegroundColor DarkCyan

$dnsClientSection = "5-DNS-Client"

# 5a — DNS server list
try {
    $dnsServers = Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction Stop |
        Where-Object { $_.ServerAddresses.Count -gt 0 }
    foreach ($adapter in $dnsServers) {
        $nicName = $adapter.InterfaceAlias
        $servers = $adapter.ServerAddresses -join ', '
        Add-Result -Section $dnsClientSection -Check "DNS servers ($nicName)" -Verdict INFO `
            -Detail "Configured: $servers"
    }
    if (-not $dnsServers) {
        Add-Result -Section $dnsClientSection -Check "DNS servers" -Verdict FAIL `
            -Detail "No IPv4 DNS server addresses configured." `
            -NextAction "Set DNS server addresses on the CA's NIC."
    }
}
catch {
    Add-Result -Section $dnsClientSection -Check "DNS servers" -Verdict FAIL `
        -Detail ("Could not query: {0}" -f $_.Exception.Message)
}

# 5b — DNS suffix search list
try {
    $suffixes = (Get-DnsClientGlobalSetting -ErrorAction Stop).SuffixSearchList
    if ($suffixes) {
        Add-Result -Section $dnsClientSection -Check "Suffix search list" -Verdict INFO `
            -Detail ("{0}" -f ($suffixes -join ', '))
    }
    else {
        Add-Result -Section $dnsClientSection -Check "Suffix search list" -Verdict INFO `
            -Detail "No custom suffix search list — default domain suffix used."
    }
}
catch {
    Add-Result -Section $dnsClientSection -Check "Suffix search list" -Verdict INFO `
        -Detail "Could not query suffix search list (non-critical)."
}

# 5c — NRPT (Name Resolution Policy Table — DirectAccess)
try {
    $nrpt = Get-DnsClientNrptPolicy -ErrorAction SilentlyContinue
    if ($nrpt) {
        Add-Result -Section $dnsClientSection -Check "NRPT policies" -Verdict INFO `
            -Detail ("{0} NRPT rule(s) present — may override DNS resolution." -f @($nrpt).Count)
    }
    else {
        Add-Result -Section $dnsClientSection -Check "NRPT policies" -Verdict PASS `
            -Detail "No NRPT policies — standard DNS resolution in effect."
    }
}
catch {
    # Not critical
}

Write-Host ""

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 6 — Route Table Check
# ══════════════════════════════════════════════════════════════════════════════
Write-Host "────────────────────────────────────────────────────────────" -ForegroundColor DarkCyan
Write-Host " SECTION 6: Route Table"                                      -ForegroundColor DarkCyan
Write-Host "────────────────────────────────────────────────────────────" -ForegroundColor DarkCyan

$routeSection = "6-Routes"

# Only attempt if we have a resolved IP from Section 1
$targetIp = ($aRecords | Select-Object -First 1).IPAddressToString
if ($targetIp) {
    try {
        $routes = Get-NetRoute -DestinationPrefix "$targetIp/32" -ErrorAction Stop
        if ($routes) {
            foreach ($route in $routes) {
                Add-Result -Section $routeSection -Check "Route to $targetIp" -Verdict PASS `
                    -Detail ("NextHop: {0}, Interface: {1} ({2}), Metric: {3}" -f `
                        $route.NextHop, $route.InterfaceAlias, $route.InterfaceIndex, $route.RouteMetric)
            }
        }
        else {
            Add-Result -Section $routeSection -Check "Route to $targetIp" -Verdict FAIL `
                -Detail "No route found — the IP may be unreachable from this server." `
                -NextAction "Check that the printer subnet route exists on this server and on upstream routers."
        }
    }
    catch {
        Add-Result -Section $routeSection -Check "Route to $targetIp" -Verdict FAIL `
            -Detail ("Route lookup error: {0}" -f $_.Exception.Message)
    }
}
else {
    Add-Result -Section $routeSection -Check "Route table" -Verdict WARN `
        -Detail "Skipped — printer IP unknown (DNS resolution failed in Section 1)." `
        -NextAction "Resolve DNS first (Section 1), then re-run to populate route checks."
}

# 6b — Default gateway
try {
    $defaultRoute = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
        Sort-Object RouteMetric | Select-Object -First 1
    if ($defaultRoute) {
        Add-Result -Section $routeSection -Check "Default gateway" -Verdict INFO `
            -Detail ("NextHop: {0}, Interface: {1}" -f $defaultRoute.NextHop, $defaultRoute.InterfaceAlias)
    }
}
catch { }

Write-Host ""

# ══════════════════════════════════════════════════════════════════════════════
# SUMMARY
# ══════════════════════════════════════════════════════════════════════════════
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " DIAGNOSTIC SUMMARY"                                         -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

$total   = $Results.Count
$pass    = ($Results | Where-Object Verdict -eq 'PASS').Count
$warn    = ($Results | Where-Object Verdict -eq 'WARN').Count
$fail    = ($Results | Where-Object Verdict -eq 'FAIL').Count
$info    = ($Results | Where-Object Verdict -eq 'INFO').Count

Write-Host ("PASS : {0}" -f $pass) -ForegroundColor Green
Write-Host ("WARN : {0}" -f $warn) -ForegroundColor Yellow
Write-Host ("FAIL : {0}" -f $fail) -ForegroundColor Red
Write-Host ("INFO : {0}" -f $info) -ForegroundColor Gray
Write-Host ("TOTAL: {0}" -f $total) -ForegroundColor White
Write-Host ""

# Actionable next steps table
Write-Host "────────────────────────────────────────────────────────────" -ForegroundColor DarkCyan
Write-Host " PRIORITY ACTIONS (based on FAIL results)"                   -ForegroundColor DarkCyan
Write-Host "────────────────────────────────────────────────────────────" -ForegroundColor DarkCyan

$failedActions = $Results | Where-Object { $_.Verdict -eq 'FAIL' -and $_.NextAction }
if ($failedActions) {
    $i = 1
    foreach ($action in $failedActions) {
        Write-Host ("{0}. [{1}] {2}" -f $i, $action.Check, $action.NextAction) -ForegroundColor Red
        $i++
    }
}
else {
    Write-Host "No FAIL results. Review WARN items for optimisation." -ForegroundColor Green
}

Write-Host ""
Write-Host "────────────────────────────────────────────────────────────" -ForegroundColor DarkCyan
Write-Host " WARNINGS TO REVIEW"                                         -ForegroundColor DarkCyan
Write-Host "────────────────────────────────────────────────────────────" -ForegroundColor DarkCyan

$warnActions = $Results | Where-Object { $_.Verdict -eq 'WARN' -and $_.NextAction }
if ($warnActions) {
    $j = 1
    foreach ($action in $warnActions) {
        Write-Host ("{0}. [{1}] {2}" -f $j, $action.Check, $action.NextAction) -ForegroundColor Yellow
        $j++
    }
}
else {
    Write-Host "No warnings." -ForegroundColor Green
}

Write-Host ""
Write-Host "────────────────────────────────────────────────────────────" -ForegroundColor DarkCyan
Write-Host " INTERPRETATION GUIDE"                                       -ForegroundColor DarkCyan
Write-Host "────────────────────────────────────────────────────────────" -ForegroundColor DarkCyan

Write-Host @"

  If Section 1 (DNS) FAILs:
    → The CA cannot resolve the printer hostname at all.
    → Check the authoritative DNS zone for b-4024.nomma.tech.
    → Confirm the A record points to the correct IP.
    → From a domain controller:  Get-DnsServerResourceRecord -ZoneName nomma.tech -Name b-4024

  If Section 2 (Connectivity) shows TCP 443/9100 FAIL:
    → The printer is unreachable on the ports needed for HTTPS/IPPS or raw printing.
    → Verify the printer's web interface is enabled (HTTP/HTTPS).
    → Check firewall rules between the CA subnet and the printer subnet.
    → Run from the printer subnet to isolate: is it the printer or the network?

  If Section 3 (CA Config) FAILs:
    → CertSvc must be Running. If stopped, start it: Start-Service CertSvc
    → certutil -CAInfo must return zero. Run it manually to see raw errors.

  If Section 4 (CA Cert / CRL / AIA) FAILs:
    → An expired CA certificate blocks ALL issuance. Renew immediately.
    → Unreachable CRL/AIA HTTP URLs: check IIS bindings, firewall, and that the
      CDP/AIA virtual directories are functioning.
    → LDAP-only CDPs: verify LDAP is reachable from the issuing CA and clients.

  If Section 5 (DNS Client) FAILs or shows unexpected servers:
    → The CA may be using an external DNS server that cannot resolve internal
      nomma.tech records. Servers should be internal domain controllers.

  If Section 6 (Routes) FAILs:
    → The CA server has no route to the printer's subnet. Add a static route
      or fix the VLAN trunk between the CA subnet and the printer VLAN.

  CERTIFICATE ISSUANCE CHECKLIST (after this diagnostic passes):
    1. The printer's web server (HTTPS) is reachable on port 443.
    2. The target certificate template has 'Server Authentication' EKU.
    3. The template is published on the Issuing CA.
    4. The printer trusts the Root CA (import Root CA cert to printer).
    5. The certificate request includes the correct SAN (Subject Alternative Name)
       matching the hostname b-4024.nomma.tech.
    6. After issuance, the full chain (Root + Issuing CA + Printer cert) validates.

"@

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Diagnostic complete at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Cyan
Write-Host " Full transcript saved to: $OutputPath"                        -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

Stop-Transcript -ErrorAction SilentlyContinue | Out-Null

# Return the results object for pipeline consumption
return $Results