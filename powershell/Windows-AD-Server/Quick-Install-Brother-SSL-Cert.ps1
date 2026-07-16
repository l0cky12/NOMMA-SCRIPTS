Set-ExecutionPolicy Bypass -Scope Process -Force

$ScriptPath = 'C:\Temp\New-BrotherPrinterTlsCertificate.ps1'
$OutputDirectory = 'C:\Temp\BrotherTLS-{0}' -f (
    Get-Date -Format 'yyyyMMdd-HHmmss'
)

Invoke-WebRequest `
    -Uri 'https://raw.githubusercontent.com/l0cky12/NOMMA-SCRIPTS/main/powershell/Windows-AD-Server/New-BrotherPrinterTlsCertificate.ps1' `
    -OutFile $ScriptPath

Unblock-File $ScriptPath

& $ScriptPath -OutputDirectory $OutputDirectory
