#Requires -Version 5.1
<#
.SYNOPSIS
    Downloads Microsoft's IntuneWinAppUtil and packages one installer as an .intunewin file.

.EXAMPLE
    .\New-IntuneWinPackage.ps1 -SourceFile C:\Packages\PaperCut.msi

.EXAMPLE
    .\New-IntuneWinPackage.ps1 -SourceFile .\install.ps1 -OutputFolder C:\Intune\Output
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$SourceFile,

    [string]$OutputFolder = (Join-Path $PWD 'Output'),

    [string]$ToolFolder = (Join-Path $PSScriptRoot 'tools')
)

$ErrorActionPreference = 'Stop'
$temporaryPath = [IO.Path]::GetTempPath()
$SourceFile = (Resolve-Path $SourceFile).Path
$extension = [IO.Path]::GetExtension($SourceFile).ToLowerInvariant()
if ($extension -notin '.msi', '.exe', '.ps1') {
    throw "SourceFile must be an .msi, .exe, or .ps1 file; received '$extension'."
}

$tool = Join-Path $ToolFolder 'IntuneWinAppUtil.exe'
if (-not (Test-Path $tool)) {
    $zip = Join-Path $temporaryPath 'Microsoft-Win32-Content-Prep-Tool.zip'
    $extract = Join-Path $temporaryPath 'Microsoft-Win32-Content-Prep-Tool'
    if ($PSCmdlet.ShouldProcess($tool, 'Download Microsoft Win32 Content Prep Tool')) {
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
$stage = Join-Path $temporaryPath "IntuneWin-$([guid]::NewGuid())"
try {
    New-Item $stage -ItemType Directory -Force | Out-Null
    Copy-Item $SourceFile $stage
    $setupFile = Split-Path $SourceFile -Leaf

    if ($PSCmdlet.ShouldProcess($SourceFile, "Package to $OutputFolder")) {
        & $tool -c $stage -s $setupFile -o $OutputFolder -q
        if ($LASTEXITCODE -ne 0) { throw "IntuneWinAppUtil.exe failed with exit code $LASTEXITCODE." }
    }

    $package = Join-Path $OutputFolder "$([IO.Path]::GetFileNameWithoutExtension($setupFile)).intunewin"
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
