<#
.SYNOPSIS
    Creates a DHCP reservation (a fixed IP tied to a MAC address).

.WHEN TO USE
    Whenever a device (printer, server, camera, AP) must always receive
    the same address from DHCP. Safe to re-run: an existing reservation
    for the same IP is reported, not duplicated.

.HOW TO RUN
    As Administrator:
        .\06-Add-DhcpReservation.ps1 -ScopeId 10.1.0.0 -IPAddress 10.1.0.50 `
            -MacAddress 'AA-BB-CC-DD-EE-FF' -Name 'PRN-Office-01' `
            -Description 'Main office printer'
#>

#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$ScopeId,      # e.g. 10.1.0.0
    [Parameter(Mandatory)] [string]$IPAddress,    # must be inside the scope's subnet
    [Parameter(Mandatory)] [string]$MacAddress,   # AA-BB-CC-DD-EE-FF or AABBCCDDEEFF
    [Parameter(Mandatory)] [string]$Name,         # device name
    [string]$Description = ''
)

$ErrorActionPreference = 'Stop'
Import-Module DhcpServer

try {
    if (-not (Get-DhcpServerv4Scope -ScopeId $ScopeId -ErrorAction SilentlyContinue)) {
        throw "Scope $ScopeId does not exist on this server."
    }

    # Normalize MAC to the dashed format the DHCP server stores.
    $mac = ($MacAddress -replace '[^0-9A-Fa-f]', '').ToUpper()
    if ($mac.Length -ne 12) { throw "MAC address '$MacAddress' is not a valid 12-hex-digit address." }
    $mac = ($mac -split '(.{2})' | Where-Object { $_ }) -join '-'

    # --- Idempotency: does a reservation for this IP already exist? ---
    $existing = Get-DhcpServerv4Reservation -ScopeId $ScopeId -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress.ToString() -eq $IPAddress }

    if ($existing) {
        Write-Host "Reservation for $IPAddress already exists (ClientId: $($existing.ClientId), Name: $($existing.Name)). Skipping." -ForegroundColor Yellow
        if ($existing.ClientId -ne $mac) {
            Write-Warning "Existing reservation has a DIFFERENT MAC ($($existing.ClientId) vs $mac). Review manually."
        }
    }
    else {
        Add-DhcpServerv4Reservation -ScopeId $ScopeId -IPAddress $IPAddress `
            -ClientId $mac -Name $Name -Description $Description
        Write-Host "Reservation created: $IPAddress -> $mac ($Name)" -ForegroundColor Green
    }

    # --- Verification -------------------------------------------------
    Write-Host "`n--- Reservations in scope $ScopeId ---" -ForegroundColor Cyan
    Get-DhcpServerv4Reservation -ScopeId $ScopeId |
        Format-Table IPAddress, ClientId, Name, Description -AutoSize
}
catch {
    Write-Error "Failed to create reservation: $($_.Exception.Message)"
    exit 1
}
