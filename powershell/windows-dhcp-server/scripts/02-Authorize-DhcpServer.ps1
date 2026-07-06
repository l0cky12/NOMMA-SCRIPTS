<#
.SYNOPSIS
    Authorizes this DHCP server in Active Directory (if domain-joined).

.WHEN TO USE
    Once after installing the role (script 01). Re-running is safe:
    it skips authorization if the server is already authorized.
    Requires Enterprise Admin rights or delegated DHCP authorization.

.HOW TO RUN
    As Administrator:
        .\02-Authorize-DhcpServer.ps1
#>

#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'

try {
    Import-Module DhcpServer

    $cs = Get-CimInstance -ClassName Win32_ComputerSystem
    if (-not $cs.PartOfDomain) {
        Write-Warning "This server is not domain-joined. AD authorization does not apply (standalone DHCP)."
        return
    }

    $serverFqdn = ('{0}.{1}' -f $env:COMPUTERNAME, $cs.Domain).ToLower()

    # --- Idempotency check: already authorized? -----------------------
    $authorized = Get-DhcpServerInDC
    if ($authorized.DnsName -contains $serverFqdn) {
        Write-Host "'$serverFqdn' is already authorized in Active Directory." -ForegroundColor Green
    }
    else {
        Write-Host "Authorizing '$serverFqdn' in Active Directory..."
        Add-DhcpServerInDC -DnsName $serverFqdn
        Write-Host "Authorized successfully." -ForegroundColor Green

        # Restart so the server begins serving immediately after authorization.
        Restart-Service -Name DHCPServer -Force
    }

    # --- Verification -------------------------------------------------
    Write-Host "`n--- Authorized DHCP servers in AD ---" -ForegroundColor Cyan
    Get-DhcpServerInDC | Format-Table DnsName, IPAddress -AutoSize
}
catch {
    Write-Error "Authorization failed: $($_.Exception.Message)"
    Write-Warning "You may need Enterprise Admin credentials: Add-DhcpServerInDC -DnsName <server-fqdn>"
    exit 1
}
