#Requires -Version 5.1
<#
.SYNOPSIS
    Downloads Microsoft's IntuneWinAppUtil and creates .intunewin packages.

.EXAMPLE
    .\New-IntuneWinPackage.ps1 -SourcePath C:\Packages\PaperCut.msi

.EXAMPLE
    .\New-IntuneWinPackage.ps1 -SourceFolder C:\WazuhPackage -SetupFile Install-Wazuh.ps1 -OutputFolder C:\IntuneWin\Output
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Files')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Files')]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string[]]$SourcePath,

    [Parameter(Mandatory, ParameterSetName = 'Folder')]
    [ValidateScript({ Test-Path $_ -PathType Container })]
    [string]$SourceFolder,

    [Parameter(Mandatory, ParameterSetName = 'Folder')]
    [string]$SetupFile,

    [string]$OutputFolder = (Join-Path $PWD 'Output'),

    [string]$ToolFolder = (Join-Path $PSScriptRoot 'tools')
)

$ErrorActionPreference = 'Stop'
$temporaryPath = [IO.Path]::GetTempPath()

if ($PSCmdlet.ParameterSetName -eq 'Folder') {
    if ($SetupFile -ne (Split-Path $SetupFile -Leaf)) {
        throw 'SetupFile must be a file directly inside SourceFolder.'
    }

    $resolvedFolder = (Resolve-Path $SourceFolder).Path
    if (-not (Test-Path (Join-Path $resolvedFolder $SetupFile) -PathType Leaf)) {
        throw "SetupFile '$SetupFile' was not found in '$resolvedFolder'."
    }

    $jobs = @([pscustomobject]@{
        Source = $resolvedFolder
        Setup = $SetupFile
        Staged = $false
    })
}
else {
    $sourceFiles = foreach ($path in $SourcePath) {
        $sourceFile = (Resolve-Path $path).Path
        $extension = [IO.Path]::GetExtension($sourceFile).ToLowerInvariant()
        if ($extension -notin '.msi', '.exe', '.ps1') {
            throw "SourcePath must contain only .msi, .exe, or .ps1 files; received '$extension'."
        }
        $sourceFile
    }

    $packageNames = @($sourceFiles | ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_) })
    $duplicates = @($packageNames | Group-Object | Where-Object Count -gt 1)
    if ($duplicates) {
        throw "Duplicate output names: $($duplicates.Name -join ', '). Rename one source file or choose separate output folders."
    }

    $jobs = foreach ($sourceFile in $sourceFiles) {
        [pscustomobject]@{
            Source = $sourceFile
            Setup = (Split-Path $sourceFile -Leaf)
            Staged = $true
        }
    }
}

$tool = Join-Path $ToolFolder 'IntuneWinAppUtil.exe'
if (-not (Test-Path $tool)) {
    $zip = Join-Path $temporaryPath 'Microsoft-Win32-Content-Prep-Tool.zip'
    $extract = Join-Path $temporaryPath 'Microsoft-Win32-Content-Prep-Tool'
    if ($PSCmdlet.ShouldProcess($tool, 'Download Microsoft Win32 Content Prep Tool from GitHub')) {
        Remove-Item $extract -Recurse -Force -ErrorAction SilentlyContinue
        Invoke-WebRequest 'https://github.com/Microsoft/Microsoft-Win32-Content-Prep-Tool/archive/refs/heads/master.zip' -OutFile $zip
        Expand-Archive $zip -DestinationPath $extract -Force
        $downloadedTool = Get-ChildItem $extract -Filter 'IntuneWinAppUtil.exe' -Recurse | Select-Object -First 1
        if (-not $downloadedTool) { throw 'IntuneWinAppUtil.exe was not found in the downloaded archive.' }
        New-Item $ToolFolder -ItemType Directory -Force | Out-Null
        Copy-Item $downloadedTool.FullName $tool -Force
    }
}

New-Item $OutputFolder -ItemType Directory -Force | Out-Null
foreach ($job in $jobs) {
    $stage = $null
    try {
        if ($job.Staged) {
            $stage = Join-Path $temporaryPath "IntuneWin-$([guid]::NewGuid())"
            New-Item $stage -ItemType Directory -Force | Out-Null
            Copy-Item $job.Source $stage
            $packageSource = $stage
        }
        else {
            $packageSource = $job.Source
        }

        $package = Join-Path $OutputFolder "$([IO.Path]::GetFileNameWithoutExtension($job.Setup)).intunewin"
        if ($PSCmdlet.ShouldProcess($packageSource, "Package $($job.Setup) to $package")) {
            & $tool -c $packageSource -s $job.Setup -o $OutputFolder -q
            if ($LASTEXITCODE -ne 0) { throw "IntuneWinAppUtil.exe failed for '$($job.Setup)' with exit code $LASTEXITCODE." }
        }

        if ($WhatIfPreference) {
            Write-Host "Would create: $package"
        }
        else {
            if (-not (Test-Path $package)) { throw "Expected package was not created: $package" }
            Write-Host "Created: $package"
        }
    }
    finally {
        if ($stage) { Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
