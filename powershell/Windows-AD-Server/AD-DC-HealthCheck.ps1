<#
.SYNOPSIS
  Read-only health check for a local Active Directory Domain Controller.

.DESCRIPTION
  Collects service, share, replication, DNS/discovery, DCDIAG, and recent
  event-log health signals. It makes no directory, service, DNS, registry,
  or configuration changes. The only optional write is the report specified
  by -OutputPath.

.NOTES
  Run from an elevated Windows PowerShell 5.1+ session on a domain controller.
  Requires the built-in dcdiag.exe and repadmin.exe utilities for their checks.
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 168)]
    [int]$EventLogHours = 24,

    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Results = New-Object System.Collections.Generic.List[object]

function Add-Result {
    param(
        [ValidateSet('PASS', 'WARN', 'FAIL', 'INFO')][string]$Status,
        [string]$Check,
        [string]$Detail
    )
    $script:Results.Add([pscustomobject]@{
        Time   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        Status = $Status
        Check  = $Check
        Detail = $Detail
    })
}

function Get-CommandPath {
    param([string]$Name)
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    return $null
}

function Invoke-ExternalCheck {
    param(
        [string]$Name,
        [string]$FilePath,
        [string[]]$Arguments,
        [scriptblock]$Evaluate
    )
    if (-not $FilePath) {
        Add-Result WARN $Name 'Required utility was not found; check skipped.'
        return
    }
    try {
        $output = & $FilePath @Arguments 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
        & $Evaluate $output $exitCode
    }
    catch {
        Add-Result FAIL $Name $_.Exception.Message
    }
}

$started = Get-Date
Write-Host "AD DC health check started: $started" -ForegroundColor Cyan

# Confirm that this is a DC and retrieve its role without changing anything.
$computerSystem = Get-CimInstance Win32_ComputerSystem
if ($computerSystem.DomainRole -notin 4, 5) {
    Add-Result FAIL 'Domain controller role' "This machine is not a domain controller (DomainRole=$($computerSystem.DomainRole))."
}
else {
    $roleName = if ($computerSystem.DomainRole -eq 4) { 'Backup domain controller' } else { 'Primary domain controller' }
    Add-Result PASS 'Domain controller role' "$env:COMPUTERNAME is a domain controller ($roleName) in $($computerSystem.Domain)."
}

$dcType = 'Unknown'
try {
    Import-Module ActiveDirectory -ErrorAction Stop
    $localDc = Get-ADDomainController -Identity $env:COMPUTERNAME
    $dcType = if ($localDc.IsReadOnly) { 'RODC' } else { 'Writable DC' }
    Add-Result PASS 'Domain controller type' "$dcType; site: $($localDc.Site); hostname: $($localDc.HostName)."
}
catch {
    Add-Result WARN 'Domain controller type' "Could not query the ActiveDirectory module: $($_.Exception.Message)"
}

# Critical DC services. DNS is warning-only when the DNS role is not installed.
$serviceNames = @('NTDS', 'Netlogon', 'DFSR', 'KDC', 'W32Time', 'DNS')
foreach ($serviceName in $serviceNames) {
    $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    if (-not $service) {
        $status = if ($serviceName -eq 'DNS') { 'WARN' } else { 'FAIL' }
        Add-Result $status "Service: $serviceName" 'Service is not installed.'
    }
    elseif ($service.Status -eq 'Running') {
        Add-Result PASS "Service: $serviceName" 'Running.'
    }
    else {
        Add-Result FAIL "Service: $serviceName" "Status is $($service.Status)."
    }
}

# SYSVOL and NETLOGON must be published by a functioning DC.
try {
    $shareNames = if (Get-Command Get-SmbShare -ErrorAction SilentlyContinue) {
        @(Get-SmbShare -ErrorAction Stop | Select-Object -ExpandProperty Name)
    }
    else {
        @((net share | Select-String '^\s*(SYSVOL|NETLOGON)\s+' | ForEach-Object { ($_ -split '\s+')[1] }))
    }
    foreach ($share in 'SYSVOL', 'NETLOGON') {
        if ($shareNames -contains $share) {
            Add-Result PASS "Share: $share" 'Published.'
        }
        else {
            Add-Result FAIL "Share: $share" 'Share is not published.'
        }
    }
}
catch {
    Add-Result FAIL 'SYSVOL/NETLOGON shares' $_.Exception.Message
}

# DNS registration and DC discovery in the current AD domain.
$domainName = $computerSystem.Domain
if ($domainName -and $domainName -ne 'WORKGROUP') {
    try {
        if (Get-Command Resolve-DnsName -ErrorAction SilentlyContinue) {
            $records = Resolve-DnsName -Name "_ldap._tcp.dc._msdcs.$domainName" -Type SRV -ErrorAction Stop
            $count = @($records | Where-Object { $_.Type -eq 'SRV' }).Count
            if ($count -gt 0) { Add-Result PASS 'DNS SRV records' "Found $count LDAP DC locator SRV record(s) for $domainName." }
            else { Add-Result FAIL 'DNS SRV records' "No LDAP DC locator SRV records found for $domainName." }
        }
        else {
            Add-Result WARN 'DNS SRV records' 'Resolve-DnsName is unavailable; check skipped.'
        }
    }
    catch {
        Add-Result FAIL 'DNS SRV records' $_.Exception.Message
    }

    Invoke-ExternalCheck -Name 'DC locator discovery' -FilePath (Get-CommandPath 'nltest.exe') -Arguments @("/dsgetdc:$domainName") -Evaluate {
        param($output, $exitCode)
        if ($exitCode -eq 0) { Add-Result PASS 'DC locator discovery' (($output -replace '\s+', ' ').Trim()) }
        else { Add-Result FAIL 'DC locator discovery' "nltest exit code $exitCode. $($output.Trim())" }
    }
}
else {
    Add-Result FAIL 'DNS/DC discovery' 'Computer is not joined to an AD domain.'
}

# DCDIAG and replication diagnostics. Both are diagnostic/read-only commands.
Invoke-ExternalCheck -Name 'DCDIAG' -FilePath (Get-CommandPath 'dcdiag.exe') -Arguments @('/q') -Evaluate {
    param($output, $exitCode)
    $failed = $exitCode -ne 0 -or $output -match '(?im)\b(failed|error)\b'
    if ($failed) {
        $detail = ($output.Trim() -replace '\r?\n', ' | ')
        if (-not $detail) { $detail = "dcdiag exit code $exitCode." }
        Add-Result FAIL 'DCDIAG' $detail
    }
    else {
        Add-Result PASS 'DCDIAG' 'No errors reported by dcdiag /q.'
    }
}

Invoke-ExternalCheck -Name 'Replication summary' -FilePath (Get-CommandPath 'repadmin.exe') -Arguments @('/replsummary') -Evaluate {
    param($output, $exitCode)
    $failed = $exitCode -ne 0 -or $output -match '(?im)(fails/total\s*:\s*[1-9]|\b(?:error|failed)\b)'
    if ($failed) {
        Add-Result FAIL 'Replication summary' (($output.Trim() -replace '\r?\n', ' | '))
    }
    else {
        Add-Result PASS 'Replication summary' 'repadmin /replsummary reported no replication failures.'
    }
}

Invoke-ExternalCheck -Name 'Replication detail' -FilePath (Get-CommandPath 'repadmin.exe') -Arguments @('/showrepl', $env:COMPUTERNAME) -Evaluate {
    param($output, $exitCode)
    $failed = $exitCode -ne 0 -or $output -match '(?im)(last attempt.*(?:failed|error)|\b(?:error|failed)\b)'
    if ($failed) {
        Add-Result FAIL 'Replication detail' (($output.Trim() -replace '\r?\n', ' | '))
    }
    else {
        Add-Result PASS 'Replication detail' 'repadmin /showrepl reported no errors for the local DC.'
    }
}

# Recent operational errors that often precede DC incidents.
$logNames = @('Directory Service', 'DNS Server', 'DFS Replication', 'System')
$startTime = (Get-Date).AddHours(-$EventLogHours)
foreach ($logName in $logNames) {
    try {
        $events = @(Get-WinEvent -FilterHashtable @{ LogName = $logName; StartTime = $startTime; Level = 1, 2 } -ErrorAction Stop)
        if ($events.Count -eq 0) {
            Add-Result PASS "Event log: $logName" "No Critical/Error events in the last $EventLogHours hour(s)."
        }
        else {
            $summary = ($events | Select-Object -First 5 | ForEach-Object { "ID $($_.Id): $($_.ProviderName)" }) -join '; '
            Add-Result WARN "Event log: $logName" "$($events.Count) Critical/Error event(s) in the last $EventLogHours hour(s). Examples: $summary"
        }
    }
    catch {
        Add-Result WARN "Event log: $logName" "Could not query log: $($_.Exception.Message)"
    }
}

$script:Results | Sort-Object @{ Expression = { @('FAIL','WARN','PASS','INFO').IndexOf($_.Status) } }, Check | Format-Table -AutoSize | Out-Host
$failures = @($script:Results | Where-Object Status -eq 'FAIL').Count
$warnings = @($script:Results | Where-Object Status -eq 'WARN').Count
$summary = "Completed: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | FAIL=$failures WARN=$warnings PASS=$(@($script:Results | Where-Object Status -eq 'PASS').Count)"
Write-Host $summary -ForegroundColor $(if ($failures) { 'Red' } elseif ($warnings) { 'Yellow' } else { 'Green' })

if ($OutputPath) {
    $destination = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
    $parent = Split-Path -Parent $destination
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        throw "Output directory does not exist: $parent"
    }
    $extension = [IO.Path]::GetExtension($destination).ToLowerInvariant()
    if ($extension -eq '.csv') {
        $script:Results | Export-Csv -LiteralPath $destination -NoTypeInformation -Encoding UTF8
    }
    else {
        @($summary, '') + ($script:Results | Format-Table -AutoSize | Out-String) | Set-Content -LiteralPath $destination -Encoding UTF8
    }
    Write-Host "Report written to $destination" -ForegroundColor Cyan
}

if ($failures -gt 0) { exit 2 }
if ($warnings -gt 0) { exit 1 }
exit 0
