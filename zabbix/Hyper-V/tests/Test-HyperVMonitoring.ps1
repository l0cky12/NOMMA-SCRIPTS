<#
.SYNOPSIS
Runs syntax and fixture-driven tests for the Hyper-V Zabbix PowerShell implementation.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$solutionRoot = Split-Path -Parent $PSScriptRoot
$collector = Join-Path $solutionRoot 'scripts\Get-ZabbixHyperVData.ps1'
$fixture = Join-Path $solutionRoot 'tests\fixtures\scenarios.json'
$failures = New-Object System.Collections.Generic.List[string]
$passed = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { $script:failures.Add($Message) } else { $script:passed++ }
}

foreach ($scriptFile in Get-ChildItem -LiteralPath (Join-Path $solutionRoot 'scripts') -Filter '*.ps1') {
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($scriptFile.FullName, [ref]$tokens, [ref]$errors)
    Assert-True (@($errors).Count -eq 0) "PowerShell parser errors in $($scriptFile.Name): $($errors -join '; ')"
}

$fixtureData = Get-Content -LiteralPath $fixture -Raw | ConvertFrom-Json
Assert-True (@($fixtureData.scenarios).Count -eq 15) 'Expected exactly 15 fixture scenarios.'
foreach ($entry in @($fixtureData.scenarios)) {
    $json = & $collector -FixturePath $fixture -Scenario ([string]$entry.name)
    $exitCode = $LASTEXITCODE
    Assert-True ($exitCode -eq 0) "Scenario $($entry.name) returned exit code $exitCode."
    try { $data = $json | ConvertFrom-Json -ErrorAction Stop } catch { $data = $null }
    Assert-True ($null -ne $data) "Scenario $($entry.name) did not return valid JSON."
    if ($null -eq $data) { continue }
    Assert-True ($null -ne $data.collector) "Scenario $($entry.name) lacks collector data."
    foreach ($arrayName in @('vms','replicas','volumes','csvs','switches','certificates')) {
        Assert-True ($null -ne $data.PSObject.Properties[$arrayName]) "Scenario $($entry.name) lacks $arrayName."
    }
}

$healthy = (& $collector -FixturePath $fixture -Scenario 'replication_healthy') | ConvertFrom-Json
Assert-True ($healthy.replicas[0].health -eq 1 -and $healthy.replicas[0].failover_ready -eq 1) 'Healthy replication fixture is not healthy and failover-ready.'
$warning = (& $collector -FixturePath $fixture -Scenario 'replication_warning') | ConvertFrom-Json
Assert-True ($warning.replicas[0].health -eq 2 -and $warning.replicas[0].lag_seconds -ge 600) 'Warning replication fixture does not cross warning conditions.'
$critical = (& $collector -FixturePath $fixture -Scenario 'replication_critical') | ConvertFrom-Json
Assert-True ($critical.replicas[0].health -eq 3 -and $critical.replicas[0].errors -gt 0 -and $critical.replicas[0].backlog_bytes -gt 0) 'Critical replication fixture lacks failure evidence.'
$noRole = (& $collector -FixturePath $fixture -Scenario 'hyperv_not_installed') | ConvertFrom-Json
Assert-True ($noRole.collector.ok -eq 1 -and $noRole.host.role_installed -eq 0 -and @($noRole.vms).Count -eq 0) 'Hyper-V absent should be a valid, empty, non-alerting result.'
$permission = (& $collector -FixturePath $fixture -Scenario 'permission_denied') | ConvertFrom-Json
Assert-True ($permission.collector.ok -eq 0 -and $permission.collector.error -match 'Access is denied') 'Permission-denied fixture did not expose a collector failure.'
$cluster = (& $collector -FixturePath $fixture -Scenario 'clustered_with_csv') | ConvertFrom-Json
Assert-True ($cluster.host.cluster_present -eq 1 -and $cluster.host.replica_broker_online -eq 1 -and @($cluster.csvs).Count -eq 1) 'Cluster/CSV fixture is incomplete.'
$empty = (& $collector -FixturePath $fixture -Scenario 'empty_discovery') | ConvertFrom-Json
Assert-True (@($empty.vms).Count -eq 0 -and @($empty.replicas).Count -eq 0 -and @($empty.csvs).Count -eq 0) 'Empty discovery fixture is not empty.'

$missingOutput = & $collector -FixturePath $fixture -Scenario 'does_not_exist' 2>$null
$missingExit = $LASTEXITCODE
$missing = $missingOutput | ConvertFrom-Json
Assert-True ($missingExit -ne 0 -and $missing.collector.ok -eq 0) 'Unknown fixture scenario did not fail safely with JSON.'

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ }
    throw "$($failures.Count) test assertion(s) failed; $passed passed."
}
Write-Output "PASS: $passed PowerShell parser and fixture assertions."
