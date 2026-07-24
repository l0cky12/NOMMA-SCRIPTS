# Install-ZabbixAgent2-PSK.ps1
# Full install of Zabbix Agent 2 on Windows Server 2012 R2+ with PSK encryption.
# Downloads the MSI from cdn.zabbix.com, installs silently, generates a PSK,
# configures TLS/PSK, creates a firewall rule, and outputs the PSK details
# needed to configure the host in the Zabbix frontend.
#
# Examples:
#   .\Install-ZabbixAgent2-PSK.ps1
#   .\Install-ZabbixAgent2-PSK.ps1 -ZabbixServer '10.1.2.61' -InstallDir 'C:\Program Files\Zabbix Agent 2'
#   .\Install-ZabbixAgent2-PSK.ps1 -WhatIf

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [string]$ZabbixServer = '10.1.2.61',
    [int]$ZabbixServerPort = 10051,
    [int]$AgentPort = 10050,
    [string]$InstallDir = 'C:\Program Files\Zabbix Agent 2',
    [string]$ZabbixHostName = $env:COMPUTERNAME,
    [string]$PskIdentity = "$($env:COMPUTERNAME)-PSK",
    [string]$PskValue = 'E6972D51CA9309DB0DA03CECE7ACC56A2878E13C6BB980BB01AD8BB767E88CD2',
    [string]$MsiUrl = 'https://cdn.zabbix.com/zabbix/binaries/stable/7.4/7.4.12/zabbix_agent2-7.4.12-windows-amd64-openssl.msi',
    [string]$LogPath = "$env:TEMP\Install-ZabbixAgent2.log",
    [switch]$ConfigureFirewall,
    [switch]$SkipInstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------

function Write-Info {
    param([string]$Message)
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Host "[$timestamp] $Message"
}

function Assert-Administrator {
    $principal = [Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()
    )
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This script must run as Administrator.'
    }
}

# ---------------------------------------------------------------------------
# Step 1 — Pre-flight checks
# ---------------------------------------------------------------------------

if ($PSCmdlet.ShouldProcess('Zabbix Agent 2 installation', 'Run pre-flight checks')) {
    Assert-Administrator
}

Write-Info "Target server:  $ZabbixServer`:$ZabbixServerPort"
Write-Info "Host name:      $ZabbixHostName"
Write-Info "PSK identity:   $PskIdentity"
Write-Info "Install dir:    $InstallDir"
Write-Info "Log path:       $LogPath"

# ---------------------------------------------------------------------------
# Step 2 — Download and install Zabbix Agent 2
# ---------------------------------------------------------------------------

if (-not $SkipInstall -and $PSCmdlet.ShouldProcess($MsiUrl, 'Download and install Zabbix Agent 2 MSI')) {
    $msiPath = Join-Path $env:TEMP 'zabbix_agent2.msi'

    Write-Info "Downloading Zabbix Agent 2 MSI from $MsiUrl ..."
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $webClient = New-Object System.Net.WebClient
        $webClient.DownloadFile($MsiUrl, $msiPath)
    }
    finally {
        if ($webClient) { $webClient.Dispose() }
    }

    if (-not (Test-Path -LiteralPath $msiPath)) {
        throw "Download failed — MSI not found at $msiPath"
    }
    Write-Info "Downloaded to $msiPath"

    Write-Info "Installing Zabbix Agent 2 (this may take a minute) ..."
    $installArgs = @(
        '/i', "`"$msiPath`"",
        '/qn',
        '/norestart',
        "INSTALLFOLDER=`"$InstallDir`"",
        "LOGFILE=`"$LogPath`""
    )
    $proc = Start-Process -FilePath msiexec.exe -ArgumentList $installArgs -Wait -PassThru -NoNewWindow

    if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) {
        # 3010 = reboot required, still a successful install
        throw "MSI install failed with exit code $($proc.ExitCode). Check log: $LogPath"
    }

    Write-Info "MSI install completed (exit code: $($proc.ExitCode))."
    if ($proc.ExitCode -eq 3010) {
        Write-Info 'A reboot is pending but not required for configuration.'
    }

    # Clean up the MSI
    Remove-Item -LiteralPath $msiPath -Force -ErrorAction SilentlyContinue

    # Give the service a moment to register
    Start-Sleep -Seconds 3
}
else {
    Write-Info 'Skipping MSI download/install (-SkipInstall or -WhatIf).'
}

# ---------------------------------------------------------------------------
# Step 3 — Locate the agent paths
# ---------------------------------------------------------------------------

Write-Info 'Locating Zabbix Agent 2 service and config ...'

$service = Get-CimInstance Win32_Service -Filter "Name='Zabbix Agent 2'" -ErrorAction SilentlyContinue
if (-not $service) {
    throw 'Zabbix Agent 2 service not found after install. Check the MSI log.'
}

$configPath = $null
$exePath = $null

if ($service.PathName -match '(?i)-c\s+"([^"]+)"') {
    $configPath = $Matches[1]
}
if ($service.PathName -match '^\s*"([^"]*zabbix_agent2\.exe)"') {
    $exePath = $Matches[1]
}
elseif ($service.PathName -match '^\s*([^\s]*zabbix_agent2\.exe)') {
    $exePath = $Matches[1]
}

if (-not $exePath) {
    throw "Could not locate zabbix_agent2.exe from: $($service.PathName)"
}
if (-not $configPath) {
    $configPath = Join-Path (Split-Path -Parent $exePath) 'zabbix_agent2.conf'
}
if (-not (Test-Path -LiteralPath $configPath)) {
    throw "Config not found: $configPath"
}

$agentDir = Split-Path -Parent $configPath
$pskPath = Join-Path $agentDir 'zabbix_agent2.psk'
$backupPath = "$configPath.backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

Write-Info "Agent exe:      $exePath"
Write-Info "Config path:    $configPath"
Write-Info "PSK file path:  $pskPath"

# ---------------------------------------------------------------------------
# Step 4 — Back up and configure zabbix_agent2.conf
# ---------------------------------------------------------------------------

if ($PSCmdlet.ShouldProcess($configPath, 'Back up and configure zabbix_agent2.conf')) {
    Copy-Item -LiteralPath $configPath -Destination $backupPath -Force
    Write-Info "Config backed up to $backupPath"

    $configLines = [System.IO.File]::ReadAllLines($configPath)

    # Remove only the keys this script manages (leave comments/documentation intact)
    $managedKeys = 'Server|ServerActive|Hostname|TLSConnect|TLSAccept|TLSPSKIdentity|TLSPSKFile'
    $configLines = $configLines | Where-Object {
        $_ -notmatch "^\s*($managedKeys)\s*="
    }

    $configLines += @(
        '',
        '# Managed by Install-ZabbixAgent2-PSK.ps1',
        "Server=$ZabbixServer",
        "ServerActive=$ZabbixServer`:$ZabbixServerPort",
        "Hostname=$ZabbixHostName",
        'TLSConnect=psk',
        'TLSAccept=psk',
        "TLSPSKIdentity=$PskIdentity",
        "TLSPSKFile=$pskPath"
    )

    # Zabbix Agent 2 on Windows rejects a UTF-8 BOM — write without one
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines($configPath, $configLines, $utf8NoBom)

    Write-Info 'Config updated with PSK settings.'
}

# ---------------------------------------------------------------------------
# Step 5 — Write the PSK file
# ---------------------------------------------------------------------------

if ($PSCmdlet.ShouldProcess($pskPath, 'Write PSK file')) {
    [System.IO.File]::WriteAllText($pskPath, $PskValue, [System.Text.Encoding]::ASCII)
    Write-Info "PSK file written to $pskPath"
}

# ---------------------------------------------------------------------------
# Step 6 — Firewall rule (optional)
# ---------------------------------------------------------------------------

if ($ConfigureFirewall -and $PSCmdlet.ShouldProcess("TCP $AgentPort from $ZabbixServer", 'Create firewall rule')) {
    $ruleName = 'Zabbix Agent 2 - TCP 10050 from Zabbix Server'
    Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue |
        Remove-NetFirewallRule

    New-NetFirewallRule `
        -DisplayName $ruleName `
        -Direction Inbound `
        -Action Allow `
        -Protocol TCP `
        -LocalPort $AgentPort `
        -RemoteAddress $ZabbixServer `
        -Profile Any | Out-Null

    Write-Info "Firewall rule created: $ruleName"
}

# ---------------------------------------------------------------------------
# Step 7 — Restart service
# ---------------------------------------------------------------------------

if ($PSCmdlet.ShouldProcess('Zabbix Agent 2', 'Restart service')) {
    Write-Info 'Restarting Zabbix Agent 2 service ...'
    Restart-Service -Name 'Zabbix Agent 2' -Force
    Start-Sleep -Seconds 5
}

# ---------------------------------------------------------------------------
# Step 8 — Verify and output results
# ---------------------------------------------------------------------------

$serviceStatus = Get-Service -Name 'Zabbix Agent 2'

Write-Output "`n========================================"
Write-Output "  Zabbix Agent 2 — Deployment Complete"
Write-Output "========================================"
Write-Output "Service:        $($serviceStatus.Status)"
Write-Output "Config backup:  $backupPath"
Write-Output "PSK file:       $pskPath"
Write-Output ""

Write-Output "========== Enter these in Zabbix frontend =========="
Write-Output "Host name:                  $ZabbixHostName"
Write-Output "Agent interface:            <this host IP>:$AgentPort"
Write-Output "Connections to host:        PSK"
Write-Output "Connections from host:      PSK"
Write-Output "PSK identity:               $PskIdentity"
Write-Output "PSK value:                  $PskValue"
Write-Output "===================================================="
Write-Output ""

Write-Output "=== Server connectivity check ==="
Test-NetConnection -ComputerName $ZabbixServer -Port $ZabbixServerPort |
    Select-Object ComputerName, RemotePort, TcpTestSucceeded
Write-Output ""

Write-Output "=== Latest Agent 2 log entries ==="
$log = Join-Path $agentDir 'zabbix_agent2.log'
if (Test-Path -LiteralPath $log) {
    Get-Content -LiteralPath $log -Tail 10
}