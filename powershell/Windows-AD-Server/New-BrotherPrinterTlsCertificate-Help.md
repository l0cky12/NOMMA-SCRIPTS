# New-BrotherPrinterTlsCertificate.ps1 Help

Creates a SAN-correct HTTPS certificate for a Brother printer from the local Microsoft AD CS Issuing CA and exports it as a password-protected PFX.

## What it does

1. Prompts for the printer DNS name when `-PrinterHost` is omitted.
2. Confirms the script is running elevated on a server with the local AD CS `CertSvc` service running.
3. Detects the active local CA automatically when `-CAConfig` is omitted.
4. Generates a Windows machine CSR containing the requested DNS Subject Alternative Name (SAN).
5. Submits it using the published `PrinterHTTPS` template.
6. Validates that the issued certificate has both the DNS SAN and Server Authentication EKU.
7. Accepts the certificate into the local machine certificate store.
8. Prompts for a temporary PFX password and exports a PFX including the certificate chain.

It does **not** modify CA settings, certificate templates, DNS, printer configuration, or the CA service.

## Prerequisites

- Run on the active Issuing CA in an **elevated Windows PowerShell 5.1** session.
- AD CS Certificate Services (`CertSvc`) must be running.
- The `PrinterHTTPS` certificate template must already be published on the local CA.
- The account running the script needs **Read** and **Enroll** on `PrinterHTTPS`.
- The Issuing CA computer account needs **Read** on `PrinterHTTPS`.
- The template must use **Supply in the request** for Subject Name and include **Server Authentication**.

## Quick start

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
.\New-BrotherPrinterTlsCertificate.ps1
```

When prompted, enter the printer's FQDN:

```text
b-4024.nomma.tech
```

The script creates a timestamped output folder when one is supplied:

```powershell
$OutputDirectory = 'C:\Temp\BrotherTLS-{0}' -f (Get-Date -Format 'yyyyMMdd-HHmmss')
.\New-BrotherPrinterTlsCertificate.ps1 -OutputDirectory $OutputDirectory
```

## Optional parameters

Use a different published template:

```powershell
.\New-BrotherPrinterTlsCertificate.ps1 -Template 'AnotherPrinterHttpsTemplate'
```

Use a specific CA instead of local CA auto-detection:

```powershell
.\New-BrotherPrinterTlsCertificate.ps1 `
    -CAConfig 'ISSUING-CA01\NOMMA Issuing CA 01'
```

## If the request is pending

The script prints the request ID and retrieval command. In the Certification Authority console:

```text
certsrv.msc
→ Pending Requests
→ right-click the matching request
→ All Tasks
→ Issue
```

Then run the retrieval command printed by the script.

## Import the PFX on the Brother

Use the Brother page that accepts both a certificate and private key:

```text
Network
→ Security
→ Certificate
→ Import Certificate and Private Key
```

Upload the generated `.pfx` file and enter the temporary PFX password. Do not use the normal **Import Certificate** page: that page expects a PEM certificate and rejects PFX files.

Then bind the new certificate:

```text
Network
→ Protocol
→ HTTP Server Settings
→ Certificate dropdown
→ select the new certificate
→ Submit
→ power-cycle the printer
```

## Cleanup

A PFX contains the private key. After the Brother accepts and serves the certificate successfully, delete the exported PFX from the Issuing CA:

```powershell
Remove-Item 'C:\Temp\BrotherTLS\b-4024.nomma.tech.pfx'
```

## Built-in PowerShell help

```powershell
Get-Help .\New-BrotherPrinterTlsCertificate.ps1 -Full
```
