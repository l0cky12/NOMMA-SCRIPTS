# Setup-ZabbixAgent2ScriptFolder.ps1
# Creates the Zabbix Agent 2 script folder, copies PowerShell scripts into it, and verifies the result.
#
# Example:
#   .\Setup-ZabbixAgent2ScriptFolder.ps1
#   .\Setup-ZabbixAgent2ScriptFolder.ps1 -SourceDirectory "C:\Temp\ZabbixScripts"
#   .\Setup-ZabbixAgent2ScriptFolder.ps1 -WhatIf

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [string]$TargetFolder = 'C:\Program Files\Zabbix Agent 2\Script',
    [string]$SourceDirectory = $PSScriptRoot,
    [switch]$PreserveExistingFiles
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Info {
    param([string]$Message)
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Host "[$timestamp] $Message"
}

function Assert-Administrator {
    $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This script must run as Administrator.'
    }
}

function Ensure-Directory {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Info "Creating folder: $Path"
        if ($PSCmdlet.ShouldProcess($Path, 'Create directory')) {
            New-Item -Path $Path -ItemType Directory -Force | Out-Null
        }
    }
}

function Copy-PowerShellScripts {
    param(
        [string]$From,
        [string]$To,
        [switch]$KeepExisting
    )

    if (-not (Test-Path -LiteralPath $From)) {
        throw "SourceDirectory not found: $From"
    }

    $scripts = Get-ChildItem -LiteralPath $From -File -Filter '*.ps1'
    if (-not $scripts) {
        Write-Info "No .ps1 files found in $From"
        return @()
    }

    $copied = New-Object System.Collections.Generic.List[string]
    foreach ($script in $scripts) {
        $destination = Join-Path -Path $To -ChildPath $script.Name
        if ($script.FullName -eq $destination) {
            Write-Info "Skipping source file already in target folder: $($script.Name)"
            continue
        }

        if ($KeepExisting -and (Test-Path -LiteralPath $destination)) {
            Write-Info "Skipping existing file: $($script.Name)"
            continue
        }

        Write-Info "Copying $($script.Name) to $destination"
        if ($PSCmdlet.ShouldProcess($destination, 'Copy script')) {
            Copy-Item -LiteralPath $script.FullName -Destination $destination -Force
        }
        $copied.Add($destination)
    }

    return $copied
}

try {
    Assert-Administrator
    Write-Info "Target folder: $TargetFolder"
    Write-Info "Source directory: $SourceDirectory"

    Ensure-Directory -Path $TargetFolder
    $copied = Copy-PowerShellScripts -From $SourceDirectory -To $TargetFolder -KeepExisting:$PreserveExistingFiles

    if (-not (Test-Path -LiteralPath $TargetFolder)) {
        throw "Target folder was not created: $TargetFolder"
    }

    $targetItems = Get-ChildItem -LiteralPath $TargetFolder -File -Filter '*.ps1'
    if (-not $targetItems) {
        throw "No PowerShell scripts were found in the target folder: $TargetFolder"
    }

    Write-Info 'Verification: target folder exists.'
    Write-Info "Verification: found $($targetItems.Count) PowerShell script(s) in the target folder."

    if ($copied.Count -gt 0) {
        Write-Info 'Copied files:'
        $copied | ForEach-Object { Write-Host " - $_" }
    }
    else {
        Write-Info 'No files were copied during this run.'
    }

    exit 0
}
catch {
    Write-Error $_
    exit 1
}
