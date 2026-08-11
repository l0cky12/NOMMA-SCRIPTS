<#
.SYNOPSIS
    Safely removes Education Plus licenses from users in an OU or CSV list.

.DESCRIPTION
    Resolves users from a Google Workspace organizational unit or a CSV file,
    checks each user's assigned SKUs, and targets only the configured Education
    Plus SKU. The default mode is a non-mutating dry run. Actual removal requires
    both -Apply and one batch-wide confirmation by typing YES.

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

Import-Module (Join-Path $PSScriptRoot 'EducationPlusLicenseLogic.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'GoogleAdminApiAdapter.psm1') -Force -ErrorAction Stop

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
