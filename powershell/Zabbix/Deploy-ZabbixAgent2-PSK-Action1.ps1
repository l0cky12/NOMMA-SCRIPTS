# Deploy-ZabbixAgent2-PSK-Action1.ps1
# Run through Action1 as SYSTEM / Administrator.
# Requires Zabbix Agent 2 to already be installed.
#
# After it runs, create or update the host in Zabbix using the PSK identity
# and PSK value printed in the Action1 output.

$ErrorActionPreference = 'Stop'

# -------------------- EDIT THIS --------------------
$ZabbixServer = '10.1.2.61' # Zabbix server / proxy IP address
$ZabbixServerPort = 10051
$AgentPort = 10050

# Leave as $env:COMPUTERNAME unless the Zabbix host name must differ.
$ZabbixHostName = $env:COMPUTERNAME

# Use a predictable, unique PSK identity for every endpoint.
$PskIdentity = "$ZabbixHostName-PSK"

# Create a Windows Firewall rule allowing passive checks only from Zabbix.
$ConfigureFirewall = $true
# ---------------------------------------------------

function Get-ZabbixAgent2Paths {
    $service = Get-CimInstance Win32_Service -Filter "Name='Zabbix Agent 2'"
    if (-not $service) {
        throw "Zabbix Agent 2 is not installed. Install it before running this script."
    }

    $configPath = $null
    $exePath = $null

    if ($service.PathName -match '(?i)-c\s+"([^\"]+)"') {
        $configPath = $Matches[1]
    }

    if ($service.PathName -match '^\s*"([^\"]*zabbix_agent2\.exe)"') {
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
        ExePath = $exePath
        ConfigPath = $configPath
        AgentDirectory = Split-Path -Parent $configPath
    }
}

$agent = Get-ZabbixAgent2Paths
$pskPath = Join-Path $agent.AgentDirectory 'zabbix_agent2.psk'
$backupPath = "$($agent.ConfigPath).backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

Write-Output "=== Zabbix Agent 2 PSK deployment ==="
Write-Output "Agent executable: $($agent.ExePath)"
Write-Output "Agent config:     $($agent.ConfigPath)"
Write-Output "Zabbix server:    $ZabbixServer`:$ZabbixServerPort"
Write-Output "Zabbix hostname:  $ZabbixHostName"

# Back up config and retain every unrelated existing setting.
Copy-Item -LiteralPath $agent.ConfigPath -Destination $backupPath -Force
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
}

Restart-Service -Name 'Zabbix Agent 2' -Force
Start-Sleep -Seconds 5
$serviceStatus = Get-Service -Name 'Zabbix Agent 2'

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
