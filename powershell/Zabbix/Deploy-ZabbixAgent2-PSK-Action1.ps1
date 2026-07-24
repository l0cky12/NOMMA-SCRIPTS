# Deploy-ZabbixAgent2-PSK-Action1.ps1
# Run through Action1 as SYSTEM / Administrator.
# Downloads and installs Zabbix Agent 2 from scratch if not already present,
# then configures PSK encryption, creates a firewall rule, and outputs the
# PSK identity + value needed in the Zabbix frontend.
#
# After it runs, create or update the host in Zabbix using the PSK identity
# and PSK value printed in the Action1 output.

$ErrorActionPreference = 'Stop'

# -------------------- EDIT THIS --------------------
$ZabbixServer = '10.1.2.61' # Zabbix server / proxy IP address
$ZabbixServerPort = 10051
$AgentPort = 10050
$InstallDir = 'C:\Program Files\Zabbix Agent 2'

# Leave as $env:COMPUTERNAME unless the Zabbix host name must differ.
$ZabbixHostName = $env:COMPUTERNAME

# Use a predictable, unique PSK identity for every endpoint.
$PskIdentity = "$ZabbixHostName-PSK"

# Create a Windows Firewall rule allowing passive checks only from Zabbix.
$ConfigureFirewall = $true

# Zabbix Agent 2 MSI download URL.
$MsiUrl = 'https://cdn.zabbix.com/zabbix/binaries/stable/7.4/7.4.12/zabbix_agent2-7.4.12-windows-amd64-openssl.msi'

# Log file for MSI installation details.
$MsiLogPath = "$env:TEMP\Install-ZabbixAgent2.log"
# ---------------------------------------------------

function Write-Info {
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Output "[$timestamp] $($args[0])"
}

function Get-ZabbixAgent2Paths {
    $service = Get-CimInstance Win32_Service -Filter "Name='Zabbix Agent 2'" -ErrorAction SilentlyContinue
    if (-not $service) {
        return $null
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
        throw "Could not locate zabbix_agent2.exe from the service command: $($service.PathName)"
    }

    if (-not $configPath) {
        $configPath = Join-Path (Split-Path -Parent $exePath) 'zabbix_agent2.conf'
    }

    if (-not (Test-Path -LiteralPath $configPath)) {
        throw "Zabbix Agent 2 config file was not found: $configPath"
    }

    [PSCustomObject]@{
        ExePath       = $exePath
        ConfigPath    = $configPath
        AgentDirectory = Split-Path -Parent $configPath
    }
}

function Install-ZabbixAgent2 {
    [CmdletBinding()]
    param(
        [string]$MsiUrl,
        [string]$InstallDir,
        [string]$MsiLogPath
    )
    $ErrorActionPreference = 'Stop'

    # Must run as admin for MSI install
    $principal = [Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()
    )
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This script must run as Administrator to install Zabbix Agent 2.'
    }

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

    # Validate MSI is not truncated (expect at least 5 MB for a real Zabbix Agent 2 MSI)
    $msiFile = Get-Item -LiteralPath $msiPath
    $minimumSize = 5MB
    if ($msiFile.Length -lt $minimumSize) {
        throw "Downloaded MSI is too small ($($msiFile.Length) bytes). Expected at least $minimumSize bytes. The download may have failed or returned an error page."
    }
    Write-Info "Downloaded to $msiPath ($($msiFile.Length) bytes)"

    # Clean up any previous partial install that could block a fresh install
    Write-Info 'Checking for and cleaning up any previous Zabbix Agent 2 install ...'
    $existing = Get-CimInstance Win32_Service -Filter "Name='Zabbix Agent 2'" -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Info 'Stopping previous Zabbix Agent 2 service ...'
        Stop-Service -Name 'Zabbix Agent 2' -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        # Kill any lingering agent processes
        Get-Process -Name 'zabbix_agent2' -ErrorAction SilentlyContinue | Stop-Process -Force
    }
    # Also check for stale zabbix_agent2.exe processes running outside the service
    $staleProcs = Get-Process -Name 'zabbix_agent2' -ErrorAction SilentlyContinue
    if ($staleProcs) {
        $staleProcs | Stop-Process -Force
        Write-Info "Killed $($staleProcs.Count) stale agent process(es)."
    }
    # Remove any existing service via msiexec /x if it's in a bad state
    $existingProduct = Get-CimInstance Win32_Product -Filter "Name LIKE '%Zabbix Agent 2%'" -ErrorAction SilentlyContinue
    if ($existingProduct) {
        Write-Info "Found existing Zabbix Agent 2 product (GUID: $($existingProduct.IdentifyingNumber)). Uninstalling first ..."
        $uninstallArgs = @('/x', $existingProduct.IdentifyingNumber, '/qn', '/norestart')
        $uninstallProc = Start-Process -FilePath msiexec.exe -ArgumentList $uninstallArgs -Wait -PassThru -NoNewWindow
        Write-Info "Uninstall exit code: $($uninstallProc.ExitCode)"
        Start-Sleep -Seconds 3
    }

    Write-Info "Installing Zabbix Agent 2 (this may take a minute) ..."
    $installArgs = @(
        '/i', "`"$msiPath`"",
        '/qn',
        '/norestart',
        "INSTALLFOLDER=`"$InstallDir`"",
        '/lvx*', "`"$MsiLogPath`""
    )
    $proc = Start-Process -FilePath msiexec.exe -ArgumentList $installArgs -Wait -PassThru -NoNewWindow

    if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) {
        # 3010 = reboot required, still a successful install
        Write-Info "MSI install failed with exit code $($proc.ExitCode). Check verbose log: $MsiLogPath"
        throw "MSI install failed with exit code $($proc.ExitCode). Check log: $MsiLogPath"
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

# ---------------------------------------------------------------------------
# Step 1 — Pre-flight
# ---------------------------------------------------------------------------

Write-Info "=== Zabbix Agent 2 PSK deployment ==="
Write-Info "Target server:  $ZabbixServer`:$ZabbixServerPort"
Write-Info "Host name:      $ZabbixHostName"
Write-Info "PSK identity:   $PskIdentity"
Write-Info "Install dir:    $InstallDir"

# ---------------------------------------------------------------------------
# Step 2 — Install agent if not already present
# ---------------------------------------------------------------------------

$agent = Get-ZabbixAgent2Paths

if (-not $agent) {
    Write-Info "Zabbix Agent 2 is not installed. Installing from scratch ..."
    Install-ZabbixAgent2 -MsiUrl $MsiUrl -InstallDir $InstallDir -MsiLogPath $MsiLogPath

    # Re-read paths after install
    $agent = Get-ZabbixAgent2Paths
    if (-not $agent) {
        Write-Info "Zabbix Agent 2 service was not found after installation. Check the MSI log: $MsiLogPath"
        throw "Zabbix Agent 2 service was not found after installation. Check the MSI log: $MsiLogPath"
    }
}
else {
    Write-Info "Zabbix Agent 2 is already installed."
}

# ---------------------------------------------------------------------------
# Step 3 — Configure PSK
# ---------------------------------------------------------------------------

$pskPath = Join-Path $agent.AgentDirectory 'zabbix_agent2.psk'
$backupPath = "$($agent.ConfigPath).backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

Write-Info "Agent executable: $($agent.ExePath)"
Write-Info "Agent config:     $($agent.ConfigPath)"
Write-Info "PSK file path:    $pskPath"

# Back up config and retain every unrelated existing setting.
Copy-Item -LiteralPath $agent.ConfigPath -Destination $backupPath -Force
Write-Info "Config backed up to $backupPath"

$configLines = [System.IO.File]::ReadAllLines($agent.ConfigPath)

# Remove only active values that this script owns. Commented documentation lines stay intact.
$managedKeys = 'Server|ServerActive|Hostname|TLSConnect|TLSAccept|TLSPSKIdentity|TLSPSKFile'
$configLines = $configLines | Where-Object {
    $_ -notmatch "^\s*($managedKeys)\s*="
}

$configLines += @(
    '',
    '# Managed by Deploy-ZabbixAgent2-PSK-Action1.ps1',
    "Server=$ZabbixServer",
    "ServerActive=$ZabbixServer`:$ZabbixServerPort",
    "Hostname=$ZabbixHostName",
    'TLSConnect=psk',
    'TLSAccept=psk',
    "TLSPSKIdentity=$PskIdentity",
    "TLSPSKFile=$pskPath"
)

# Zabbix Agent 2 on Windows rejects a UTF-8 BOM. Write without one.
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllLines($agent.ConfigPath, $configLines, $utf8NoBom)

Write-Info 'Config updated with PSK settings.'

# ---------------------------------------------------------------------------
# Step 4 — Generate PSK
# ---------------------------------------------------------------------------

# Generate a unique 32-byte (64-character hexadecimal) PSK.
$randomBytes = New-Object byte[] 32
$rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
try {
    $rng.GetBytes($randomBytes)
}
finally {
    $rng.Dispose()
}
$pskValue = [BitConverter]::ToString($randomBytes) -replace '-', ''
[System.IO.File]::WriteAllText($pskPath, $pskValue, [System.Text.Encoding]::ASCII)

Write-Info "PSK file written to $pskPath"

# ---------------------------------------------------------------------------
# Step 5 — Firewall rule (optional)
# ---------------------------------------------------------------------------

if ($ConfigureFirewall) {
    $ruleName = 'Zabbix Agent 2 - TCP 10050 from Zabbix Server'
    Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule

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
# Step 6 — Restart service
# ---------------------------------------------------------------------------

Write-Info 'Restarting Zabbix Agent 2 service ...'
Restart-Service -Name 'Zabbix Agent 2' -Force
Start-Sleep -Seconds 5
$serviceStatus = Get-Service -Name 'Zabbix Agent 2'

# ---------------------------------------------------------------------------
# Step 7 — Output results
# ---------------------------------------------------------------------------

Write-Output ""
Write-Output "=== Deployment result ==="
Write-Output "Service status: $($serviceStatus.Status)"
Write-Output "Firewall rule:  $($ConfigureFirewall)"
Write-Output "Config backup:  $backupPath"
Write-Output ""

Write-Output "=== Enter these values in Zabbix host encryption ==="
Write-Output "Host name:                  $ZabbixHostName"
Write-Output "Agent interface:            <this endpoint IP>:$AgentPort"
Write-Output "Connections to host:        PSK"
Write-Output "Connections from host:      PSK"
Write-Output "PSK identity:               $PskIdentity"
Write-Output "PSK value:                  $pskValue"
Write-Output ""

Write-Output "=== Endpoint-to-server connectivity test ==="
Test-NetConnection -ComputerName $ZabbixServer -Port $ZabbixServerPort | Select-Object ComputerName, RemotePort, TcpTestSucceeded
Write-Output ""

Write-Output "=== Latest Agent 2 log entries ==="
$logPath = Join-Path $agent.AgentDirectory 'zabbix_agent2.log'
if (Test-Path -LiteralPath $logPath) {
    Get-Content -LiteralPath $logPath -Tail 12
}