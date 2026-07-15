<#
.SYNOPSIS
    Creates a SAN-correct HTTPS certificate package for a Brother printer.
.DESCRIPTION
    Run elevated on the Issuing CA. Creates a Windows machine key and CSR with a
    DNS SAN, submits it to the configured Enterprise CA template, validates the
    issued certificate, accepts it, and exports a password-protected PFX for
    Brother's "Import Certificate and Private Key" page.

    This script does not alter CA settings, templates, services, DNS, or the
    printer. The named template must already be published and grant the running
    account Read + Enroll.
.NOTES
    The PFX contains a private key. Copy it directly to the printer's admin
    workstation, import it, then delete it securely after a successful test.
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$PrinterHost,
    [string]$CAConfig,
    [string]$Template = 'PrinterHTTPS',
    [string]$OutputDirectory = 'C:\Temp\BrotherTLS'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($PrinterHost)) {
    $PrinterHost = Read-Host 'Enter the printer DNS name (for example, b-4024.nomma.tech)'
}

$PrinterHost = $PrinterHost.Trim().TrimEnd('.')
if ($PrinterHost -notmatch '^(?=.{1,253}$)([A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$') {
    Write-Host "FAIL: '$PrinterHost' is not a valid fully qualified DNS name." -ForegroundColor Red
    exit 1
}

function Fail([string]$Message) {
    Write-Host "FAIL: $Message" -ForegroundColor Red
    exit 1
}

function Invoke-Certreq {
    param([string[]]$Arguments)
    $output = & certreq.exe @Arguments 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        Fail ("certreq failed with exit code {0}:`n{1}" -f $LASTEXITCODE, $output)
    }
    return $output
}

$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)
if (-not $isAdmin) { Fail 'Run this script from an elevated PowerShell session.' }

if (-not (Get-Command certreq.exe -ErrorAction SilentlyContinue)) { Fail 'certreq.exe was not found.' }

if ([string]::IsNullOrWhiteSpace($CAConfig)) {
    $certSvc = Get-Service -Name CertSvc -ErrorAction SilentlyContinue
    if ($null -eq $certSvc) { Fail 'AD CS (CertSvc) is not installed. Run this script on the Issuing CA.' }
    if ($certSvc.Status -ne 'Running') { Fail 'AD CS (CertSvc) is not running. Run this script on the active Issuing CA.' }

    $activeCA = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration' -Name Active -ErrorAction Stop).Active
    if ([string]::IsNullOrWhiteSpace($activeCA)) { Fail 'Could not determine the local active CA name.' }

    $CAConfig = "$env:COMPUTERNAME\$activeCA"
    Write-Host "Using local CA: $CAConfig" -ForegroundColor Cyan
}

$templateList = & certutil.exe -CATemplates 2>&1 | Out-String
if ($LASTEXITCODE -ne 0 -or $templateList -notmatch [regex]::Escape($Template)) {
    Fail "Template '$Template' is not published on this CA. Publish it first and ensure the CA computer account has Read permission."
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$SafeName = $PrinterHost -replace '[^A-Za-z0-9.-]', '_'
$InfPath = Join-Path $OutputDirectory "$SafeName.inf"
$ReqPath = Join-Path $OutputDirectory "$SafeName.req"
$CerPath = Join-Path $OutputDirectory "$SafeName.cer"
$PfxPath = Join-Path $OutputDirectory "$SafeName.pfx"

if ((Test-Path $ReqPath) -or (Test-Path $CerPath) -or (Test-Path $PfxPath)) {
    Fail "Output files already exist in $OutputDirectory. Move or delete the old request/certificate/PFX before continuing."
}

$Inf = @"
[Version]
Signature="`$Windows NT`$"

[NewRequest]
Subject = "CN=$PrinterHost"
KeyLength = 2048
KeyAlgorithm = RSA
HashAlgorithm = sha256
Exportable = TRUE
MachineKeySet = TRUE
ProviderName = "Microsoft Enhanced RSA and AES Cryptographic Provider"
ProviderType = 24
RequestType = PKCS10
KeyUsage = 0xa0

[Extensions]
2.5.29.17 = "{text}"
_continue_ = "dns=$PrinterHost"

[RequestAttributes]
CertificateTemplate = "$Template"
"@

Set-Content -Path $InfPath -Value $Inf -Encoding Ascii -NoNewline

Write-Host "Creating CSR for $PrinterHost..." -ForegroundColor Cyan
Invoke-Certreq @('-new', '-machine', $InfPath, $ReqPath) | Write-Host

Write-Host "Submitting CSR to $CAConfig using template $Template..." -ForegroundColor Cyan
$SubmitOutput = Invoke-Certreq @('-submit', '-config', $CAConfig, $ReqPath, $CerPath)
$SubmitOutput | Write-Host

if (-not (Test-Path $CerPath)) {
    $requestIdMatch = [regex]::Match($SubmitOutput, '(?im)RequestId:\s*(\d+)')
    if ($requestIdMatch.Success) {
        Write-Host "Request is pending. Issue Request ID $($requestIdMatch.Groups[1].Value) in certsrv.msc, then run:" -ForegroundColor Yellow
        Write-Host "certreq -retrieve -config `"$CAConfig`" $($requestIdMatch.Groups[1].Value) `"$CerPath`"" -ForegroundColor Yellow
        exit 2
    }
    Fail 'The CA did not create the certificate file and no Request ID was found.'
}

$IssuedCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($CerPath)
$San = @($IssuedCert.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.17' })
$Eku = @($IssuedCert.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.37' })
$HasDnsSan = $San | Where-Object { $_.Format($true) -match [regex]::Escape($PrinterHost) }
$HasServerAuth = $Eku | Where-Object { $_.Format($true) -match '1\.3\.6\.1\.5\.5\.7\.3\.1|Server Authentication' }

if (-not $HasDnsSan) { Fail "Issued certificate has no DNS SAN for $PrinterHost. PFX was not created." }
if (-not $HasServerAuth) { Fail 'Issued certificate lacks Server Authentication EKU. PFX was not created.' }

Write-Host 'Certificate validation passed: correct SAN and Server Authentication EKU.' -ForegroundColor Green
Invoke-Certreq @('-accept', '-machine', $CerPath) | Write-Host

$StoreCert = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Thumbprint -eq $IssuedCert.Thumbprint }
if ($null -eq $StoreCert) { Fail 'Issued certificate was not found in LocalMachine\My after certreq -accept.' }

$PfxPassword = Read-Host 'Set a temporary PFX password' -AsSecureString
if ($PfxPassword.Length -eq 0) { Fail 'PFX password cannot be blank.' }

Export-PfxCertificate -Cert "Cert:\LocalMachine\My\$($IssuedCert.Thumbprint)" -FilePath $PfxPath -Password $PfxPassword -ChainOption BuildChain | Out-Null

Write-Host ''
Write-Host 'SUCCESS' -ForegroundColor Green
Write-Host "PFX: $PfxPath"
Write-Host "Certificate: $CerPath"
Write-Host ''
Write-Host 'Brother: Network > Security > Certificate > Import Certificate and Private Key.' -ForegroundColor Cyan
Write-Host 'Upload the PFX, enter the password, bind it under HTTP Server Settings, and power-cycle the printer.' -ForegroundColor Cyan
