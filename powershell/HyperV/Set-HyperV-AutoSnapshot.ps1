# Set-HyperV-AutoSnapshot.ps1
# Creates a scheduled task on the Hyper-V host that snapshots a VM
# every 2 hours, keeping only the 4 most recent snapshots.
#
# Run this once on the Hyper-V host as Administrator.
# Edit the VM name and schedule below before running.

# -------------------- EDIT THESE --------------------
$VMName          = 'DC05'          # Name of the VM to snapshot
$IntervalMinutes = 120             # Every 2 hours
$MaxSnapshots    = 4               # Keep only this many
$TaskName        = "HyperV-AutoSnapshot-$VMName"
# ----------------------------------------------------

$ErrorActionPreference = 'Stop'

# Ensure Hyper-V module is available
if (-not (Get-Module -ListAvailable -Name Hyper-V)) {
    throw 'Hyper-V PowerShell module not found. Run this on the Hyper-V host.'
}

# Verify the VM exists
$vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
if (-not $vm) {
    throw "VM '$VMName' not found on this host."
}

# ------------------------------------------------------------------
# Create the snapshot + prune script
# ------------------------------------------------------------------
$scriptBlock = @"
`$VMName       = '$VMName'
`$MaxSnapshots = $MaxSnapshots

Import-Module Hyper-V -ErrorAction Stop

# Get current checkpoints, sorted newest first
`$snapshots = Get-VMSnapshot -VMName `$VMName | Sort-Object CreationTime -Descending

# Create a new checkpoint
`$timestamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
Checkpoint-VM -Name `$VMName -SnapshotName "Auto-`$timestamp" -ErrorAction Stop

Write-Output "[`$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Snapshot created: Auto-`$timestamp"

# Remove excess snapshots (keep only the newest N)
if (`$snapshots.Count -ge `$MaxSnapshots) {
    `$toRemove = `$snapshots | Select-Object -Skip (`$MaxSnapshots - 1)
    foreach (`$snap in `$toRemove) {
        Remove-VMSnapshot -VMSnapshot `$snap -Confirm:`$false
        Write-Output "  Removed old snapshot: `$(`$snap.Name)"
    }
}
"@

# ------------------------------------------------------------------
# Register the scheduled task
# ------------------------------------------------------------------
$action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -Command `"$scriptBlock`""

$trigger = New-ScheduledTaskTrigger -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) `
    -At (Get-Date).AddMinutes(5) `
    -Once `
    -RepetitionDuration ([TimeSpan]::MaxValue)

$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -MultipleInstances IgnoreNew

Register-ScheduledTask -TaskName $TaskName `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings `
    -Force

Write-Output "---"
Write-Output "✅ Scheduled task created: $TaskName"
Write-Output "   VM:          $VMName"
Write-Output "   Interval:    Every $IntervalMinutes minutes ($($IntervalMinutes/60)h)"
Write-Output "   Retention:   Keep last $MaxSnapshots snapshots"
Write-Output "   Runs as:     SYSTEM"
Write-Output ""
Write-Output "To test immediately: Start-ScheduledTask -TaskName '$TaskName'"
Write-Output "To view:            Get-ScheduledTask -TaskName '$TaskName'"
Write-Output "To remove:          Unregister-ScheduledTask -TaskName '$TaskName' -Confirm:`$false"