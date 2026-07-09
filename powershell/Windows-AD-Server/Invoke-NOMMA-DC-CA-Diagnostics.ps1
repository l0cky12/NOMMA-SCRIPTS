#Requires -Version 5.1
<#
.SYNOPSIS
    Runs NOMMA domain controller and certificate authority diagnostics.

.DESCRIPTION
    Checks the secure channel, current DC, logon server, Kerberos tickets,
    and several certutil queries against NOMMA, NOMMA-DC2023, and NOMMA-DC05.
    Run this from an elevated PowerShell session on Windows.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-Administrator {
    try {
        $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [Security.Principal.WindowsPrincipal]::new($currentIdentity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        return $false
    }
}

function Invoke-DiagnosticCommand {
    param(
        [Parameter(Mandatory)]
        [string]$Title,

        [Parameter(Mandatory)]
        [string]$CommandText,

        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock
    )

    Write-Host ""
    Write-Host ('=' * 88) -ForegroundColor DarkCyan
    Write-Host $Title -ForegroundColor Cyan
    Write-Host ('-' * 88) -ForegroundColor DarkCyan
    Write-Host "Command: $CommandText" -ForegroundColor DarkGray
    Write-Host ""

    try {
        $global:LASTEXITCODE = $null
        & $ScriptBlock
        $exitCode = $LASTEXITCODE

        if ($null -ne $exitCode -and $exitCode -ne 0) {
            Write-Host ""
            Write-Host "Command exited with code $exitCode" -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host ""
        Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    }
}

if (-not (Test-Administrator)) {
    Write-Host "WARNING: Run this script from an elevated PowerShell session for best results." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "NOMMA DC/CA diagnostics starting..." -ForegroundColor Green

Invoke-DiagnosticCommand -Title 'Secure channel query' -CommandText 'nltest /sc_query:NOMMA' -ScriptBlock {
    nltest /sc_query:NOMMA
}

Invoke-DiagnosticCommand -Title 'Domain controller discovery' -CommandText 'nltest /dsgetdc:NOMMA' -ScriptBlock {
    nltest /dsgetdc:NOMMA
}

Invoke-DiagnosticCommand -Title 'Logon server' -CommandText 'cmd /c echo %LOGONSERVER%' -ScriptBlock {
    cmd /c echo %LOGONSERVER%
}

Invoke-DiagnosticCommand -Title 'Kerberos tickets' -CommandText 'klist' -ScriptBlock {
    klist
}

Invoke-DiagnosticCommand -Title 'Certificate templates' -CommandText 'certutil -template' -ScriptBlock {
    certutil -template
}

Invoke-DiagnosticCommand -Title 'Certificate templates from NOMMA-DC2023' -CommandText 'certutil -dc NOMMA-DC2023 -template' -ScriptBlock {
    certutil -dc NOMMA-DC2023 -template
}

Invoke-DiagnosticCommand -Title 'Certificate templates from NOMMA-DC05' -CommandText 'certutil -dc NOMMA-DC05 -template' -ScriptBlock {
    certutil -dc NOMMA-DC05 -template
}

Invoke-DiagnosticCommand -Title 'CA information' -CommandText 'certutil -CAInfo' -ScriptBlock {
    certutil -CAInfo
}

Invoke-DiagnosticCommand -Title 'CA ping' -CommandText 'certutil -ping' -ScriptBlock {
    certutil -ping
}

Invoke-DiagnosticCommand -Title 'AD CA discovery' -CommandText 'certutil -ADCA' -ScriptBlock {
    certutil -ADCA
}

Write-Host ""
Write-Host ('=' * 88) -ForegroundColor DarkCyan
Write-Host 'Diagnostics complete.' -ForegroundColor Green
Write-Host ('=' * 88) -ForegroundColor DarkCyan
