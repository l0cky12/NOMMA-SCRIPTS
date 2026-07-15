<#
.SYNOPSIS
    Exports the local Windows device to a shared Microsoft Intune Autopilot CSV.

.DESCRIPTION
    Reads the BIOS serial number and Autopilot hardware hash from the local
    MDM bridge WMI provider, then appends one Intune-compatible row to a local
    or UNC CSV file.

    Concurrent writers are serialized with an atomically-created .lock file.
    The script validates an existing CSV before appending and skips a device
    when its serial number or hardware hash is already present.

.PARAMETER CsvPath
    Optional local or UNC path to the Autopilot import CSV. When omitted, the
    script creates or appends to NOMMA-Autopilot.csv in the current directory.

.PARAMETER GroupTag
    Optional Autopilot group tag assigned to this device. Allowed values are:
    Cadet Devices, Teacher Devices, IT Devices, School Administrator Devices.
    When omitted, the Group Tag field is blank.

.PARAMETER LockTimeoutSeconds
    Maximum time to wait for another writer to release the CSV lock.
    The default is 120 seconds.

.EXAMPLE
    .\Export-NOMMAAutopilotDevice.ps1 `
        -CsvPath '\\fileserver\Deployment\Autopilot\NOMMA-Autopilot.csv' `
        -GroupTag 'Cadet Devices'

.EXAMPLE
    .\Export-NOMMAAutopilotDevice.ps1 `
        -CsvPath 'C:\ProgramData\NOMMA\NOMMA-Autopilot.csv' `
        -GroupTag 'Teacher Devices' `
        -LockTimeoutSeconds 300

.OUTPUTS
    PSCustomObject with Result, SerialNumber, HardwareHash, GroupTag, CsvPath,
    and Message properties. Result is Added, SkippedDuplicateSerial,
    SkippedDuplicateHash, or SkippedDuplicateSerialAndHash.

.NOTES
    Requires Windows 10 or Windows 11, Windows PowerShell 5.1, and an elevated
    Administrator session. No PowerShell modules or cloud credentials are used.

    The lock file is <CsvPath>.lock. A timed-out script never removes another
    process's lock. If a device crashed while holding a lock, verify that no
    exporter is active before manually deleting the stale lock file.

    If execution policy blocks a file downloaded from GitHub, the first run can
    use: powershell.exe -ExecutionPolicy Bypass -File .\Export-NOMMAAutopilotDevice.ps1 ...
#>
#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string]$CsvPath = (Join-Path -Path (Get-Location).Path -ChildPath 'NOMMA-Autopilot.csv'),

    [Parameter(Position = 1)]
    [ValidateSet(
        'Cadet Devices',
        'Teacher Devices',
        'IT Devices',
        'School Administrator Devices'
    )]
    [AllowNull()]
    [string]$GroupTag,

    [ValidateRange(1, 3600)]
    [int]$LockTimeoutSeconds = 120
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if (Get-Command -Name Unblock-File -ErrorAction SilentlyContinue) {
    $currentScriptPath = $MyInvocation.MyCommand.Path
    if ($currentScriptPath -and (Test-Path -LiteralPath $currentScriptPath)) {
        try {
            Unblock-File -LiteralPath $currentScriptPath -ErrorAction SilentlyContinue
        }
        catch {
            # Unblocking is best effort; it is not required for normal execution.
        }
    }
}

function Test-IsAdministrator {
    [CmdletBinding()]
    param()

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-NOMMAAutopilotIdentity {
    [CmdletBinding()]
    param()

    $biosRecords = @(Get-CimInstance -ClassName 'Win32_BIOS' -ErrorAction Stop)
    if ($biosRecords.Count -lt 1) {
        throw 'Win32_BIOS returned no records.'
    }

    $serialNumber = ([string]$biosRecords[0].SerialNumber).Trim()
    if ([string]::IsNullOrWhiteSpace($serialNumber)) {
        throw 'The BIOS serial number is empty.'
    }

    $detailRecords = @(
        Get-CimInstance `
            -Namespace 'root/cimv2/mdm/dmmap' `
            -ClassName 'MDM_DevDetail_Ext01' `
            -Filter "InstanceID='Ext' AND ParentID='./DevDetail'" `
            -ErrorAction Stop
    )

    if ($detailRecords.Count -lt 1) {
        throw "MDM_DevDetail_Ext01 returned no Ext record. Confirm the script is running elevated in 64-bit Windows PowerShell."
    }

    $hardwareHash = ([string]$detailRecords[0].DeviceHardwareData).Trim()
    if ([string]::IsNullOrWhiteSpace($hardwareHash)) {
        throw 'MDM_DevDetail_Ext01.DeviceHardwareData is empty.'
    }

    [pscustomobject]@{
        SerialNumber = $serialNumber
        HardwareHash = $hardwareHash
    }
}

function Enter-AtomicFileLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$LockPath,

        [Parameter(Mandatory = $true)]
        [int]$TimeoutSeconds
    )

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()

    while ($true) {
        try {
            $stream = [IO.File]::Open(
                $LockPath,
                [IO.FileMode]::CreateNew,
                [IO.FileAccess]::Write,
                [IO.FileShare]::Read
            )

            $metadata = @(
                "ComputerName=$env:COMPUTERNAME"
                "ProcessId=$PID"
                "AcquiredUtc=$([DateTime]::UtcNow.ToString('o'))"
            ) -join "`r`n"
            $metadataBytes = [Text.Encoding]::UTF8.GetBytes($metadata + "`r`n")
            $stream.Write($metadataBytes, 0, $metadataBytes.Length)
            $stream.Flush()

            return $stream
        }
        catch [IO.IOException] {
            if (-not (Test-Path -LiteralPath $LockPath -PathType Leaf)) {
                throw
            }

            if ($stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                throw "Timed out after $TimeoutSeconds seconds waiting for CSV lock '$LockPath'. The lock was left untouched."
            }

            Start-Sleep -Milliseconds 250
        }
    }
}

function Get-CsvHeaderNames {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $reader = $null
    try {
        $reader = New-Object IO.StreamReader($Path, $true)
        $headerLine = $reader.ReadLine()
    }
    finally {
        if ($null -ne $reader) {
            $reader.Dispose()
        }
    }

    if ([string]::IsNullOrWhiteSpace($headerLine)) {
        return @()
    }

    $probeCsv = $headerLine + "`r`n,,,,"
    $probeRows = @($probeCsv | ConvertFrom-Csv)
    if ($probeRows.Count -ne 1) {
        throw "Could not parse the CSV header in '$Path'."
    }

    return @($probeRows[0].PSObject.Properties.Name)
}

function Assert-AutopilotCsvHeader {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string[]]$ExpectedHeaders
    )

    $actualHeaders = @(Get-CsvHeaderNames -Path $Path)
    $headerMatches = $actualHeaders.Count -eq $ExpectedHeaders.Count

    if ($headerMatches) {
        for ($index = 0; $index -lt $ExpectedHeaders.Count; $index++) {
            if ($actualHeaders[$index] -cne $ExpectedHeaders[$index]) {
                $headerMatches = $false
                break
            }
        }
    }

    if (-not $headerMatches) {
        throw "Existing CSV '$Path' does not have the exact required headers in the required order. No data was written."
    }
}

function Add-CsvLines {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string[]]$Lines,

        [Parameter(Mandatory = $true)]
        [bool]$CreateNew
    )

    $fileStream = $null
    $writer = $null

    try {
        $fileMode = if ($CreateNew) { [IO.FileMode]::CreateNew } else { [IO.FileMode]::Open }
        $fileStream = [IO.File]::Open(
            $Path,
            $fileMode,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::Read
        )

        $needsLeadingNewLine = $false
        if ($fileStream.Length -gt 0) {
            [void]$fileStream.Seek(-1, [IO.SeekOrigin]::End)
            $lastByte = $fileStream.ReadByte()
            $needsLeadingNewLine = ($lastByte -ne 10) -and ($lastByte -ne 13)
        }
        [void]$fileStream.Seek(0, [IO.SeekOrigin]::End)

        $emitBom = $fileStream.Length -eq 0
        $encoding = New-Object Text.UTF8Encoding($emitBom)
        $writer = New-Object IO.StreamWriter($fileStream, $encoding, 4096, $true)

        if ($needsLeadingNewLine) {
            $writer.Write("`r`n")
        }

        foreach ($line in $Lines) {
            $writer.WriteLine($line)
        }

        $writer.Flush()
        $fileStream.Flush($true)
    }
    finally {
        if ($null -ne $writer) {
            $writer.Dispose()
        }
        if ($null -ne $fileStream) {
            $fileStream.Dispose()
        }
    }
}

$expectedHeaders = @(
    'Device Serial Number',
    'Windows Product ID',
    'Hardware Hash',
    'Group Tag',
    'Assigned User'
)

$lockStream = $null
$lockAcquired = $false
$resolvedCsvPath = $null
$lockPath = $null
$result = $null
$failureMessage = $null
$exitCode = 0

try {
    if (-not (Test-IsAdministrator)) {
        throw 'This script must be run from an elevated Administrator session.'
    }

    $resolvedCsvPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($CsvPath)
    $csvDirectory = Split-Path -Path $resolvedCsvPath -Parent

    if ([string]::IsNullOrWhiteSpace($csvDirectory) -or -not (Test-Path -LiteralPath $csvDirectory -PathType Container)) {
        throw "The CSV parent directory does not exist or is unavailable: '$csvDirectory'."
    }

    if (Test-Path -LiteralPath $resolvedCsvPath -PathType Container) {
        throw "CsvPath points to a directory, not a file: '$resolvedCsvPath'."
    }

    $deviceIdentity = Get-NOMMAAutopilotIdentity
    $lockPath = $resolvedCsvPath + '.lock'
    $lockStream = Enter-AtomicFileLock -LockPath $lockPath -TimeoutSeconds $LockTimeoutSeconds
    $lockAcquired = $true

    $csvExists = Test-Path -LiteralPath $resolvedCsvPath -PathType Leaf
    $csvHasContent = $csvExists -and ((Get-Item -LiteralPath $resolvedCsvPath).Length -gt 0)
    $existingRows = @()

    if ($csvHasContent) {
        Assert-AutopilotCsvHeader -Path $resolvedCsvPath -ExpectedHeaders $expectedHeaders
        $existingRows = @(Import-Csv -LiteralPath $resolvedCsvPath -ErrorAction Stop)
    }

    $serialDuplicate = @(
        $existingRows | Where-Object {
            ([string]$_.'Device Serial Number').Trim() -ieq $deviceIdentity.SerialNumber
        }
    ).Count -gt 0

    $hashDuplicate = @(
        $existingRows | Where-Object {
            ([string]$_.'Hardware Hash').Trim() -ceq $deviceIdentity.HardwareHash
        }
    ).Count -gt 0

    if ($serialDuplicate -or $hashDuplicate) {
        if ($serialDuplicate -and $hashDuplicate) {
            $duplicateResult = 'SkippedDuplicateSerialAndHash'
            $duplicateMessage = 'Skipped: both the serial number and hardware hash already exist in the CSV.'
        }
        elseif ($serialDuplicate) {
            $duplicateResult = 'SkippedDuplicateSerial'
            $duplicateMessage = 'Skipped: the serial number already exists in the CSV.'
        }
        else {
            $duplicateResult = 'SkippedDuplicateHash'
            $duplicateMessage = 'Skipped: the hardware hash already exists in the CSV.'
        }

        $result = [pscustomobject]@{
            Result       = $duplicateResult
            SerialNumber = $deviceIdentity.SerialNumber
            HardwareHash = $deviceIdentity.HardwareHash
            GroupTag     = $GroupTag
            CsvPath      = $resolvedCsvPath
            Message      = $duplicateMessage
        }
    }
    else {
        $newRow = [pscustomobject][ordered]@{
            'Device Serial Number' = $deviceIdentity.SerialNumber
            'Windows Product ID'   = ''
            'Hardware Hash'        = $deviceIdentity.HardwareHash
            'Group Tag'            = $GroupTag
            'Assigned User'        = ''
        }

        $convertedLines = @($newRow | ConvertTo-Csv -NoTypeInformation)
        if ($convertedLines.Count -ne 2) {
            throw 'Failed to generate exactly one Autopilot CSV row.'
        }

        if ($csvHasContent) {
            Add-CsvLines -Path $resolvedCsvPath -Lines @($convertedLines[1]) -CreateNew $false
        }
        elseif ($csvExists) {
            Add-CsvLines -Path $resolvedCsvPath -Lines $convertedLines -CreateNew $false
        }
        else {
            Add-CsvLines -Path $resolvedCsvPath -Lines $convertedLines -CreateNew $true
        }

        $result = [pscustomobject]@{
            Result       = 'Added'
            SerialNumber = $deviceIdentity.SerialNumber
            HardwareHash = $deviceIdentity.HardwareHash
            GroupTag     = $GroupTag
            CsvPath      = $resolvedCsvPath
            Message      = 'Added one device row to the Autopilot CSV.'
        }
    }
}
catch {
    $exitCode = 1
    $failureMessage = $_.Exception.Message
}
finally {
    if ($null -ne $lockStream) {
        $lockStream.Dispose()
    }

    if ($lockAcquired -and $lockPath) {
        try {
            Remove-Item -LiteralPath $lockPath -Force -ErrorAction Stop
        }
        catch {
            Write-Warning "Failed to remove owned lock file '$lockPath': $($_.Exception.Message)"
        }
    }
}

if ($exitCode -ne 0) {
    Write-Error -Message "Export-NOMMAAutopilotDevice failed: $failureMessage" -ErrorAction Continue
}
else {
    Write-Output $result
}

exit $exitCode
