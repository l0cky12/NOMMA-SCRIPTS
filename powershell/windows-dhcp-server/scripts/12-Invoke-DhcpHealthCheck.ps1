<#
.SYNOPSIS
    Runs a DHCP server health check: service state, AD authorization,
    scope states, and utilization. Read-only.

.WHEN TO USE
    Daily/weekly checks, after maintenance, or as a first step when
    users report "no IP address" issues. Always safe to run.

.HOW TO RUN
    As Administrator:
        .\12-Invoke-DhcpHealthCheck.ps1
#>

#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'
Import-Module DhcpServer

$issues = New-Object System.Collections.Generic.List[string]

Write-Host "=== DHCP HEALTH CHECK - $env:COMPUTERNAME - $(Get-Date) ===" -ForegroundColor Cyan

# --- 1. Service status --------------------------------------------------
$svc = Get-Service -Name DHCPServer -ErrorAction SilentlyContinue
if (-not $svc) {
    $issues.Add("DHCPServer service not found - role may not be installed.")
    Write-Host "[FAIL] DHCPServer service not found." -ForegroundColor Red
}
elseif ($svc.Status -ne 'Running') {
    $issues.Add("DHCPServer service is $($svc.Status).")
    Write-Host "[FAIL] Service status: $($svc.Status)" -ForegroundColor Red
}
else {
    Write-Host "[ OK ] DHCPServer service is running (StartType: $($svc.StartType))." -ForegroundColor Green
}

# --- 2. AD authorization -------------------------------------------------
try {
    $cs = Get-CimInstance Win32_ComputerSystem
    if ($cs.PartOfDomain) {
        $fqdn = ('{0}.{1}' -f $env:COMPUTERNAME, $cs.Domain).ToLower()
        $auth = Get-DhcpServerInDC
        if ($auth.DnsName -contains $fqdn) {
            Write-Host "[ OK ] Server '$fqdn' is authorized in Active Directory." -ForegroundColor Green
        } else {
            $issues.Add("Server '$fqdn' is NOT authorized in AD.")
            Write-Host "[FAIL] Server is NOT authorized in AD (run 02-Authorize-DhcpServer.ps1)." -ForegroundColor Red
        }
    } else {
        Write-Host "[INFO] Not domain-joined - AD authorization not applicable." -ForegroundColor Yellow
    }
}
catch {
    $issues.Add("Could not verify AD authorization: $($_.Exception.Message)")
    Write-Host "[WARN] Could not verify AD authorization: $($_.Exception.Message)" -ForegroundColor Yellow
}

# --- 3. Scope states and utilization -------------------------------------
try {
    $scopes = Get-DhcpServerv4Scope
    if (-not $scopes) {
        $issues.Add("No DHCP scopes are configured.")
        Write-Host "[FAIL] No scopes configured." -ForegroundColor Red
    }
    foreach ($s in $scopes) {
        if ($s.State -ne 'Active') {
            $issues.Add("Scope $($s.ScopeId) ($($s.Name)) is $($s.State).")
            Write-Host "[WARN] Scope $($s.ScopeId) is $($s.State)." -ForegroundColor Yellow
        } else {
            Write-Host "[ OK ] Scope $($s.ScopeId) ($($s.Name)) is Active." -ForegroundColor Green
        }

        $stat = Get-DhcpServerv4ScopeStatistics -ScopeId $s.ScopeId
        $pct  = [math]::Round($stat.PercentageInUse, 1)
        if ($pct -ge 90) {
            $issues.Add("Scope $($s.ScopeId) is ${pct}% full (Free: $($stat.Free)).")
            Write-Host "       Utilization: ${pct}% in use, $($stat.Free) free  [CRITICAL]" -ForegroundColor Red
        } elseif ($pct -ge 80) {
            $issues.Add("Scope $($s.ScopeId) is ${pct}% full (Free: $($stat.Free)).")
            Write-Host "       Utilization: ${pct}% in use, $($stat.Free) free  [WARNING]" -ForegroundColor Yellow
        } else {
            Write-Host "       Utilization: ${pct}% in use, $($stat.Free) free" -ForegroundColor Green
        }
    }
}
catch {
    $issues.Add("Could not read scopes: $($_.Exception.Message)")
}

# --- Summary --------------------------------------------------------------
Write-Host "`n=== SUMMARY ===" -ForegroundColor Cyan
if ($issues.Count -eq 0) {
    Write-Host "All checks passed - DHCP server is healthy." -ForegroundColor Green
} else {
    Write-Host "$($issues.Count) issue(s) found:" -ForegroundColor Red
    $issues | ForEach-Object { Write-Host " - $_" -ForegroundColor Red }
    exit 1   # non-zero exit code so monitoring/scheduled tasks can alert
}
