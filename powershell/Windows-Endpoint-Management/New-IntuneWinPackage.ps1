#Requires -Version 5.1
<#
.SYNOPSIS
    Downloads Microsoft's IntuneWinAppUtil and packages one or more installers as .intunewin files.

.EXAMPLE
    .\New-IntuneWinPackage.ps1 -SourcePath C:\Packages\PaperCut.msi

.EXAMPLE
    .\New-IntuneWinPackage.ps1 -SourcePath C:\Packages\Agent.msi, C:\Packages\Helper.exe -OutputFolder C:\Intune\Output
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string[]]$SourcePath,

    [string]$OutputFolder = (Join-Path $PWD 'Output'),

    [string]$ToolFolder = (Join-Path $PSScriptRoot 'tools')
)

$ErrorActionPreference = 'Stop'
$temporaryPath = [IO.Path]::GetTempPath()
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
foreach ($sourceFile in $sourceFiles) {
    $stage = Join-Path $temporaryPath "IntuneWin-$([guid]::NewGuid())"
    try {
        New-Item $stage -ItemType Directory -Force | Out-Null
        Copy-Item $sourceFile $stage
        $setupFile = Split-Path $sourceFile -Leaf
        $package = Join-Path $OutputFolder "$([IO.Path]::GetFileNameWithoutExtension($setupFile)).intunewin"

        if ($PSCmdlet.ShouldProcess($sourceFile, "Package to $package")) {
            & $tool -c $stage -s $setupFile -o $OutputFolder -q
            if ($LASTEXITCODE -ne 0) { throw "IntuneWinAppUtil.exe failed for '$setupFile' with exit code $LASTEXITCODE." }
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
        Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
}
