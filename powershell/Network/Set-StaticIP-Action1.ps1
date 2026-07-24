# Set-StaticIP-Action1.ps1
# Run through Action1 as SYSTEM.
# Detects the active network adapter with DHCP and sets a static IP.
# Works on any Windows PC — auto-finds the right interface.
#
# Edit the variables below before deploying through Action1.

$ErrorActionPreference = 'Stop'

# -------------------- EDIT THESE --------------------
$IPAddress       = '10.6.4.95'     # Desired static IP
$PrefixLength    = 24              # Subnet mask: 24 = 255.255.255.0
$DefaultGateway  = '10.6.4.1'      # Usually x.x.x.1 or x.x.x.254
$PrimaryDNS      = '10.1.2.53'     # Primary DNS server
$SecondaryDNS    = '10.1.2.54'     # Secondary DNS server
# ----------------------------------------------------

function Write-Info {
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Output "[$timestamp] $($args[0])"
}

function Assert-Administrator {
    $principal = [Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()
    )
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This script must run as Administrator.'
    }
}

# ------------------------------------------------------------------
# Step 1 — Pre-flight
# ------------------------------------------------------------------
Assert-Administrator

Write-Info "Target IP: $IPAddress /$PrefixLength"
Write-Info "Gateway:   $DefaultGateway"
Write-Info "DNS:       $PrimaryDNS, $SecondaryDNS"

# ------------------------------------------------------------------
# Step 2 — Find the active adapter with DHCP
# ------------------------------------------------------------------
$adapter = Get-NetAdapter | Where-Object {
    $_.Status -eq 'Up' -and
    (Get-NetIPInterface -InterfaceIndex $_.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).Dhcp -eq 'Enabled'
} | Select-Object -First 1

if (-not $adapter) {
    throw 'No active adapter with DHCP enabled found. Check network status.'
}

$adapterName = $adapter.Name
$ifIndex = $adapter.ifIndex

Write-Info "Found adapter: $adapterName (ifIndex: $ifIndex)"
Write-Info "Current config will be backed up."

# ------------------------------------------------------------------
# Step 3 — Back up current config
# ------------------------------------------------------------------
$backup = Get-NetIPConfiguration -InterfaceIndex $ifIndex -ErrorAction SilentlyContinue
$currentIP  = $backup.IPv4Address.IPAddress
$currentGw  = $backup.IPv4DefaultGateway.NextHop
$currentDns = ($backup.DNSServer.ServerAddresses -join ', ')

Write-Info "Current IP:     $currentIP"
Write-Info "Current gateway: $currentGw"
Write-Info "Current DNS:     $currentDns"

# ------------------------------------------------------------------
# Step 4 — Set static IP
# ------------------------------------------------------------------
Write-Info "Removing DHCP configuration..."
Remove-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue
Remove-NetRoute -InterfaceIndex $ifIndex -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue

Write-Info "Setting static IP: $IPAddress /$PrefixLength gateway $DefaultGateway..."
New-NetIPAddress -InterfaceIndex $ifIndex `
    -IPAddress $IPAddress `
    -PrefixLength $PrefixLength `
    -DefaultGateway $DefaultGateway `
    -ErrorAction Stop | Out-Null

Write-Info "Setting DNS: $PrimaryDNS, $SecondaryDNS..."
Set-DNSClientServerAddress -InterfaceIndex $ifIndex `
    -ServerAddresses @($PrimaryDNS, $SecondaryDNS) `
    -ErrorAction Stop

# ------------------------------------------------------------------
# Step 5 — Verify
# ------------------------------------------------------------------
$verify = Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
Write-Info "---"
Write-Info "✅ Static IP set successfully!"
Write-Info "   Adapter:  $adapterName"
Write-Info "   IP:       $($verify.IPAddress) /$($verify.PrefixLength)"
Write-Info "   Gateway:  $( (Get-NetRoute -InterfaceIndex $ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue).NextHop )"
Write-Info "   DNS:      $( (Get-DNSClientServerAddress -InterfaceIndex $ifIndex -ErrorAction SilentlyContinue).ServerAddresses -join ', ' )"
Write-Info "---"
Write-Info "📋 Prior config (for reference):"
Write-Info "   Previous IP: $currentIP"
Write-Info "   Previous gateway: $currentGw"
Write-Info "   Previous DNS: $currentDns"
