# Test-ZabbixHyperV-Action1.ps1
# Read-only validation for the NOMMA Hyper-V Zabbix collector.
# Run using Action1 on actual Hyper-V hosts only.

$ErrorActionPreference = 'Stop'

$agentDir = 'C:\Program Files\Zabbix Agent 2'
$agentExe = Join-Path $agentDir 'zabbix_agent2.exe'
$agentConfig = Join-Path $agentDir 'zabbix_agent2.conf'
$collectorPath = Join-Path $agentDir 'scripts\Get-ZabbixHyperV.ps1'
$userParameterPath = Join-Path $agentDir 'zabbix_agent2.d\plugins.d\userparameter_hyperv.conf'
$failures = New-Object System.Collections.Generic.List[string]

function Test-Result {
    param(
        [string]$Name,
        [bool]$Passed,
        [string]$Detail
    )

    if ($Passed) {
        Write-Output "PASS: $Name - $Detail"
    }
    else {
        Write-Output "FAIL: $Name - $Detail"
        $script:failures.Add($Name)
    }
}

Write-Output '=== NOMMA Hyper-V Zabbix Collector Test ==='

# Required files
Test-Result -Name 'Zabbix Agent 2 executable' -Passed (Test-Path -LiteralPath $agentExe) -Detail $agentExe
Test-Result -Name 'Zabbix Agent 2 config' -Passed (Test-Path -LiteralPath $agentConfig) -Detail $agentConfig
Test-Result -Name 'Hyper-V collector script' -Passed (Test-Path -LiteralPath $collectorPath) -Detail $collectorPath
Test-Result -Name 'Hyper-V UserParameter file' -Passed (Test-Path -LiteralPath $userParameterPath) -Detail $userParameterPath

# Agent service
$agentService = Get-Service -Name 'Zabbix Agent 2' -ErrorAction SilentlyContinue
if ($agentService) {
    $agentServiceDetail = [string]$agentService.Status
}
else {
    $agentServiceDetail = 'Service not found'
}
Test-Result -Name 'Zabbix Agent 2 service' -Passed ($agentService -and $agentService.Status -eq 'Running') -Detail $agentServiceDetail

# Local Hyper-V prerequisites
$hypervModule = Get-Module -ListAvailable -Name Hyper-V | Select-Object -First 1
if ($hypervModule) {
    $hypervModuleDetail = $hypervModule.Path
}
else {
    $hypervModuleDetail = 'Module not found'
}
Test-Result -Name 'Hyper-V PowerShell module' -Passed ($null -ne $hypervModule) -Detail $hypervModuleDetail

$vmms = Get-Service -Name vmms -ErrorAction SilentlyContinue
if ($vmms) {
    $vmmsDetail = [string]$vmms.Status
}
else {
    $vmmsDetail = 'Service not found'
}
Test-Result -Name 'Hyper-V VMMS service' -Passed ($vmms -and $vmms.Status -eq 'Running') -Detail $vmmsDetail

# Run the collector directly and validate its JSON contract. Preserve its full
# failure document in Action1 output so a failed check is diagnosable remotely.
if (Test-Path -LiteralPath $collectorPath) {
    try {
        $collectorOutput = & powershell.exe -NoLogo -NoProfile -NonInteractive -File $collectorPath 2>&1
        $collectorExitCode = $LASTEXITCODE
        $collectorText = ($collectorOutput | Out-String).Trim()
        $collectorJson = $collectorText | ConvertFrom-Json -ErrorAction Stop

        $isHealthy = ($collectorExitCode -eq 0 -and $collectorJson.collection.ok -eq 1)
        $detail = "exit=$collectorExitCode; collection.ok=$($collectorJson.collection.ok); VMs=$($collectorJson.host.vmTotal); replica-primary=$($collectorJson.host.replicaPrimary); replica=$($collectorJson.host.replicaReplica)"
        if (-not $isHealthy -and $collectorJson.collection.error) {
            $detail += "; error=$($collectorJson.collection.error)"
        }
        Test-Result -Name 'Direct Hyper-V collector' -Passed $isHealthy -Detail $detail

        if (-not $isHealthy) {
            Write-Output "`n=== Direct collector failure document ==="
            Write-Output $collectorText
        }
    }
    catch {
        Test-Result -Name 'Direct Hyper-V collector' -Passed $false -Detail $_.Exception.Message
    }
}

# Verify that Agent 2 loaded the UserParameter.
if ((Test-Path -LiteralPath $agentExe) -and (Test-Path -LiteralPath $agentConfig)) {
    try {
        $agentTest = & $agentExe -c $agentConfig -t hyperv.collect 2>&1
        $agentTestText = $agentTest | Out-String
        $supported = ($agentTestText -notmatch 'ZBX_NOTSUPPORTED|Unknown metric|not supported') -and ($agentTestText -match 'hyperv\.collect')
        $preview = ($agentTestText -replace '[\r\n]+', ' ').Trim()
        if ($preview.Length -gt 500) { $preview = $preview.Substring(0, 500) + '...' }
        Test-Result -Name 'Agent 2 UserParameter: hyperv.collect' -Passed $supported -Detail $preview
    }
    catch {
        Test-Result -Name 'Agent 2 UserParameter: hyperv.collect' -Passed $false -Detail $_.Exception.Message
    }
}

# Check reachability to the configured active-check server, if one is configured.
if (Test-Path -LiteralPath $agentConfig) {
    $serverActiveLine = Get-Content -LiteralPath $agentConfig | Where-Object { $_ -match '^\s*ServerActive\s*=' } | Select-Object -First 1
    if ($serverActiveLine -match '^\s*ServerActive\s*=\s*([^,\s]+)') {
        $endpoint = $Matches[1]
        $serverName = $endpoint
        $serverPort = 10051
        if ($endpoint -match '^(.+):(\d+)$') {
            $serverName = $Matches[1]
            $serverPort = [int]$Matches[2]
        }
        try {
            $networkTest = Test-NetConnection -ComputerName $serverName -Port $serverPort -WarningAction SilentlyContinue
            Test-Result -Name 'Active-check server TCP reachability' -Passed $networkTest.TcpTestSucceeded -Detail "$serverName`:$serverPort"
        }
        catch {
            Test-Result -Name 'Active-check server TCP reachability' -Passed $false -Detail $_.Exception.Message
        }
    }
    else {
        Test-Result -Name 'Active-check server configuration' -Passed $false -Detail 'No active ServerActive line found.'
    }
}

Write-Output "`n=== Recent Agent 2 log ==="
$logPath = Join-Path $agentDir 'zabbix_agent2.log'
if (Test-Path -LiteralPath $logPath) {
    Get-Content -LiteralPath $logPath -Tail 20
}

if ($failures.Count -gt 0) {
    Write-Output "`n=== Hyper-V monitoring test failure summary ==="
    $failures | ForEach-Object { Write-Output "FAIL: $_" }
    Write-Output 'Review the Direct collector failure document and Agent 2 log above for the exact cause.'
    exit 1
}

Write-Output "`nSUCCESS: Hyper-V collector and Agent 2 UserParameter tests passed."
exit 0
