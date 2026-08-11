<#
.SYNOPSIS
    Safely removes Education Plus licenses from users in an OU or CSV list.

.DESCRIPTION
    Resolves users from a Google Workspace organizational unit or a CSV file,
    checks each user's assigned SKUs, and targets only the configured Education
    Plus SKU. The default mode is a non-mutating dry run. Actual removal requires
    both -Apply and one batch-wide confirmation by typing YES.
    Loading Google API assemblies for a real run requires the .NET SDK (dotnet) or pre-restored assemblies.

.PARAMETER CsvPath
    Path to a CSV containing a recognized email column. Used when -OuTarget is
    not supplied.

.PARAMETER OuTarget
    Gets target users from the Google Directory API instead of a CSV file.

.PARAMETER OuPath
    Google Workspace organizational-unit path used with -OuTarget.

.PARAMETER Apply
    Enables license removal after one interactive confirmation. Without this
    switch, the script is a dry run and makes zero removal calls.

.PARAMETER ReportPath
    Directory in which the timestamped CSV report is written.

.PARAMETER CredentialsPath
    Required path to an OAuth2 client-secrets JSON file. Its contents and tokens
    are never printed or written to reports.

.PARAMETER EducationPlusSkuId
    Education Plus SKU to remove. Override this only after tenant verification.

.EXAMPLE
    ./Remove-EducationPlusLicense-InactiveOU.ps1 -CsvPath ./users.csv `
        -CredentialsPath ./client-secrets.json -ReportPath ./reports

    Performs a dry run against users.csv.

.EXAMPLE
    ./Remove-EducationPlusLicense-InactiveOU.ps1 -OuTarget `
        -CredentialsPath ./client-secrets.json -Apply

    Checks the default inactive OU and, after one YES confirmation, removes only
    the Education Plus SKU.
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$CsvPath,

    [switch]$OuTarget,

    [string]$OuPath = 'NOMMA.net/zMisc/Inactive',

    [switch]$Apply,

    [string]$ReportPath = (Join-Path $PSScriptRoot 'reports'),

    [string]$CredentialsPath,

    [string]$EducationPlusSkuId = 'Google-Apps-For-Education-Plus'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertFrom-EduPlusCsv {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [string]$CsvPath
    )

    if ([string]::IsNullOrWhiteSpace($CsvPath)) {
        throw 'CsvPath must not be empty.'
    }
    if (-not (Test-Path -LiteralPath $CsvPath -PathType Leaf)) {
        throw "CSV file was not found: $CsvPath"
    }

    $rawLines = @(Get-Content -LiteralPath $CsvPath -ErrorAction Stop)
    $firstContentLine = $rawLines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1
    if ($null -eq $firstContentLine) {
        Write-Warning 'The CSV is empty; zero targets were found.'
        return @()
    }

    try {
        # Add a synthetic row so that a header-only CSV still exposes its column names.
        $headerProbe = @($firstContentLine, '__header_probe__') | ConvertFrom-Csv -ErrorAction Stop | Select-Object -First 1
        $headers = @($headerProbe.PSObject.Properties.Name)
    }
    catch {
        throw "The CSV header could not be parsed: $($_.Exception.Message)"
    }

    $recognizedHeaders = @('Email', 'EmailAddress', 'PrimaryEmail', 'UserEmail')
    $emailHeader = $headers | Where-Object { $_ -iin $recognizedHeaders } | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($emailHeader)) {
        throw "The CSV must contain a recognized email column: $($recognizedHeaders -join ', ')."
    }

    try {
        $rows = @(Import-Csv -LiteralPath $CsvPath -ErrorAction Stop)
    }
    catch {
        throw "The CSV could not be parsed: $($_.Exception.Message)"
    }

    if ($rows.Count -eq 0) {
        Write-Warning 'The CSV contains a header but no data rows; zero targets were found.'
        return @()
    }

    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $emails = [System.Collections.Generic.List[string]]::new()
    for ($index = 0; $index -lt $rows.Count; $index++) {
        $lineNumber = $index + 2
        $rawEmail = $rows[$index].PSObject.Properties[$emailHeader].Value
        $email = if ($null -eq $rawEmail) { '' } else { ([string]$rawEmail).Trim() }

        if ([string]::IsNullOrWhiteSpace($email)) {
            Write-Warning "Skipping CSV row $lineNumber because its email value is missing."
            continue
        }

        $parsedAddress = $null
        $isValid = [System.Net.Mail.MailAddress]::TryCreate($email, [ref]$parsedAddress) -and
            $parsedAddress.Address -ceq $email -and
            $email -match '^[^@\s]+@[^@\s]+$'
        if (-not $isValid) {
            Write-Warning "Skipping CSV row $lineNumber because '$email' is not a valid email address."
            continue
        }

        if ($seen.Add($email)) {
            $emails.Add($email)
        }
    }

    return $emails.ToArray()
}

function Test-EducationPlusAssigned {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$AssignedSkus,

        [Parameter(Mandatory)]
        [string]$TargetSkuId
    )

    if ([string]::IsNullOrWhiteSpace($TargetSkuId)) {
        throw 'TargetSkuId must not be empty.'
    }

    return @($AssignedSkus) -contains $TargetSkuId
}

function New-EduPlusResult {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$Email,

        [Parameter(Mandatory)]
        [string]$Status,

        [Parameter(Mandatory)]
        [bool]$EduPlusBefore,

        [Parameter(Mandatory)]
        [bool]$EduPlusAfter,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$Error
    )

    return [pscustomobject][ordered]@{
        Email         = $Email
        Status        = $Status
        EduPlusBefore = $EduPlusBefore
        EduPlusAfter  = $EduPlusAfter
        Error         = if ($null -eq $Error) { '' } else { $Error }
    }
}

function Format-EduPlusReportRows {
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Results,

        [Parameter(Mandatory)]
        [ValidateSet('dry-run', 'apply')]
        [string]$Mode,

        [Parameter(Mandatory)]
        $Timestamp
    )

    $timestampText = if ($Timestamp -is [datetime]) {
        $Timestamp.ToUniversalTime().ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
    }
    else {
        [string]$Timestamp
    }

    foreach ($result in @($Results)) {
        [pscustomobject][ordered]@{
            Email         = [string]$result.Email
            Status        = [string]$result.Status
            EduPlusBefore = [bool]$result.EduPlusBefore
            EduPlusAfter  = [bool]$result.EduPlusAfter
            Error         = if ($null -eq $result.Error) { '' } else { [string]$result.Error }
            Mode          = $Mode
            Timestamp     = $timestampText
        }
    }
}

$script:GoogleAssembliesLoaded = $false
$script:CredentialCache = @{}
$script:GoogleWorkspaceProductId = 'Google-Apps'
$script:GoogleCustomerId = 'my_customer'

function Initialize-GoogleApiAssemblies {
    if ($script:GoogleAssembliesLoaded) {
        return
    }

    $requiredTypes = @(
        'Google.Apis.Auth.OAuth2.GoogleWebAuthorizationBroker, Google.Apis.Auth',
        'Google.Apis.Admin.Directory.directory_v1.DirectoryService, Google.Apis.Admin.Directory.directory_v1',
        'Google.Apis.Licensing.v1.LicensingService, Google.Apis.Licensing.v1'
    )
    $allTypesAvailable = $true
    foreach ($typeName in $requiredTypes) {
        if ($null -eq [type]::GetType($typeName, $false)) {
            $allTypesAvailable = $false
            break
        }
    }
    if ($allTypesAvailable) {
        $script:GoogleAssembliesLoaded = $true
        return
    }

    $dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
    if ($null -eq $dotnet) {
        throw 'Google API assemblies are not loaded and dotnet is unavailable to restore them from NuGet.'
    }

    $localData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    if ([string]::IsNullOrWhiteSpace($localData)) {
        $localData = [System.IO.Path]::GetTempPath()
    }
    $restoreRoot = Join-Path $localData 'NOMMA-SCRIPTS/GoogleAdminApiAssemblies'
    $projectPath = Join-Path $restoreRoot 'GoogleApiDependencies.csproj'
    $licensingAssembly = Get-ChildItem -LiteralPath (Join-Path $restoreRoot 'bin') -Recurse -File `
        -Filter 'Google.Apis.Licensing.v1.dll' -ErrorAction SilentlyContinue | Select-Object -First 1

    if ($null -eq $licensingAssembly) {
        [System.IO.Directory]::CreateDirectory($restoreRoot) | Out-Null
        $project = @'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net8.0</TargetFramework>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="Google.Apis.Auth" Version="*" />
    <PackageReference Include="Google.Apis.Admin.Directory.directory_v1" Version="*" />
    <PackageReference Include="Google.Apis.Licensing.v1" Version="*" />
  </ItemGroup>
</Project>
'@
        [System.IO.File]::WriteAllText($projectPath, $project, [System.Text.UTF8Encoding]::new($false))

        $buildOutput = & $dotnet.Source build $projectPath --configuration Release --nologo --verbosity quiet 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "NuGet restore/build for the Google API assemblies failed: $($buildOutput -join [Environment]::NewLine)"
        }

        $licensingAssembly = Get-ChildItem -LiteralPath (Join-Path $restoreRoot 'bin') -Recurse -File -Filter 'Google.Apis.Licensing.v1.dll' |
            Select-Object -First 1
    }

    if ($null -eq $licensingAssembly) {
        throw 'NuGet restore completed, but the Google Licensing API assembly was not found.'
    }

    $assemblyDirectory = $licensingAssembly.Directory.FullName
    $loadOrder = @(
        'Newtonsoft.Json.dll',
        'Google.Apis.Core.dll',
        'Google.Apis.dll',
        'Google.Apis.Auth.PlatformServices.dll',
        'Google.Apis.Auth.dll',
        'Google.Apis.Admin.Directory.directory_v1.dll',
        'Google.Apis.Licensing.v1.dll'
    )
    foreach ($assemblyName in $loadOrder) {
        $assemblyPath = Join-Path $assemblyDirectory $assemblyName
        if (Test-Path -LiteralPath $assemblyPath -PathType Leaf) {
            Add-Type -Path $assemblyPath -ErrorAction Stop
        }
    }

    foreach ($typeName in $requiredTypes) {
        if ($null -eq [type]::GetType($typeName, $false)) {
            throw "Required Google API type failed to load: $($typeName.Split(',')[0])"
        }
    }
    $script:GoogleAssembliesLoaded = $true
}

function Resolve-GApiCredential {
    param(
        [Parameter(Mandatory)]
        [object]$Credential
    )

    $pathProperty = $Credential.PSObject.Properties['CredentialsPath']
    $scopesProperty = $Credential.PSObject.Properties['Scopes']
    if ($null -eq $pathProperty -or $null -eq $scopesProperty) {
        return $Credential
    }

    $credentialsPath = [string]$pathProperty.Value
    $scopes = @($scopesProperty.Value)
    $cacheKey = "{0}|{1}" -f $credentialsPath, ($scopes -join '|')
    if ($script:CredentialCache.ContainsKey($cacheKey)) {
        return $script:CredentialCache[$cacheKey]
    }

    try {
        $clientSecretsType = [type]::GetType('Google.Apis.Auth.OAuth2.GoogleClientSecrets, Google.Apis.Auth', $true)
        $brokerType = [type]::GetType('Google.Apis.Auth.OAuth2.GoogleWebAuthorizationBroker, Google.Apis.Auth', $true)
        $dataStoreType = [type]::GetType('Google.Apis.Util.Store.FileDataStore, Google.Apis.Core', $true)

        $clientSecrets = $clientSecretsType::FromFile($credentialsPath).Secrets
        $localData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
        if ([string]::IsNullOrWhiteSpace($localData)) {
            $localData = [System.IO.Path]::GetTempPath()
        }
        $pathHash = [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($credentialsPath))
        ).Substring(0, 16)
        $tokenStorePath = Join-Path $localData (Join-Path 'NOMMA-SCRIPTS/GoogleAdminAuth' $pathHash)
        $dataStore = [Activator]::CreateInstance($dataStoreType, @($tokenStorePath, $true))

        $authorizationTask = $brokerType::AuthorizeAsync(
            $clientSecrets,
            [string[]]$scopes,
            'education-plus-license-removal',
            [Threading.CancellationToken]::None,
            $dataStore
        )
        $resolvedCredential = $authorizationTask.GetAwaiter().GetResult()
        $script:CredentialCache[$cacheKey] = $resolvedCredential
        return $resolvedCredential
    }
    catch {
        throw 'OAuth credential initialization failed. Verify the client-secrets file and complete the authorization flow.'
    }
}

function New-GApiServiceInitializer {
    param(
        [Parameter(Mandatory)]
        [object]$Credential
    )

    $initializerType = [type]::GetType('Google.Apis.Services.BaseClientService+Initializer, Google.Apis', $true)
    $initializer = [Activator]::CreateInstance($initializerType)
    $initializer.HttpClientInitializer = $Credential
    $initializer.ApplicationName = 'NOMMA Education Plus License Removal'
    return $initializer
}

function New-GApiDirectoryService {
    param([Parameter(Mandatory)][object]$Credential)

    $serviceType = [type]::GetType(
        'Google.Apis.Admin.Directory.directory_v1.DirectoryService, Google.Apis.Admin.Directory.directory_v1',
        $true
    )
    $initializer = New-GApiServiceInitializer -Credential $Credential
    return [Activator]::CreateInstance($serviceType, @($initializer))
}

function New-GApiLicensingService {
    param([Parameter(Mandatory)][object]$Credential)

    $serviceType = [type]::GetType('Google.Apis.Licensing.v1.LicensingService, Google.Apis.Licensing.v1', $true)
    $initializer = New-GApiServiceInitializer -Credential $Credential
    return [Activator]::CreateInstance($serviceType, @($initializer))
}

function Get-GApiDirectoryUsersByOU {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$OuPath,

        [Parameter(Mandatory)]
        [object]$Credential
    )

    Initialize-GoogleApiAssemblies
    $resolvedCredential = Resolve-GApiCredential -Credential $Credential
    $service = New-GApiDirectoryService -Credential $resolvedCredential
    $users = [System.Collections.Generic.List[object]]::new()
    $pageToken = $null

    do {
        $request = $service.Users.List()
        $request.Customer = $script:GoogleCustomerId
        $escapedOuPath = $OuPath.Replace("'", "\'")
        $request.Query = "orgUnitPath='$escapedOuPath'"
        $request.Projection = 'full'
        $request.MaxResults = 500
        $request.PageToken = $pageToken
        $response = $request.Execute()

        foreach ($user in @($response.UsersValue)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$user.PrimaryEmail)) {
                $users.Add([pscustomobject]@{ Email = [string]$user.PrimaryEmail })
            }
        }
        $pageToken = $response.NextPageToken
    } while (-not [string]::IsNullOrWhiteSpace([string]$pageToken))

    return $users.ToArray()
}

function Get-GApiUserLicenseSkus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Email,

        [Parameter(Mandatory)]
        [object]$Credential
    )

    Initialize-GoogleApiAssemblies
    $resolvedCredential = Resolve-GApiCredential -Credential $Credential
    $service = New-GApiLicensingService -Credential $resolvedCredential
    $skuIds = [System.Collections.Generic.List[string]]::new()
    $pageToken = $null

    do {
        $request = $service.LicenseAssignments.ListForProduct(
            $script:GoogleWorkspaceProductId,
            $script:GoogleCustomerId
        )
        $request.MaxResults = 1000
        $request.PageToken = $pageToken
        $response = $request.Execute()

        foreach ($assignment in @($response.Items)) {
            if ([string]$assignment.UserId -ieq $Email -and
                -not [string]::IsNullOrWhiteSpace([string]$assignment.SkuId)) {
                $skuIds.Add([string]$assignment.SkuId)
            }
        }
        $pageToken = $response.NextPageToken
    } while (-not [string]::IsNullOrWhiteSpace([string]$pageToken))

    return $skuIds.ToArray()
}

function Remove-GApiLicenseAssignment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Email,

        [Parameter(Mandatory)]
        [string]$SkuId,

        [Parameter(Mandatory)]
        [object]$Credential
    )

    Initialize-GoogleApiAssemblies
    $resolvedCredential = Resolve-GApiCredential -Credential $Credential
    $service = New-GApiLicensingService -Credential $resolvedCredential
    $service.LicenseAssignments.Delete(
        $script:GoogleWorkspaceProductId,
        $SkuId,
        $Email
    ).Execute() | Out-Null
}

function Get-SafeEduPlusErrorMessage {
    param([Parameter(Mandatory)][string]$Message)

    $safeMessage = $Message
    $safeMessage = $safeMessage -replace '(?i)Bearer\s+[^\s,;]+', 'Bearer [REDACTED]'
    $safeMessage = $safeMessage -replace '(?i)(access_token|refresh_token|client_secret|id_token)(["''\s:=]+)[^\s,;}]+', '$1$2[REDACTED]'
    return $safeMessage
}

function Resolve-EduPlusTargets {
    param(
        [string]$CsvPath,
        [switch]$OuTarget,
        [string]$OuPath,
        [Parameter(Mandatory)][object]$Credential
    )

    if ($OuTarget) {
        if ([string]::IsNullOrWhiteSpace($OuPath)) {
            throw 'OuPath must not be empty when -OuTarget is used.'
        }

        $directoryUsers = @(Get-GApiDirectoryUsersByOU -OuPath $OuPath -Credential $Credential)
        $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $emails = [System.Collections.Generic.List[string]]::new()
        foreach ($user in $directoryUsers) {
            $email = if ($null -eq $user) { '' } else { ([string]$user.Email).Trim() }
            if ([string]::IsNullOrWhiteSpace($email)) {
                Write-Warning 'Skipping a Directory API user record with no email address.'
                continue
            }
            if ($seen.Add($email)) {
                $emails.Add($email)
            }
        }
        return $emails.ToArray()
    }

    if (-not [string]::IsNullOrWhiteSpace($CsvPath)) {
        return @(ConvertFrom-EduPlusCsv -CsvPath $CsvPath)
    }

    throw 'Specify an input source: use -OuTarget [-OuPath <path>] or -CsvPath <file>.'
}

function Export-EduPlusReport {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Results,
        [Parameter(Mandatory)][ValidateSet('dry-run', 'apply')][string]$Mode,
        [Parameter(Mandatory)][datetime]$Timestamp,
        [Parameter(Mandatory)][string]$ReportPath
    )

    if ([string]::IsNullOrWhiteSpace($ReportPath)) {
        throw 'ReportPath must not be empty.'
    }

    New-Item -ItemType Directory -Path $ReportPath -Force -ErrorAction Stop | Out-Null
    $fileTimestamp = $Timestamp.ToUniversalTime().ToString('yyyyMMdd-HHmmss')
    $reportFile = Join-Path $ReportPath "EducationPlusLicense-$fileTimestamp-$Mode.csv"
    $rows = @(Format-EduPlusReportRows -Results $Results -Mode $Mode -Timestamp $Timestamp)
    if ($rows.Count -gt 0) {
        $rows | Export-Csv -LiteralPath $reportFile -NoTypeInformation -Encoding utf8NoBOM -ErrorAction Stop
    }
    else {
        '"Email","Status","EduPlusBefore","EduPlusAfter","Error","Mode","Timestamp"' |
            Set-Content -LiteralPath $reportFile -Encoding utf8NoBOM -ErrorAction Stop
    }
    return $reportFile
}

function Invoke-EducationPlusLicenseRemoval {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [string]$CsvPath,
        [switch]$OuTarget,
        [string]$OuPath = 'NOMMA.net/zMisc/Inactive',
        [switch]$Apply,
        [string]$ReportPath = (Join-Path $PSScriptRoot 'reports'),
        [string]$CredentialsPath,
        [string]$EducationPlusSkuId = 'Google-Apps-For-Education-Plus'
    )

    if ([string]::IsNullOrWhiteSpace($CredentialsPath)) {
        throw 'CredentialsPath is required. Pass the path to an OAuth2 client-secrets JSON file.'
    }
    if (-not (Test-Path -LiteralPath $CredentialsPath -PathType Leaf)) {
        throw 'The OAuth2 client-secrets file specified by CredentialsPath does not exist.'
    }
    if ([string]::IsNullOrWhiteSpace($EducationPlusSkuId)) {
        throw 'EducationPlusSkuId must not be empty.'
    }

    $credentialContext = [pscustomobject]@{
        CredentialsPath = (Resolve-Path -LiteralPath $CredentialsPath -ErrorAction Stop).Path
        Scopes = @(
            'https://www.googleapis.com/auth/admin.directory.user.readonly'
            'https://www.googleapis.com/auth/apps.licensing'
        )
    }

    $targets = @(Resolve-EduPlusTargets -CsvPath $CsvPath -OuTarget:$OuTarget -OuPath $OuPath -Credential $credentialContext)
    $mode = if ($Apply) { 'apply' } else { 'dry-run' }
    $timestamp = [datetime]::UtcNow
    $states = [System.Collections.Generic.List[object]]::new()

    foreach ($email in $targets) {
        try {
            $assignedSkus = @(Get-GApiUserLicenseSkus -Email $email -Credential $credentialContext)
            $before = Test-EducationPlusAssigned -AssignedSkus $assignedSkus -TargetSkuId $EducationPlusSkuId
            $states.Add([pscustomobject]@{
                Email  = $email
                Before = $before
                Error  = ''
            })
        }
        catch {
            $states.Add([pscustomobject]@{
                Email  = $email
                Before = $false
                Error  = Get-SafeEduPlusErrorMessage -Message $_.Exception.Message
            })
        }
    }

    if ($Apply) {
        $candidateCount = @($states | Where-Object { [string]::IsNullOrEmpty($_.Error) -and $_.Before }).Count
        $sourceDescription = if ($OuTarget) { $OuPath } else { "CSV '$CsvPath'" }
        $answer = Read-Host "[Apply] Are you sure you want to remove the Education Plus license from $candidateCount user(s) in ${sourceDescription}? Type YES to continue"
        if ([string]::IsNullOrWhiteSpace($answer) -or $answer.Trim() -ine 'YES') {
            Write-Warning 'Confirmation was not YES. No license assignments were removed.'
            return 2
        }
    }

    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($state in $states) {
        if (-not [string]::IsNullOrEmpty($state.Error)) {
            $results.Add((New-EduPlusResult -Email $state.Email -Status 'error' -EduPlusBefore $false -EduPlusAfter $false -Error $state.Error))
            Write-Warning "[$($state.Email)] error: $($state.Error)"
            continue
        }

        if (-not $state.Before) {
            $results.Add((New-EduPlusResult -Email $state.Email -Status 'already-clean' -EduPlusBefore $false -EduPlusAfter $false -Error ''))
            Write-Host "[$($state.Email)] Education Plus: absent -> absent (already clean)"
            continue
        }

        if (-not $Apply) {
            $results.Add((New-EduPlusResult -Email $state.Email -Status 'dry-run-remove' -EduPlusBefore $true -EduPlusAfter $true -Error ''))
            Write-Host "[$($state.Email)] Education Plus: present -> present (dry-run plan: remove)"
            continue
        }

        try {
            Remove-GApiLicenseAssignment -Email $state.Email -SkuId $EducationPlusSkuId -Credential $credentialContext
            $results.Add((New-EduPlusResult -Email $state.Email -Status 'removed' -EduPlusBefore $true -EduPlusAfter $false -Error ''))
            Write-Host "[$($state.Email)] Education Plus: present -> absent (removed)"
        }
        catch {
            $safeError = Get-SafeEduPlusErrorMessage -Message $_.Exception.Message
            $results.Add((New-EduPlusResult -Email $state.Email -Status 'error' -EduPlusBefore $true -EduPlusAfter $true -Error $safeError))
            Write-Warning "[$($state.Email)] error: $safeError"
        }
    }

    $reportFile = Export-EduPlusReport -Results $results.ToArray() -Mode $mode -Timestamp $timestamp -ReportPath $ReportPath
    $removedCount = @($results | Where-Object Status -eq 'removed').Count
    $alreadyCleanCount = @($results | Where-Object Status -eq 'already-clean').Count
    $errorCount = @($results | Where-Object Status -eq 'error').Count

    Write-Host "Report: $reportFile"
    Write-Host "Summary: processed=$($results.Count), removed=$removedCount, already-clean=$alreadyCleanCount, errors=$errorCount"

    if ($errorCount -gt 0) {
        return 1
    }
    return 0
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        $exitCode = Invoke-EducationPlusLicenseRemoval @PSBoundParameters
    }
    catch {
        $safeFatalError = Get-SafeEduPlusErrorMessage -Message $_.Exception.Message
        Write-Error $safeFatalError -ErrorAction Continue
        $exitCode = 1
    }
    exit $exitCode
}
