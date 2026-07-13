#Requires -Version 5.1
<#
.SYNOPSIS
    Safely validates native AD CS Issuing CA connectivity from a Windows endpoint.

.DESCRIPTION
    Tests DNS, RPC Endpoint Mapper reachability, device join state, and a read-only
    certutil CA ping against a specified AD CS Issuing CA. The selected AD CS
    interface is the supported native enrollment RPC/DCOM interface used by
    certutil.exe; certutil -config <CAConfig> -ping does not submit, approve,
    revoke, or delete certificates.

    An Entra-only joined device does not automatically have an on-premises AD
    Kerberos logon session. Native AD CS RPC/DCOM uses the Windows logon token;
    supplying a PSCredential cannot safely or reliably change the identity used
    by certutil or COM in this process. When alternate credentials are provided,
    this script validates them with an authenticated LDAP bind only. To test CA
    RPC with alternate AD credentials, use a separate interactive Windows
    logon context (for example, runas.exe /netonly) or deploy supported
    Certificate Enrollment Web Services (CEP/CES) with its HTTPS endpoint.

    This script intentionally performs no certificate enrollment or other AD CS
    state-changing operation.

.PARAMETER CAServer
    DNS name or host name of the Windows server hosting the Issuing CA.

.PARAMETER CAConfig
    Optional AD CS configuration string in the form CA-SERVER\Issuing-CA-Name.
    If omitted, the script attempts read-only enterprise CA discovery with
    certutil -ADCA. Specify CAConfig explicitly for reliable validation.

.PARAMETER Credential
    Optional AD domain credential used only for an LDAP authentication test.
    It does not impersonate certutil or change native AD CS RPC/DCOM identity.

.PARAMETER PromptForCredential
    Securely prompts with Get-Credential for an optional AD credential, then
    tests it with LDAP. Requires ADDomain unless the username is a UPN.

.PARAMETER ADDomain
    AD DNS domain used for the optional alternate-credential LDAP bind, such as
    ad.example.com. When omitted, the UPN suffix is used if Credential.UserName
    is in user@ad.example.com format.

.PARAMETER LogPath
    Optional path for a pipe-delimited operational log. Passwords, SecureString
    contents, authentication tokens, and private keys are never logged.

.PARAMETER DetailedTest
    Adds non-authoritative diagnostic tests such as TCP 445. TCP 135 plus a
    successful certutil CA ping is more meaningful than ICMP for native AD CS.

.EXAMPLE
    .\Test-ADCSIssuingCAConnection.ps1 -CAServer 'CA01.contoso.com' `
        -CAConfig 'CA01\Contoso Issuing CA'

    Uses the current Windows logon identity for a read-only native AD CS CA ping.

.EXAMPLE
    .\Test-ADCSIssuingCAConnection.ps1 -CAServer 'CA01.contoso.com' `
        -CAConfig 'CA01\Contoso Issuing CA' -PromptForCredential `
        -ADDomain 'contoso.com'

    Securely prompts for an AD credential and validates that credential with LDAP.
    The CA ping still uses the current Windows logon token; see NOTES.

.EXAMPLE
    .\Test-ADCSIssuingCAConnection.ps1 -CAServer 'CA01.contoso.com' `
        -CAConfig 'CA01\Contoso Issuing CA' -DetailedTest

    Includes additional TCP diagnostics. It does not treat a ping or TCP test as
    proof of CA authentication.

.EXAMPLE
    .\Test-ADCSIssuingCAConnection.ps1 -CAServer 'CA01.contoso.com' `
        -CAConfig 'CA01\Contoso Issuing CA' `
        -LogPath 'C:\ProgramData\ADCS-Diagnostics\CA-Connection.log'

    Writes operational results to the specified log file without logging secrets.

.NOTES
    Exit codes:
      0 = Successful authenticated CA validation
      1 = General failure
      2 = DNS or network failure
      3 = Authentication or authorization failure
      4 = CA configuration invalid or could not be discovered
      5 = Unsupported AD CS access architecture or non-Windows host

    Native AD CS RPC/DCOM requires line-of-sight to the CA, TCP 135, negotiated
    dynamic RPC ports, and an AD-authenticated Windows logon context authorized
    to query the CA. A firewall rule that permits only TCP 135 is insufficient:
    dynamic RPC must be allowed according to the organization's documented CA
    firewall policy. SMB/TCP 445 is not a prerequisite for a native CA ping and
    is shown only as an optional diagnostic.

    Downloaded scripts may be marked as Internet-origin. If policy blocks the
    first run, review the script and use Unblock-File on the reviewed copy.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9.-]*$')]
    [string]$CAServer,

    [Parameter()]
    [ValidatePattern('^[^\\/:*?"<>|]+\\[^\\/:*?"<>|]+$')]
    [string]$CAConfig,

    [Parameter()]
    [System.Management.Automation.PSCredential]$Credential,

    [Parameter()]
    [switch]$PromptForCredential,

    [Parameter()]
    [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9.-]*$')]
    [string]$ADDomain,

    [Parameter()]
    [string]$LogPath,

    [Parameter()]
    [switch]$DetailedTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ExitCode = @{
    'Success'                 = 0
    'GeneralFailure'          = 1
    'NetworkFailure'          = 2
    'AuthenticationFailure'   = 3
    'InvalidCAConfiguration'  = 4
    'UnsupportedArchitecture' = 5
}

$script:Results = [System.Collections.Generic.List[object]]::new()
$script:LogPath = $LogPath

function Write-OperationalLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('INFO', 'SUCCESS', 'WARNING', 'ERROR')]
        [string]$Level,

        [Parameter(Mandatory)]
        [string]$Message
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ssK'
    Write-Information -MessageData ('[{0}] [{1}] {2}' -f $timestamp, $Level, $Message) -InformationAction Continue

    if (-not [string]::IsNullOrWhiteSpace($script:LogPath)) {
        try {
            $parentPath = Split-Path -Path $script:LogPath -Parent
            if (-not [string]::IsNullOrWhiteSpace($parentPath) -and -not (Test-Path -LiteralPath $parentPath)) {
                New-Item -Path $parentPath -ItemType Directory -Force -ErrorAction Stop | Out-Null
            }

            Add-Content -LiteralPath $script:LogPath -Value ('{0}|{1}|{2}' -f $timestamp, $Level, $Message) -Encoding UTF8 -ErrorAction Stop
        }
        catch {
            Write-Warning ('Unable to write to LogPath ''{0}'': {1}' -f $script:LogPath, $_.Exception.Message)
            $script:LogPath = $null
        }
    }
}

function Add-TestResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$Target,

        [Parameter(Mandatory)]
        [ValidateSet('PASS', 'FAIL', 'WARNING', 'SKIPPED')]
        [string]$Result,

        [Parameter(Mandatory)]
        [string]$Explanation
    )

    $script:Results.Add([pscustomobject]@{
        'TestName'    = $Name
        'Target'      = $Target
        'Result'      = $Result
        'Explanation' = $Explanation
    })

    $level = switch ($Result) {
        'PASS'    { 'SUCCESS' }
        'FAIL'    { 'ERROR' }
        'WARNING' { 'WARNING' }
        default   { 'INFO' }
    }

    Write-OperationalLog -Level $level -Message ('{0} | Target: {1} | Result: {2} | {3}' -f $Name, $Target, $Result, $Explanation)
}

function Test-LocalWindows {
    [CmdletBinding()]
    param()

    return ($env:OS -eq 'Windows_NT')
}

function Get-DeviceJoinState {
    [CmdletBinding()]
    param()

    $state = [ordered]@{
        'DisplayName'    = 'Unknown'
        'AzureAdJoined'  = $false
        'DomainJoined'   = $false
        'DiagnosticInfo' = $null
    }

    $dsregcmd = Get-Command -Name 'dsregcmd.exe' -ErrorAction SilentlyContinue
    if ($null -ne $dsregcmd) {
        try {
            $dsregOutput = & $dsregcmd.Source /status 2>&1 | Out-String
            $state.AzureAdJoined = ($dsregOutput -match '(?im)^\s*AzureAdJoined\s*:\s*YES\s*$')
            $state.DomainJoined = ($dsregOutput -match '(?im)^\s*DomainJoined\s*:\s*YES\s*$')
            $state.DiagnosticInfo = 'Determined with dsregcmd.exe /status.'
        }
        catch {
            $state.DiagnosticInfo = ('dsregcmd.exe could not be queried: {0}' -f $_.Exception.Message)
        }
    }

    if (-not $state.DomainJoined) {
        try {
            $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
            $state.DomainJoined = [bool]$computerSystem.PartOfDomain
            if ([string]::IsNullOrWhiteSpace($state.DiagnosticInfo)) {
                $state.DiagnosticInfo = 'Determined with Win32_ComputerSystem.'
            }
        }
        catch {
            if ([string]::IsNullOrWhiteSpace($state.DiagnosticInfo)) {
                $state.DiagnosticInfo = ('Join state query failed: {0}' -f $_.Exception.Message)
            }
        }
    }

    if ($state.AzureAdJoined -and $state.DomainJoined) {
        $state.DisplayName = 'Hybrid Entra Joined'
    }
    elseif ($state.AzureAdJoined) {
        $state.DisplayName = 'Entra Joined'
    }
    elseif ($state.DomainJoined) {
        $state.DisplayName = 'AD Domain Joined'
    }
    else {
        $state.DisplayName = 'Not Entra or AD Domain Joined'
    }

    return [pscustomobject]$state
}

function Resolve-CAHost {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ServerName
    )

    try {
        $records = Resolve-DnsName -Name $ServerName -DnsOnly -ErrorAction Stop |
            Where-Object { $_.Type -in @('A', 'AAAA') }
        $addresses = @($records | ForEach-Object { $_.IPAddress } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)

        if ($addresses.Count -eq 0) {
            throw 'DNS returned no A or AAAA records.'
        }

        return $addresses
    }
    catch {
        throw ('DNS resolution failed for {0}: {1}' -f $ServerName, $_.Exception.Message)
    }
}

function Test-TcpPort {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ComputerName,

        [Parameter(Mandatory)]
        [ValidateRange(1, 65535)]
        [int]$Port,

        [Parameter()]
        [ValidateRange(100, 30000)]
        [int]$TimeoutMilliseconds = 5000
    )

    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $asyncResult = $client.BeginConnect($ComputerName, $Port, $null, $null)
        if (-not $asyncResult.AsyncWaitHandle.WaitOne($TimeoutMilliseconds, $false)) {
            return $false
        }

        $client.EndConnect($asyncResult)
        return $client.Connected
    }
    catch {
        return $false
    }
    finally {
        $client.Dispose()
    }
}

function Invoke-Certutil {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$ArgumentList
    )

    $certutil = Get-Command -Name 'certutil.exe' -ErrorAction Stop
    $global:LASTEXITCODE = 0
    $output = & $certutil.Source @ArgumentList 2>&1 | Out-String
    $exitCode = $LASTEXITCODE

    return [pscustomobject]@{
        'ExitCode' = $exitCode
        'Output'   = $output.Trim()
    }
}

function Find-CAConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ServerName
    )

    $discovery = Invoke-Certutil -ArgumentList @('-ADCA')
    if ($discovery.ExitCode -ne 0) {
        return $null
    }

    $shortServerName = $ServerName.Split('.')[0]
    $configurationMatches = [System.Collections.Generic.List[string]]::new()
    foreach ($line in ($discovery.Output -split "`r?`n")) {
        if ($line -match '(?i)\b(?:config|configuration)\s*:\s*(.+\\.+)$') {
            $candidate = $Matches[1].Trim()
            $candidateServer = $candidate.Split('\')[0]
            if (($candidateServer -ieq $ServerName) -or ($candidateServer -ieq $shortServerName)) {
                $configurationMatches.Add($candidate)
            }
        }
    }

    $uniqueMatches = @($configurationMatches | Select-Object -Unique)
    if ($uniqueMatches.Count -eq 1) {
        return $uniqueMatches[0]
    }

    return $null
}

function Test-AlternateADCredential {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$TestCredential,

        [Parameter()]
        [string]$DomainName
    )

    $networkCredential = $null
    $connection = $null
    try {
        if ([string]::IsNullOrWhiteSpace($DomainName) -and $TestCredential.UserName -match '@') {
            $DomainName = $TestCredential.UserName.Split('@')[-1]
        }

        if ([string]::IsNullOrWhiteSpace($DomainName)) {
            throw 'ADDomain is required when the credential username is not a UPN.'
        }

        # LdapConnection requires NetworkCredential. GetNetworkCredential exposes a
        # transient managed password string internally; it is never logged, saved,
        # or placed on a command line, and references are cleared in finally.
        $networkCredential = $TestCredential.GetNetworkCredential()
        $connection = [System.DirectoryServices.Protocols.LdapConnection]::new($DomainName)
        $connection.AuthType = [System.DirectoryServices.Protocols.AuthType]::Negotiate
        $connection.SessionOptions.ProtocolVersion = 3
        $connection.Credential = $networkCredential
        $connection.Bind()
        return [pscustomobject]@{
            'Succeeded' = $true
            'Message'   = ('Authenticated LDAP bind succeeded for the supplied AD credential against {0}.' -f $DomainName)
        }
    }
    catch {
        return [pscustomobject]@{
            'Succeeded' = $false
            'Message'   = ('Authenticated LDAP bind failed: {0}' -f $_.Exception.Message)
        }
    }
    finally {
        if ($null -ne $connection) {
            $connection.Dispose()
        }
        $networkCredential = $null
    }
}

function Get-CAFailureCategory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Output
    )

    if ($Output -match '(?i)(access is denied|logon failure|unknown user name|0x80070005|0x8007052e|0x8009030c|0x80090322)') {
        return 'Authentication'
    }

    if ($Output -match '(?i)(rpc server is unavailable|0x800706ba|server is unavailable|network path was not found|0x80070035)') {
        return 'Network'
    }

    if ($Output -match '(?i)(invalid.*config|config.*not found|0x80070057|0x80004005)') {
        return 'Configuration'
    }

    return 'General'
}

function Show-Summary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$JoinState,

        [Parameter(Mandatory)]
        [string]$ServerName,

        [Parameter()]
        [string]$Configuration,

        [Parameter(Mandatory)]
        [int]$FinalExitCode
    )

    $dnsResult = ($script:Results | Where-Object { $_.TestName -eq 'DNS resolution' } | Select-Object -Last 1).Result
    $connectivityResult = ($script:Results | Where-Object { $_.TestName -eq 'RPC Endpoint Mapper (TCP 135)' } | Select-Object -Last 1).Result
    $authenticationResult = ($script:Results | Where-Object { $_.TestName -in @('Current Windows identity CA access', 'Alternate AD credential LDAP bind') } | Select-Object -Last 1).Result
    $caQueryResult = ($script:Results | Where-Object { $_.TestName -eq 'Native AD CS CA ping' } | Select-Object -Last 1).Result

    Write-Information -MessageData '' -InformationAction Continue
    Write-Information -MessageData ('=' * 78) -InformationAction Continue
    Write-Information -MessageData ('Device Join State : {0}' -f $JoinState.DisplayName) -InformationAction Continue
    Write-Information -MessageData ('CA Server         : {0}' -f $ServerName) -InformationAction Continue
    Write-Information -MessageData ('CA Configuration  : {0}' -f $(if ($Configuration) { $Configuration } else { 'Not resolved' })) -InformationAction Continue
    Write-Information -MessageData ('DNS Resolution    : {0}' -f $(if ($dnsResult) { $dnsResult } else { 'SKIPPED' })) -InformationAction Continue
    Write-Information -MessageData ('CA Connectivity   : {0}' -f $(if ($connectivityResult) { $connectivityResult } else { 'SKIPPED' })) -InformationAction Continue
    Write-Information -MessageData ('Authentication    : {0}' -f $(if ($authenticationResult) { $authenticationResult } else { 'NOT VALIDATED' })) -InformationAction Continue
    Write-Information -MessageData ('CA Query          : {0}' -f $(if ($caQueryResult) { $caQueryResult } else { 'SKIPPED' })) -InformationAction Continue
    Write-Information -MessageData ('=' * 78) -InformationAction Continue

    if ($FinalExitCode -eq $ExitCode.Success) {
        Write-Information -MessageData 'Final Result: SUCCESS' -InformationAction Continue
    }
    else {
        Write-Information -MessageData ('Final Result: FAILED (exit code {0})' -f $FinalExitCode) -InformationAction Continue
    }
}

$finalExitCode = $ExitCode.GeneralFailure
$joinState = $null

function Get-ADCSValidationExitException {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int]$Code
    )

    $exception = [System.OperationCanceledException]::new('AD CS validation completed with a non-zero exit code.')
    $exception.Data['ADCSValidationExitCode'] = $Code
    return $exception
}

try {
    if (-not (Test-LocalWindows)) {
        Write-OperationalLog -Level 'ERROR' -Message 'This script must run on Windows because certutil.exe and Windows join state are required.'
        $finalExitCode = $ExitCode.UnsupportedArchitecture
        throw (Get-ADCSValidationExitException -Code $finalExitCode)
    }

    if ($PromptForCredential -and $null -ne $Credential) {
        throw 'Specify either Credential or PromptForCredential, not both.'
    }

    if ($PromptForCredential) {
        $Credential = Get-Credential -Message 'Enter an AD credential for an LDAP authentication test. This does not change certutil identity.'
    }

    $joinState = Get-DeviceJoinState
    Add-TestResult -Name 'Device join state' -Target $env:COMPUTERNAME -Result 'PASS' -Explanation ('{0} {1}' -f $joinState.DisplayName, $joinState.DiagnosticInfo)

    if ($joinState.DisplayName -eq 'Entra Joined') {
        Write-OperationalLog -Level 'WARNING' -Message 'Entra-only join does not by itself provide an on-premises AD Kerberos logon context. Native AD CS RPC may fail until a supported AD authentication path is present.'
    }

    $resolvedAddresses = Resolve-CAHost -ServerName $CAServer
    Add-TestResult -Name 'DNS resolution' -Target $CAServer -Result 'PASS' -Explanation ('Resolved address(es): {0}.' -f ($resolvedAddresses -join ', '))

    if (Test-TcpPort -ComputerName $CAServer -Port 135) {
        Add-TestResult -Name 'RPC Endpoint Mapper (TCP 135)' -Target ('{0}:135' -f $CAServer) -Result 'PASS' -Explanation 'TCP 135 is reachable. Native AD CS RPC also needs negotiated dynamic RPC ports, verified by the CA ping.'
    }
    else {
        Add-TestResult -Name 'RPC Endpoint Mapper (TCP 135)' -Target ('{0}:135' -f $CAServer) -Result 'FAIL' -Explanation 'TCP 135 is not reachable. Check VPN/routing and the CA firewall policy for RPC Endpoint Mapper and approved dynamic RPC ports.'
        $finalExitCode = $ExitCode.NetworkFailure
        throw (Get-ADCSValidationExitException -Code $finalExitCode)
    }

    if ($DetailedTest) {
        if (Test-TcpPort -ComputerName $CAServer -Port 445) {
            Add-TestResult -Name 'Optional SMB diagnostic (TCP 445)' -Target ('{0}:445' -f $CAServer) -Result 'PASS' -Explanation 'SMB is reachable. This is diagnostic only and is not required for a native certutil CA ping.'
        }
        else {
            Add-TestResult -Name 'Optional SMB diagnostic (TCP 445)' -Target ('{0}:445' -f $CAServer) -Result 'WARNING' -Explanation 'SMB is not reachable. This alone does not prevent native AD CS RPC/DCOM access.'
        }
    }

    if ($null -ne $Credential) {
        $credentialTest = Test-AlternateADCredential -TestCredential $Credential -DomainName $ADDomain
        if ($credentialTest.Succeeded) {
            Add-TestResult -Name 'Alternate AD credential LDAP bind' -Target $(if ($ADDomain) { $ADDomain } else { 'UPN-derived domain' }) -Result 'PASS' -Explanation $credentialTest.Message
        }
        else {
            Add-TestResult -Name 'Alternate AD credential LDAP bind' -Target $(if ($ADDomain) { $ADDomain } else { 'UPN-derived domain' }) -Result 'FAIL' -Explanation $credentialTest.Message
            $finalExitCode = $ExitCode.AuthenticationFailure
            throw (Get-ADCSValidationExitException -Code $finalExitCode)
        }
    }

    if ([string]::IsNullOrWhiteSpace($CAConfig)) {
        Write-OperationalLog -Level 'INFO' -Message 'CAConfig was not supplied. Attempting read-only enterprise CA discovery with certutil -ADCA.'
        $CAConfig = Find-CAConfiguration -ServerName $CAServer
        if ([string]::IsNullOrWhiteSpace($CAConfig)) {
            Add-TestResult -Name 'CA configuration discovery' -Target $CAServer -Result 'FAIL' -Explanation 'Could not identify exactly one CA configuration for this server. Supply -CAConfig "CA-SERVER\Issuing-CA-Name".'
            $finalExitCode = $ExitCode.InvalidCAConfiguration
            throw (Get-ADCSValidationExitException -Code $finalExitCode)
        }

        Add-TestResult -Name 'CA configuration discovery' -Target $CAServer -Result 'PASS' -Explanation ('Discovered CA configuration: {0}.' -f $CAConfig)
    }

    $configuredServer = $CAConfig.Split('\')[0]
    $shortConfiguredServer = $configuredServer.Split('.')[0]
    $shortCAServer = $CAServer.Split('.')[0]
    if (($configuredServer -ine $CAServer) -and ($shortConfiguredServer -ine $shortCAServer)) {
        Add-TestResult -Name 'CA configuration validation' -Target $CAConfig -Result 'FAIL' -Explanation ('CAConfig server component does not match CAServer ({0}).' -f $CAServer)
        $finalExitCode = $ExitCode.InvalidCAConfiguration
        throw (Get-ADCSValidationExitException -Code $finalExitCode)
    }

    Add-TestResult -Name 'CA configuration validation' -Target $CAConfig -Result 'PASS' -Explanation 'Configuration string syntax and server component are valid.'

    # certutil -ping is a read-only native CA RPC/DCOM probe. It neither submits
    # a request nor changes CA state, and it runs under the current Windows token.
    $caPing = Invoke-Certutil -ArgumentList @('-config', $CAConfig, '-ping')
    if ($caPing.ExitCode -eq 0) {
        Add-TestResult -Name 'Current Windows identity CA access' -Target $CAConfig -Result 'PASS' -Explanation 'The current Windows logon token authenticated sufficiently for the native CA query.'
        Add-TestResult -Name 'Native AD CS CA ping' -Target $CAConfig -Result 'PASS' -Explanation 'The Issuing CA responded to the read-only certutil RPC/DCOM ping.'
        $finalExitCode = $ExitCode.Success
    }
    else {
        $failureCategory = Get-CAFailureCategory -Output $caPing.Output
        $safeFailureText = ($caPing.Output -replace '\s+', ' ').Trim()
        if ($safeFailureText.Length -gt 500) {
            $safeFailureText = $safeFailureText.Substring(0, 500)
        }

        switch ($failureCategory) {
            'Authentication' {
                Add-TestResult -Name 'Current Windows identity CA access' -Target $CAConfig -Result 'FAIL' -Explanation ('Native CA authentication or authorization failed: {0}' -f $safeFailureText)
                Add-TestResult -Name 'Native AD CS CA ping' -Target $CAConfig -Result 'FAIL' -Explanation 'The CA did not accept the current Windows identity for the read-only query.'
                Write-OperationalLog -Level 'WARNING' -Message 'Next step: use an AD or hybrid-joined sign-in context with Kerberos line-of-sight, or deploy supported CES/CEP. A PSCredential does not impersonate certutil RPC/DCOM.'
                $finalExitCode = $ExitCode.AuthenticationFailure
            }
            'Network' {
                Add-TestResult -Name 'Native AD CS CA ping' -Target $CAConfig -Result 'FAIL' -Explanation ('Native CA RPC/DCOM could not reach the CA: {0}' -f $safeFailureText)
                Write-OperationalLog -Level 'WARNING' -Message 'Next step: verify CA firewall rules for TCP 135 and the organization-approved dynamic RPC range, plus VPN/routing to the CA.'
                $finalExitCode = $ExitCode.NetworkFailure
            }
            'Configuration' {
                Add-TestResult -Name 'Native AD CS CA ping' -Target $CAConfig -Result 'FAIL' -Explanation ('CA configuration appears invalid or unavailable: {0}' -f $safeFailureText)
                Write-OperationalLog -Level 'WARNING' -Message 'Next step: confirm the exact CA configuration with certutil -ADCA from an AD-authenticated administrative workstation.'
                $finalExitCode = $ExitCode.InvalidCAConfiguration
            }
            default {
                Add-TestResult -Name 'Native AD CS CA ping' -Target $CAConfig -Result 'FAIL' -Explanation ('certutil returned exit code {0}: {1}' -f $caPing.ExitCode, $safeFailureText)
                Write-OperationalLog -Level 'WARNING' -Message 'Next step: review the certutil output, CA service health, CA permissions, and AD CS event logs on the Issuing CA.'
                $finalExitCode = $ExitCode.GeneralFailure
            }
        }
    }
}
catch {
    if ($_.Exception.Data.Contains('ADCSValidationExitCode')) {
        $finalExitCode = [int]$_.Exception.Data['ADCSValidationExitCode']
    }
    else {
        Write-OperationalLog -Level 'ERROR' -Message $_.Exception.Message
        if ($_.Exception.Message -match '(?i)(DNS resolution failed|Resolve-DnsName)') {
            $finalExitCode = $ExitCode.NetworkFailure
        }
        elseif ($_.Exception.Message -match '(?i)(Credential|logon|access is denied|authentication)') {
            $finalExitCode = $ExitCode.AuthenticationFailure
        }
        else {
            $finalExitCode = $ExitCode.GeneralFailure
        }
    }
}
finally {
    if ($null -ne $joinState) {
        Show-Summary -JoinState $joinState -ServerName $CAServer -Configuration $CAConfig -FinalExitCode $finalExitCode
    }

    # Do not retain a supplied credential reference longer than this invocation.
    $Credential = $null
}

exit $finalExitCode
