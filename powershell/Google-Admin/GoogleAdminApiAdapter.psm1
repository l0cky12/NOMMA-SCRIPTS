Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

Export-ModuleMember -Function @(
    'Get-GApiDirectoryUsersByOU',
    'Get-GApiUserLicenseSkus',
    'Remove-GApiLicenseAssignment'
)
