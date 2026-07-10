<#
.SYNOPSIS
Installs the NOMMA Hyper-V Zabbix collector and UserParameter.
.DESCRIPTION
Copies read-only monitoring files into the selected Zabbix agent directory. Supports -WhatIf.
.EXAMPLE
.\Install-ZabbixHyperVMonitoring.ps1 -WhatIf
.EXAMPLE
.\Install-ZabbixHyperVMonitoring.ps1 -AgentFlavor Agent2
.NOTES
Run elevated. Rollback: use -Uninstall, then restart the agent service.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [ValidateSet('Agent2','Classic')]
    [string]$AgentFlavor = 'Agent2',

    [string]$AgentRoot,

    [switch]$Uninstall
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if (-not $AgentRoot) {
    $AgentRoot = if ($AgentFlavor -eq 'Agent2') { 'C:\Program Files\Zabbix Agent 2' } else { 'C:\Program Files\Zabbix Agent' }
}
$serviceName = if ($AgentFlavor -eq 'Agent2') { 'Zabbix Agent 2' } else { 'Zabbix Agent' }
$includeDir = if ($AgentFlavor -eq 'Agent2') { Join-Path $AgentRoot 'zabbix_agent2.d' } else { Join-Path $AgentRoot 'zabbix_agentd.d' }
$targetScriptDir = Join-Path $AgentRoot 'scripts\Hyper-V'
$userParameterPath = Join-Path $includeDir 'hyperv.conf'
$solutionRoot = Split-Path -Parent $PSScriptRoot

if ($Uninstall) {
    foreach ($path in @($userParameterPath, $targetScriptDir)) {
        if (Test-Path -LiteralPath $path) {
            if ($PSCmdlet.ShouldProcess($path, 'Remove Hyper-V monitoring file or directory')) {
                Remove-Item -LiteralPath $path -Recurse -Force
            }
        }
    }
    Write-Output "Uninstall staged. Restart '$serviceName' after reviewing the removal."
    return
}

$sourceCollector = Join-Path $solutionRoot 'scripts\Get-ZabbixHyperVData.ps1'
$sourceConfig = Join-Path $solutionRoot 'config\hyperv-monitoring.example.json'
if (-not (Test-Path -LiteralPath $sourceCollector)) { throw "Missing collector: $sourceCollector" }
if (-not (Test-Path -LiteralPath $sourceConfig)) { throw "Missing config example: $sourceConfig" }

if ($PSCmdlet.ShouldProcess($targetScriptDir, 'Create script directory')) {
    New-Item -ItemType Directory -Path $targetScriptDir -Force | Out-Null
    New-Item -ItemType Directory -Path $includeDir -Force | Out-Null
}

$targetCollector = Join-Path $targetScriptDir 'Get-ZabbixHyperVData.ps1'
$targetConfig = Join-Path $targetScriptDir 'hyperv-monitoring.json'
if ($PSCmdlet.ShouldProcess($targetCollector, 'Install collector')) {
    Copy-Item -LiteralPath $sourceCollector -Destination $targetCollector -Force
    Unblock-File -LiteralPath $targetCollector -ErrorAction SilentlyContinue
}
if (-not (Test-Path -LiteralPath $targetConfig)) {
    if ($PSCmdlet.ShouldProcess($targetConfig, 'Install initial configuration')) {
        Copy-Item -LiteralPath $sourceConfig -Destination $targetConfig
    }
}
else {
    Write-Output "Preserved existing configuration: $targetConfig"
}

$escapedCollector = $targetCollector.Replace('"','\"')
$escapedConfig = $targetConfig.Replace('"','\"')
$userParameter = "# Managed by NOMMA Hyper-V monitoring installer.`r`nUserParameter=hyperv.collect,powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$escapedCollector`" -ConfigPath `"$escapedConfig`"`r`n"
if ($PSCmdlet.ShouldProcess($userParameterPath, 'Install UserParameter')) {
    [IO.File]::WriteAllText($userParameterPath, $userParameter, [Text.UTF8Encoding]::new($false))
}

Write-Output "Installed collector: $targetCollector"
Write-Output "Installed configuration: $targetConfig"
Write-Output "Installed UserParameter: $userParameterPath"
Write-Output "Next: restart '$serviceName' and test hyperv.collect locally."
