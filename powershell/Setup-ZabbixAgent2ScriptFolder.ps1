# Setup-ZabbixAgent2ScriptFolder.ps1
# Clones the NOMMA Zabbix Windows scripts repo, copies every PowerShell script from scripts/windows
# into the Zabbix Agent 2 script folder, and verifies the result.
#
# Example:
#   .\Setup-ZabbixAgent2ScriptFolder.ps1
#   .\Setup-ZabbixAgent2ScriptFolder.ps1 -WhatIf
#   .\Setup-ZabbixAgent2ScriptFolder.ps1 -SourceRepoUrl "https://github.com/l0cky12/zabbix-windows-ad-dhcp-dns-monitoring.git" -SourceRepoPath "scripts/windows"

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [string]$TargetFolder = 'C:\Program Files\Zabbix Agent 2\Script',
    [string]$SourceRepoUrl = 'https://github.com/l0cky12/zabbix-windows-ad-dhcp-dns-monitoring.git',
    [string]$SourceRepoBranch = 'main',
    [string]$SourceRepoPath = 'scripts/windows',
    [string]$WorkingDirectory = (Join-Path $env:TEMP 'zabbix-windows-scripts-src'),
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

function Assert-GitAvailable {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw 'git is required but was not found in PATH.'
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

function Get-RepoSourcePath {
    param(
        [string]$RepoUrl,
        [string]$Branch,
        [string]$WorkDir,
        [string]$RelativePath
    )

    if (Test-Path -LiteralPath $WorkDir) {
        Write-Info "Removing existing working directory: $WorkDir"
        if ($PSCmdlet.ShouldProcess($WorkDir, 'Remove old working directory')) {
            Remove-Item -LiteralPath $WorkDir -Recurse -Force
        }
    }

    Ensure-Directory -Path $WorkDir

    Write-Info "Cloning $RepoUrl (branch: $Branch)"
    if ($PSCmdlet.ShouldProcess($RepoUrl, 'Clone repository')) {
        git clone --depth 1 --branch $Branch $RepoUrl $WorkDir | Out-Null
    }

    $sourcePath = Join-Path -Path $WorkDir -ChildPath $RelativePath
    if (-not (Test-Path -LiteralPath $sourcePath)) {
        throw "Repository path not found: $sourcePath"
    }

    return $sourcePath
}

function Copy-PowerShellScripts {
    param(
        [string]$From,
        [string]$To,
        [switch]$KeepExisting
    )

    $scripts = Get-ChildItem -LiteralPath $From -Recurse -File -Filter '*.ps1'
    if (-not $scripts) {
        Write-Info "No .ps1 files found in $From"
        return @()
    }

    $copied = New-Object System.Collections.Generic.List[string]
    foreach ($script in $scripts) {
        $relative = $script.FullName.Substring($From.Length).TrimStart('\\','/')
        $destination = Join-Path -Path $To -ChildPath $relative
        $destinationDir = Split-Path -Path $destination -Parent

        Ensure-Directory -Path $destinationDir

        if ($script.FullName -eq $destination) {
            Write-Info "Skipping source file already in target folder: $($script.Name)"
            continue
        }

        if ($KeepExisting -and (Test-Path -LiteralPath $destination)) {
            Write-Info "Skipping existing file: $relative"
            continue
        }

        Write-Info "Copying $relative to $destination"
        if ($PSCmdlet.ShouldProcess($destination, 'Copy script')) {
            Copy-Item -LiteralPath $script.FullName -Destination $destination -Force
        }
        $copied.Add($destination)
    }

    return $copied
}

try {
    Assert-Administrator
    Assert-GitAvailable
    Write-Info "Target folder: $TargetFolder"
    Write-Info "Repo: $SourceRepoUrl"
    Write-Info "Branch: $SourceRepoBranch"
    Write-Info "Repo path: $SourceRepoPath"

    Ensure-Directory -Path $TargetFolder

    $sourcePath = Get-RepoSourcePath -RepoUrl $SourceRepoUrl -Branch $SourceRepoBranch -WorkDir $WorkingDirectory -RelativePath $SourceRepoPath
    try {
        $copied = Copy-PowerShellScripts -From $sourcePath -To $TargetFolder -KeepExisting:$PreserveExistingFiles

        if (-not (Test-Path -LiteralPath $TargetFolder)) {
            throw "Target folder was not created: $TargetFolder"
        }

        $targetItems = Get-ChildItem -LiteralPath $TargetFolder -Recurse -File -Filter '*.ps1'
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
    }
    finally {
        if (Test-Path -LiteralPath $WorkingDirectory) {
            Write-Info "Cleaning up working directory: $WorkingDirectory"
            if ($PSCmdlet.ShouldProcess($WorkingDirectory, 'Remove cloned repository')) {
                Remove-Item -LiteralPath $WorkingDirectory -Recurse -Force
            }
        }
    }

    exit 0
}
catch {
    Write-Error $_
    exit 1
}
