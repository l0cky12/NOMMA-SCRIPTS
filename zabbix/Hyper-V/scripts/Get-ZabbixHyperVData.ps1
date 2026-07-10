<#
.SYNOPSIS
Collects lean Hyper-V, Hyper-V Replica, cluster, storage, network, certificate, and backup health as JSON.
.DESCRIPTION
One PowerShell process supplies a Zabbix master item. All other metrics are dependent items.
The script is read-only and returns JSON even when Hyper-V is absent or collection fails.
.EXAMPLE
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Get-ZabbixHyperVData.ps1 -ConfigPath .\hyperv-monitoring.json
.NOTES
Compatible with Windows PowerShell 5.1. Run the first downloaded invocation with -ExecutionPolicy Bypass.
#>
[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Pretty', Justification = 'Read by the nested Write-Result helper through script scope.')]
param(
    [Parameter()]
    [string]$ConfigPath = 'C:\Program Files\Zabbix Agent 2\scripts\Hyper-V\hyperv-monitoring.json',

    [Parameter(DontShow)]
    [string]$FixturePath,

    [Parameter(DontShow)]
    [string]$Scenario,

    [Parameter()]
    [switch]$Pretty
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function ConvertTo-EpochSecond {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return 0 }
    try {
        $date = [DateTime]$Value
        return [int64]([DateTimeOffset]$date.ToUniversalTime()).ToUnixTimeSeconds()
    }
    catch { return 0 }
}

function Get-ObjectProperty {
    param(
        [AllowNull()][object]$InputObject,
        [Parameter(Mandatory)][string[]]$Names,
        [AllowNull()][object]$Default = $null
    )
    if ($null -eq $InputObject) { return $Default }
    foreach ($name in $Names) {
        $property = $InputObject.PSObject.Properties[$name]
        if ($null -ne $property -and $null -ne $property.Value) { return $property.Value }
    }
    return $Default
}

function ConvertTo-Integer {
    param([AllowNull()][object]$Value, [int64]$Default = 0)
    try { return [int64]$Value } catch { return $Default }
}

function ConvertTo-Double {
    param([AllowNull()][object]$Value, [double]$Default = 0)
    try { return [math]::Round([double]$Value, 2) } catch { return $Default }
}

function Get-ServiceState {
    param([Parameter(Mandatory)][string]$Name)
    try {
        $service = Get-Service -Name $Name -ErrorAction Stop
        if ([string]$service.Status -eq 'Running') { return 1 }
        return 0
    }
    catch { return -1 }
}

function Convert-VMState {
    param([AllowNull()][object]$State)
    switch ([string]$State) {
        'Off' { return 0 }
        'Running' { return 1 }
        'Paused' { return 2 }
        'Saved' { return 3 }
        'Starting' { return 4 }
        'Stopping' { return 5 }
        'Critical' { return 6 }
        default { return 7 }
    }
}

function Convert-ReplicationHealth {
    param([AllowNull()][object]$Health)
    switch ([string]$Health) {
        'Normal' { return 1 }
        'Warning' { return 2 }
        'Critical' { return 3 }
        default { return 0 }
    }
}

function ConvertTo-ReplicaState {
    param([AllowNull()][object]$Value)
    switch ([string]$Value) {
        'Replicating' { return 1 }
        'PreparedForFailover' { return 2 }
        'Resynchronizing' { return 3 }
        'Suspended' { return 4 }
        'Error' { return 5 }
        'UpdateError' { return 5 }
        'ReadyForInitialReplication' { return 6 }
        'WaitingForInitialReplication' { return 7 }
        'WaitingForStartResynchronize' { return 8 }
        'ResynchronizeSuspended' { return 9 }
        'RecoveryInProgress' { return 10 }
        'FailbackInProgress' { return 11 }
        'FailbackComplete' { return 12 }
        'InitialReplicationInProgress' { return 13 }
        'FailedOverWaitingCompletion' { return 14 }
        'FailedOver' { return 15 }
        'WaitingForUpdateCompletion' { return 16 }
        'WaitingForRepurposeCompletion' { return 17 }
        'PreparedForSyncReplication' { return 18 }
        'PreparedForGroupReverseReplication' { return 19 }
        'FiredrillInProgress' { return 20 }
        'Disabled' { return 21 }
        default { return 0 }
    }
}

function Get-HeartbeatState {
    param([Parameter(Mandatory)][object]$VM)
    # Heartbeat integration service ID is invariant; display names are localized.
    $heartbeatId = '84EAAE65-2F2E-45F5-9BB5-0E857DC8EB47'
    try {
        $service = Get-VMIntegrationService -VM $VM -ErrorAction Stop |
            Where-Object { ([string](Get-ObjectProperty $_ @('Id') '')).Trim('{}') -ieq $heartbeatId } |
            Select-Object -First 1
        if ($null -eq $service -or -not [bool](Get-ObjectProperty $service @('Enabled') $false)) { return 0 }
        $status = [string](Get-ObjectProperty $service @('PrimaryOperationalStatus','OperationalStatus') '')
        if ($status -match 'Ok|OperatingNormally') { return 1 }
        if ($status -match 'Degraded|ProtocolMismatch') { return 2 }
        return 0
    }
    catch { return -1 }
}

function Read-Config {
    param([string]$Path)
    $defaults = [ordered]@{
        eventLookbackMinutes = 10
        excludeVolumeLabelRegex = '^(Recovery|System Reserved)$'
        minimumVolumeSizeBytes = 1073741824
        certificateThumbprints = @()
        backupProvider = 'Auto'
        backupStatusFile = ''
        criticalEventLogs = @(
            'Microsoft-Windows-Hyper-V-VMMS-Admin',
            'Microsoft-Windows-Hyper-V-Worker-Admin',
            'Microsoft-Windows-Hyper-V-High-Availability-Admin',
            'Microsoft-Windows-Hyper-V-StorageVSP-Admin'
        )
    }
    if (-not [string]::IsNullOrWhiteSpace($Path) -and (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $loaded = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        foreach ($key in @($defaults.Keys)) {
            $value = Get-ObjectProperty $loaded @($key) $null
            if ($null -ne $value) { $defaults[$key] = $value }
        }
    }
    return [pscustomobject]$defaults
}

function Write-Result {
    param([Parameter(Mandatory)][object]$Data)
    $json = if ($script:Pretty) { $Data | ConvertTo-Json -Depth 12 } else { $Data | ConvertTo-Json -Depth 12 -Compress }
    Write-Output $json
}

if (-not [string]::IsNullOrWhiteSpace($FixturePath)) {
    try {
        $fixture = Get-Content -LiteralPath $FixturePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $entry = @($fixture.scenarios | Where-Object { [string]$_.name -eq $Scenario }) | Select-Object -First 1
        if ($null -eq $entry) { throw "Fixture scenario '$Scenario' was not found." }
        Write-Result -Data $entry.data
        exit 0
    }
    catch {
        Write-Result -Data ([ordered]@{ schema_version = 1; collector = [ordered]@{ ok = 0; error = $_.Exception.Message; timestamp = ConvertTo-EpochSecond (Get-Date); duration_ms = 0 } })
        exit 1
    }
}

$timer = [Diagnostics.Stopwatch]::StartNew()
$componentErrors = New-Object System.Collections.Generic.List[string]
$result = [ordered]@{
    schema_version = 1
    collector = [ordered]@{ ok = 1; error = ''; timestamp = ConvertTo-EpochSecond (Get-Date); duration_ms = 0; component_errors = @() }
    host = [ordered]@{
        role_installed = 0; vmms_service = -1; vmcompute_service = -1
        vm_total = 0; vm_running = 0; vm_critical = 0
        replication_enabled = 0; replica_total = 0; replica_normal = 0; replica_warning = 0; replica_critical = 0; oldest_replication_lag_seconds = 0
        cluster_present = 0; cluster_service = -1; cluster_node_up = -1; replica_broker_present = 0; replica_broker_online = -1
        csv_total = 0; csv_unhealthy = 0; external_switch_total = 0; external_switch_down = 0
        volume_min_free_percent = 100; critical_event_count = 0; last_critical_event_age_seconds = 0
        cpu_percent = 0; memory_available_percent = 0; certificate_min_days = 99999
    }
    backup = [ordered]@{ enabled = 0; provider = 'None'; status = 0; age_seconds = 0; last_success_epoch = 0 }
    vms = @(); replicas = @(); volumes = @(); csvs = @(); switches = @(); certificates = @()
}

try {
    $config = Read-Config -Path $ConfigPath
    $result.host.vmms_service = Get-ServiceState -Name 'vmms'
    $result.host.vmcompute_service = Get-ServiceState -Name 'vmcompute'
    $getVmCommand = Get-Command -Name Get-VM -ErrorAction SilentlyContinue
    $result.host.role_installed = if ($null -ne $getVmCommand -or $result.host.vmms_service -ne -1) { 1 } else { 0 }

    if ($result.host.role_installed -eq 1) {
        try {
            $allVms = @(Get-VM -ErrorAction Stop)
            foreach ($vm in $allVms) {
                $id = ([string]$vm.Id).ToLowerInvariant()
                $stateCode = Convert-VMState $vm.State
                $statusText = [string](Get-ObjectProperty $vm @('Status','PrimaryStatusDescription') '')
                $healthCode = if ($statusText -match 'Critical|Error|Failed') { 0 } else { 1 }
                $result.vms += [ordered]@{
                    '{#VMID}' = $id; '{#VMNAME}' = [string]$vm.Name
                    id = $id; name = [string]$vm.Name; state = $stateCode; health = $healthCode
                    heartbeat = Get-HeartbeatState -VM $vm
                    uptime_seconds = ConvertTo-Integer (Get-ObjectProperty $vm @('Uptime') 0).TotalSeconds 0
                    status = $statusText
                }
            }
            $result.host.vm_total = @($result.vms).Count
            $result.host.vm_running = @($result.vms | Where-Object { $_.state -eq 1 }).Count
            $result.host.vm_critical = @($result.vms | Where-Object { $_.health -eq 0 -or $_.state -eq 6 }).Count
        }
        catch {
            $result.collector.ok = 0
            $result.collector.error = "Get-VM failed: $($_.Exception.Message)"
        }

        try {
            $server = Get-VMReplicationServer -ErrorAction Stop
            $result.host.replication_enabled = if ([bool](Get-ObjectProperty $server @('ReplicationEnabled') $false)) { 1 } else { 0 }
        }
        catch {
            $componentErrors.Add("Replication server query: $($_.Exception.Message)")
        }

        if (Get-Command -Name Get-VMReplication -ErrorAction SilentlyContinue) {
            try {
                $relationships = @(Get-VMReplication -ErrorAction Stop)
                foreach ($relationship in $relationships) {
                    $vmId = ([string](Get-ObjectProperty $relationship @('VMId','Id') '')).ToLowerInvariant()
                    $statistics = $null
                    try { $statistics = Measure-VMReplication -VMName ([string]$relationship.VMName) -ErrorAction Stop } catch { Write-Verbose "Replication statistics unavailable for $($relationship.VMName): $($_.Exception.Message)" }
                    $lastReplication = Get-ObjectProperty $statistics @('LastReplicationTime') (Get-ObjectProperty $relationship @('LastReplicationTime','LastApplyTime') $null)
                    $lastEpoch = ConvertTo-EpochSecond $lastReplication
                    $lag = if ($lastEpoch -gt 0) { [math]::Max(0, (ConvertTo-EpochSecond (Get-Date)) - $lastEpoch) } else { 0 }
                    $errorsValue = Get-ObjectProperty $statistics @('ReplicationErrors','ErrorCount') 0
                    $errorCount = if ($errorsValue -is [System.Collections.ICollection]) { $errorsValue.Count } else { ConvertTo-Integer $errorsValue 0 }
                    $backlog = ConvertTo-Integer (Get-ObjectProperty $statistics @('PendingReplicationSize','PendingDataSize','BacklogSize') 0) 0
                    $healthCode = Convert-ReplicationHealth (Get-ObjectProperty $relationship @('ReplicationHealth','Health') '')
                    $stateCode = ConvertTo-ReplicaState (Get-ObjectProperty $relationship @('ReplicationState','State') '')
                    $isResync = if ($stateCode -in @(3,8,9)) { 1 } else { 0 }
                    $ready = if ($healthCode -eq 1 -and $stateCode -in @(1,2) -and $lastEpoch -gt 0) { 1 } else { 0 }
                    $result.replicas += [ordered]@{
                        '{#REPLICAID}' = $vmId; '{#REPLICANAME}' = [string]$relationship.VMName
                        id = $vmId; name = [string]$relationship.VMName
                        health = $healthCode; state = $stateCode
                        mode = [string](Get-ObjectProperty $relationship @('ReplicationMode','Mode','ReplicationRelationshipType') 'Unknown')
                        last_replication_epoch = $lastEpoch; lag_seconds = $lag; errors = $errorCount
                        backlog_bytes = $backlog; resynchronizing = $isResync; failover_ready = $ready
                    }
                }
            }
            catch { $componentErrors.Add("Get-VMReplication failed: $($_.Exception.Message)") }
        }
    }

    $result.host.replica_total = @($result.replicas).Count
    $result.host.replica_normal = @($result.replicas | Where-Object { $_.health -eq 1 }).Count
    $result.host.replica_warning = @($result.replicas | Where-Object { $_.health -eq 2 }).Count
    $result.host.replica_critical = @($result.replicas | Where-Object { $_.health -eq 3 }).Count
    if ($result.host.replica_total -gt 0) { $result.host.oldest_replication_lag_seconds = ConvertTo-Integer (($result.replicas | Measure-Object -Property lag_seconds -Maximum).Maximum) 0 }

    try {
        $clusterService = Get-ServiceState -Name 'ClusSvc'
        $result.host.cluster_service = $clusterService
        if ($clusterService -ne -1) {
            $result.host.cluster_present = 1
            if (Get-Command -Name Get-ClusterNode -ErrorAction SilentlyContinue) {
                $localNode = Get-ClusterNode -Name $env:COMPUTERNAME -ErrorAction Stop
                $result.host.cluster_node_up = if ([string]$localNode.State -eq 'Up') { 1 } else { 0 }
                $brokerResources = @(Get-ClusterResource -ErrorAction Stop | Where-Object { [string]$_.ResourceType -eq 'Virtual Machine Replication Broker' })
                if ($brokerResources.Count -gt 0) {
                    $result.host.replica_broker_present = 1
                    $result.host.replica_broker_online = if (@($brokerResources | Where-Object { [string]$_.State -ne 'Online' }).Count -eq 0) { 1 } else { 0 }
                }
                foreach ($csv in @(Get-ClusterSharedVolume -ErrorAction Stop)) {
                    $info = @($csv.SharedVolumeInfo) | Select-Object -First 1
                    $partition = Get-ObjectProperty $info @('Partition') $null
                    $size = ConvertTo-Integer (Get-ObjectProperty $partition @('Size') 0) 0
                    $free = ConvertTo-Integer (Get-ObjectProperty $partition @('FreeSpace') 0) 0
                    $freePct = if ($size -gt 0) { [math]::Round(($free / $size) * 100, 2) } else { 0 }
                    $state = if ([string]$csv.State -eq 'Online') { 1 } else { 0 }
                    $csvId = ([string]$csv.Name).ToLowerInvariant()
                    $result.csvs += [ordered]@{ '{#CSVID}' = $csvId; '{#CSVNAME}' = [string]$csv.Name; id = $csvId; name = [string]$csv.Name; state = $state; free_percent = $freePct; size_bytes = $size }
                }
            }
        }
    }
    catch { $componentErrors.Add("Cluster query: $($_.Exception.Message)") }
    $result.host.csv_total = @($result.csvs).Count
    $result.host.csv_unhealthy = @($result.csvs | Where-Object { $_.state -ne 1 }).Count

    try {
        if (Get-Command -Name Get-VMSwitch -ErrorAction SilentlyContinue) {
            foreach ($switch in @(Get-VMSwitch -SwitchType External -ErrorAction Stop)) {
                $status = 0
                $description = [string](Get-ObjectProperty $switch @('NetAdapterInterfaceDescription') '')
                if (-not [string]::IsNullOrWhiteSpace($description) -and (Get-Command -Name Get-NetAdapter -ErrorAction SilentlyContinue)) {
                    $adapters = @(Get-NetAdapter -InterfaceDescription $description -ErrorAction SilentlyContinue)
                    if (@($adapters | Where-Object { [string]$_.Status -eq 'Up' }).Count -gt 0) { $status = 1 }
                }
                $switchId = ([string]$switch.Id).ToLowerInvariant()
                $result.switches += [ordered]@{ '{#SWITCHID}' = $switchId; '{#SWITCHNAME}' = [string]$switch.Name; id = $switchId; name = [string]$switch.Name; up = $status; adapter = $description }
            }
        }
    }
    catch { $componentErrors.Add("External switch query: $($_.Exception.Message)") }
    $result.host.external_switch_total = @($result.switches).Count
    $result.host.external_switch_down = @($result.switches | Where-Object { $_.up -ne 1 }).Count

    try {
        foreach ($volume in @(Get-CimInstance -ClassName Win32_Volume -Filter 'DriveType=3' -ErrorAction Stop)) {
            $size = ConvertTo-Integer $volume.Capacity 0
            if ($size -lt (ConvertTo-Integer $config.minimumVolumeSizeBytes 1073741824)) { continue }
            if ([string]$volume.Label -match [string]$config.excludeVolumeLabelRegex) { continue }
            $free = ConvertTo-Integer $volume.FreeSpace 0
            $freePct = if ($size -gt 0) { [math]::Round(($free / $size) * 100, 2) } else { 0 }
            $id = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$volume.DeviceID)).TrimEnd('=').Replace('+','-').Replace('/','_')
            $display = if (-not [string]::IsNullOrWhiteSpace([string]$volume.DriveLetter)) { [string]$volume.DriveLetter } elseif (-not [string]::IsNullOrWhiteSpace([string]$volume.Label)) { [string]$volume.Label } else { [string]$volume.DeviceID }
            $result.volumes += [ordered]@{ '{#VOLUMEID}' = $id; '{#VOLUMENAME}' = $display; id = $id; name = $display; free_percent = $freePct; free_bytes = $free; size_bytes = $size }
        }
    }
    catch { $componentErrors.Add("Volume query: $($_.Exception.Message)") }
    if (@($result.volumes).Count -gt 0) { $result.host.volume_min_free_percent = ConvertTo-Double (($result.volumes | Measure-Object -Property free_percent -Minimum).Minimum) 100 }

    try {
        $thumbprints = @($config.certificateThumbprints | ForEach-Object { ([string]$_).Replace(' ','').ToUpperInvariant() } | Where-Object { $_ })
        foreach ($thumbprint in $thumbprints) {
            $cert = Get-ChildItem -Path Cert:\LocalMachine\My -ErrorAction Stop | Where-Object { ([string]$_.Thumbprint).ToUpperInvariant() -eq $thumbprint } | Select-Object -First 1
            if ($null -eq $cert) {
                $result.certificates += [ordered]@{ '{#CERTID}' = $thumbprint; '{#CERTNAME}' = $thumbprint; id = $thumbprint; subject = 'Not found'; days_remaining = -1; valid = 0 }
                continue
            }
            $days = [math]::Floor(($cert.NotAfter.ToUniversalTime() - (Get-Date).ToUniversalTime()).TotalDays)
            $valid = if ($cert.NotBefore -le (Get-Date) -and $cert.NotAfter -gt (Get-Date)) { 1 } else { 0 }
            $result.certificates += [ordered]@{ '{#CERTID}' = $thumbprint; '{#CERTNAME}' = [string]$cert.Subject; id = $thumbprint; subject = [string]$cert.Subject; days_remaining = $days; valid = $valid }
        }
    }
    catch { $componentErrors.Add("Certificate query: $($_.Exception.Message)") }
    if (@($result.certificates).Count -gt 0) { $result.host.certificate_min_days = ConvertTo-Integer (($result.certificates | Measure-Object -Property days_remaining -Minimum).Minimum) 99999 }

    try {
        $provider = [string]$config.backupProvider
        if (($provider -eq 'File' -or $provider -eq 'Auto') -and -not [string]::IsNullOrWhiteSpace([string]$config.backupStatusFile) -and (Test-Path -LiteralPath ([string]$config.backupStatusFile))) {
            $stamp = Get-Content -LiteralPath ([string]$config.backupStatusFile) -Raw | ConvertFrom-Json
            $epoch = ConvertTo-EpochSecond (Get-ObjectProperty $stamp @('completedUtc','lastSuccessUtc') $null)
            $result.backup.enabled = 1; $result.backup.provider = 'StatusFile'; $result.backup.last_success_epoch = $epoch
            $result.backup.age_seconds = if ($epoch -gt 0) { [math]::Max(0, (ConvertTo-EpochSecond (Get-Date)) - $epoch) } else { 0 }
            $result.backup.status = if ([string](Get-ObjectProperty $stamp @('status') '') -match 'Success|Completed|OK') { 1 } else { 3 }
        }
        elseif (($provider -eq 'WindowsServerBackup' -or $provider -eq 'Auto') -and (Get-Command -Name Get-WBJob -ErrorAction SilentlyContinue)) {
            $job = Get-WBJob -Previous 1 -ErrorAction Stop
            if ($null -ne $job) {
                $state = [string](Get-ObjectProperty $job @('JobState') '')
                $end = Get-ObjectProperty $job @('EndTime') $null
                $epoch = ConvertTo-EpochSecond $end
                $result.backup.enabled = 1; $result.backup.provider = 'WindowsServerBackup'; $result.backup.last_success_epoch = $epoch
                $result.backup.age_seconds = if ($epoch -gt 0) { [math]::Max(0, (ConvertTo-EpochSecond (Get-Date)) - $epoch) } else { 0 }
                $result.backup.status = if ($state -match 'Completed|Success') { 1 } elseif ($state -match 'Running') { 2 } else { 3 }
            }
        }
    }
    catch { $componentErrors.Add("Backup query: $($_.Exception.Message)") }

    try {
        $startTime = (Get-Date).AddMinutes(-1 * (ConvertTo-Integer $config.eventLookbackMinutes 10))
        $events = @()
        foreach ($logName in @($config.criticalEventLogs)) {
            try { $events += @(Get-WinEvent -FilterHashtable @{ LogName = [string]$logName; Level = 1,2; StartTime = $startTime } -ErrorAction Stop) } catch { Write-Verbose "Event log unavailable: $logName" }
        }
        $result.host.critical_event_count = @($events).Count
        if (@($events).Count -gt 0) {
            $latest = $events | Sort-Object TimeCreated -Descending | Select-Object -First 1
            $result.host.last_critical_event_age_seconds = [math]::Max(0, (ConvertTo-EpochSecond (Get-Date)) - (ConvertTo-EpochSecond $latest.TimeCreated))
        }
    }
    catch { $componentErrors.Add("Event log query: $($_.Exception.Message)") }

    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $totalMemory = ConvertTo-Double $os.TotalVisibleMemorySize 0
        $freeMemory = ConvertTo-Double $os.FreePhysicalMemory 0
        if ($totalMemory -gt 0) { $result.host.memory_available_percent = [math]::Round(($freeMemory / $totalMemory) * 100, 2) }
        $cpu = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction Stop
        $result.host.cpu_percent = ConvertTo-Double $cpu.PercentProcessorTime 0
    }
    catch { $componentErrors.Add("Capacity query: $($_.Exception.Message)") }
}
catch {
    $result.collector.ok = 0
    $result.collector.error = $_.Exception.Message
}
finally {
    $timer.Stop()
    $result.collector.duration_ms = $timer.ElapsedMilliseconds
    $result.collector.component_errors = @($componentErrors)
    Write-Result -Data $result
}
