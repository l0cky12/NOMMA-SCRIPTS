# Repair-ZabbixHyperVCollector-Action1.ps1
# Repairs the NOMMA Hyper-V Zabbix collector on an actual Hyper-V host.
# Downloads the current public collector, ensures Agent 2 has a 30-second timeout,
# restarts Agent 2, and reports the collector result.

$ErrorActionPreference = 'Stop'

$agentDir = 'C:\Program Files\Zabbix Agent 2'
$agentExe = Join-Path $agentDir 'zabbix_agent2.exe'
$agentConfig = Join-Path $agentDir 'zabbix_agent2.conf'
$scriptsDir = Join-Path $agentDir 'scripts'
$pluginsDir = Join-Path $agentDir 'zabbix_agent2.d\plugins.d'
$collectorPath = Join-Path $scriptsDir 'Get-ZabbixHyperV.ps1'
$userParameterPath = Join-Path $pluginsDir 'userparameter_hyperv.conf'

$collectorUrl = 'https://raw.githubusercontent.com/l0cky12/zabbix-hyperv-monitoring/main/scripts/Get-ZabbixHyperV.ps1'
$userParameterUrl = 'https://raw.githubusercontent.com/l0cky12/zabbix-hyperv-monitoring/main/agent/userparameter_hyperv.conf'

if (-not (Test-Path -LiteralPath $agentExe)) { throw "Zabbix Agent 2 was not found: $agentExe" }
if (-not (Test-Path -LiteralPath $agentConfig)) { throw "Zabbix Agent 2 config was not found: $agentConfig" }

New-Item -ItemType Directory -Path $scriptsDir -Force | Out-Null
New-Item -ItemType Directory -Path $pluginsDir -Force | Out-Null

# Download to temporary files first. Existing collector remains intact if download fails.
$collectorTemp = Join-Path $env:TEMP 'Get-ZabbixHyperV.ps1.download'
$userParameterTemp = Join-Path $env:TEMP 'userparameter_hyperv.conf.download'

Invoke-WebRequest -Uri $collectorUrl -OutFile $collectorTemp
Invoke-WebRequest -Uri $userParameterUrl -OutFile $userParameterTemp

if (-not (Test-Path -LiteralPath $collectorTemp) -or (Get-Item -LiteralPath $collectorTemp).Length -lt 1000) {
    throw 'Downloaded Hyper-V collector is missing or unexpectedly small.'
}
if (-not (Test-Path -LiteralPath $userParameterTemp) -or (Get-Item -LiteralPath $userParameterTemp).Length -lt 50) {
    throw 'Downloaded Hyper-V UserParameter config is missing or unexpectedly small.'
}

Move-Item -LiteralPath $collectorTemp -Destination $collectorPath -Force
Move-Item -LiteralPath $userParameterTemp -Destination $userParameterPath -Force
Unblock-File -Path $collectorPath -ErrorAction SilentlyContinue
Unblock-File -Path $userParameterPath -ErrorAction SilentlyContinue

# Hyper-V inventory and replication cmdlets can exceed the default Agent timeout.
# Preserve all other settings and write the config without a UTF-8 BOM.
$backupPath = "$agentConfig.backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
Copy-Item -LiteralPath $agentConfig -Destination $backupPath -Force
$configLines = [System.IO.File]::ReadAllLines($agentConfig)
$configLines = $configLines | Where-Object { $_ -notmatch '^\s*Timeout\s*=' }
$configLines += @('', '# Hyper-V collector timeout', 'Timeout=30')
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllLines($agentConfig, $configLines, $utf8NoBom)

Restart-Service -Name 'Zabbix Agent 2' -Force
Start-Sleep -Seconds 5

$service = Get-Service -Name 'Zabbix Agent 2'
if ($service.Status -ne 'Running') { throw "Zabbix Agent 2 did not start. Status: $($service.Status)" }

Write-Output '=== Hyper-V collector repair complete ==='
Write-Output "Collector: $collectorPath"
Write-Output "UserParameter: $userParameterPath"
Write-Output "Agent config backup: $backupPath"
Write-Output 'Agent timeout: 30 seconds'
Write-Output "`n=== Direct collector result ==="
$collectorResult = & powershell.exe -NoLogo -NoProfile -NonInteractive -File $collectorPath
$collectorResult

Write-Output "`n=== Agent 2 UserParameter result ==="
& $agentExe -c $agentConfig -t hyperv.collect 2>&1
