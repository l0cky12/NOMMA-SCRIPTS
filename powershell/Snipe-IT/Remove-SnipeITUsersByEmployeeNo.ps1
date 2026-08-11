#Requires -Version 7.0
<#
.SYNOPSIS
    Safely soft-deletes Snipe-IT users from a headerless CSV of Employee Nos.

.DESCRIPTION
    Looks up Snipe-IT users by employee_num and reports the proposed changes.
    DryRun is the default; actual soft deletion requires -Apply. Users with
    checked-out assets are always blocked from deletion.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$CsvPath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$BaseUrl,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$AuthToken,

    [switch]$Apply,

    [ValidateRange(0, 2147483647)]
    [int]$ConfirmRange = 0,

    [scriptblock]$HttpRequest,

    [ValidateRange(0, 30)]
    [double]$RequestDelaySeconds = 0.25,

    [ValidateRange(0, 10)]
    [int]$MaxRetries = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Protect-SnipeITText {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [object]$InputObject,

        [AllowEmptyString()]
        [string]$Token = ''
    )

    if ($null -eq $InputObject) {
        return ''
    }

    $text = if ($InputObject -is [string]) {
        $InputObject
    }
    else {
        try {
            $InputObject | ConvertTo-Json -Depth 10 -Compress -ErrorAction Stop
        }
        catch {
            [string]$InputObject
        }
    }

    if (-not [string]::IsNullOrEmpty($Token)) {
        $text = [regex]::Replace(
            $text,
            [regex]::Escape($Token),
            '[REDACTED]',
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
    }

    return [regex]::Replace(
        $text,
        '(?i)Bearer\s+[A-Za-z0-9._~+/=-]+',
        'Bearer [REDACTED]'
    )
}

function Read-SnipeITEmployeeNoCsv {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$CsvPath
    )

    if (-not [System.IO.Path]::IsPathFullyQualified($CsvPath)) {
        throw "CsvPath must be an absolute path: $CsvPath"
    }
    if (-not (Test-Path -LiteralPath $CsvPath -PathType Leaf)) {
        throw "CSV file was not found: $CsvPath"
    }

    $values = [System.Collections.Generic.List[string]]::new()
    foreach ($line in @(Get-Content -LiteralPath $CsvPath -ErrorAction Stop)) {
        $value = (([string]$line).TrimEnd("`r") -split ',', 2)[0].Trim()
        if ($value.Length -ge 2 -and $value.StartsWith('"') -and $value.EndsWith('"')) {
            $value = $value.Substring(1, $value.Length - 2).Trim()
        }
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $values.Add($value)
        }
    }

    if ($values.Count -eq 0) {
        throw "CSV file '$CsvPath' is invalid because it contains zero data rows."
    }

    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $uniqueValues = [System.Collections.Generic.List[string]]::new()
    $counts = [System.Collections.Generic.Dictionary[string, int]]::new([System.StringComparer]::Ordinal)

    foreach ($value in $values) {
        if ($counts.ContainsKey($value)) {
            $counts[$value]++
        }
        else {
            $counts[$value] = 1
        }

        if ($seen.Add($value)) {
            $uniqueValues.Add($value)
        }
    }

    $duplicates = [System.Collections.Generic.List[object]]::new()
    foreach ($value in $uniqueValues) {
        if ($counts[$value] -gt 1) {
            $duplicates.Add([pscustomobject]@{
                    EmployeeNo = $value
                    Count      = $counts[$value]
                })
        }
    }

    return [pscustomobject]@{
        EmployeeNos = $uniqueValues.ToArray()
        Duplicates  = $duplicates.ToArray()
    }
}

function Invoke-SnipeITHttpRequest {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('GET', 'DELETE')]
        [string]$Method,

        [Parameter(Mandatory)]
        [string]$Uri,

        [Parameter(Mandatory)]
        [hashtable]$Headers,

        [AllowNull()]
        [scriptblock]$HttpRequest,

        [Parameter(Mandatory)]
        [string]$AuthToken
    )

    $responseHeaders = $null
    try {
        if ($null -ne $HttpRequest) {
            $rawResponse = & $HttpRequest -Method $Method -Uri $Uri -Headers $Headers
            $statusCode = 200
            $body = $rawResponse

            if ($null -ne $rawResponse) {
                $statusProperty = $rawResponse.PSObject.Properties['StatusCode']
                if ($null -ne $statusProperty) {
                    $statusCode = [int]$statusProperty.Value
                }

                $bodyProperty = $rawResponse.PSObject.Properties['Body']
                $contentProperty = $rawResponse.PSObject.Properties['Content']
                if ($null -ne $bodyProperty) {
                    $body = $bodyProperty.Value
                }
                elseif ($null -ne $contentProperty) {
                    $body = $contentProperty.Value
                }

                $headersProperty = $rawResponse.PSObject.Properties['Headers']
                if ($null -ne $headersProperty) {
                    $responseHeaders = $headersProperty.Value
                }
            }
        }
        else {
            $snipeStatusCode = 0
            $snipeResponseHeaders = $null
            $body = Invoke-RestMethod -Method $Method -Uri $Uri -Headers $Headers `
                -StatusCodeVariable snipeStatusCode -ResponseHeadersVariable snipeResponseHeaders `
                -ErrorAction Stop
            $statusCode = [int]$snipeStatusCode
            $responseHeaders = $snipeResponseHeaders
        }

        if ($body -is [string] -and -not [string]::IsNullOrWhiteSpace($body)) {
            try {
                $body = $body | ConvertFrom-Json -ErrorAction Stop
            }
            catch {
                # A non-JSON response body is preserved for redacted error reporting.
            }
        }

        $succeeded = $statusCode -ge 200 -and $statusCode -lt 300
        $errorText = if ($succeeded) {
            ''
        }
        else {
            $redactedBody = Protect-SnipeITText -InputObject $body -Token $AuthToken
            if ([string]::IsNullOrWhiteSpace($redactedBody)) {
                "HTTP $statusCode"
            }
            else {
                "HTTP ${statusCode}: $redactedBody"
            }
        }

        return [pscustomobject]@{
            Succeeded  = $succeeded
            StatusCode = $statusCode
            Body       = $body
            Headers    = $responseHeaders
            Error      = $errorText
        }
    }
    catch {
        $statusCode = 0
        $responseProperty = $_.Exception.PSObject.Properties['Response']
        if ($null -ne $responseProperty -and $null -ne $responseProperty.Value) {
            $statusProperty = $responseProperty.Value.PSObject.Properties['StatusCode']
            if ($null -ne $statusProperty -and $null -ne $statusProperty.Value) {
                $statusCode = [int]$statusProperty.Value
            }

            $headersProperty = $responseProperty.Value.PSObject.Properties['Headers']
            if ($null -ne $headersProperty) {
                $responseHeaders = $headersProperty.Value
            }
        }

        $body = if (-not [string]::IsNullOrWhiteSpace($_.ErrorDetails.Message)) {
            $_.ErrorDetails.Message
        }
        else {
            $_.Exception.Message
        }
        if ($body -is [string] -and -not [string]::IsNullOrWhiteSpace($body)) {
            try {
                $body = $body | ConvertFrom-Json -ErrorAction Stop
            }
            catch {
                # A non-JSON response body is preserved for redacted error reporting.
            }
        }
        $redactedBody = Protect-SnipeITText -InputObject $body -Token $AuthToken
        $errorText = if ($statusCode -gt 0) {
            "HTTP ${statusCode}: $redactedBody"
        }
        else {
            "Request failed: $redactedBody"
        }

        return [pscustomobject]@{
            Succeeded  = $false
            StatusCode = $statusCode
            Body       = $body
            Headers    = $responseHeaders
            Error      = $errorText
        }
    }
}

function Get-SnipeITRetryDelaySeconds {
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Response,

        [Parameter(Mandatory)]
        [ValidateRange(0, 10)]
        [int]$Attempt
    )

    foreach ($propertyName in @('retryAfter', 'retry_after')) {
        if ($null -ne $Response.Body) {
            $property = $Response.Body.PSObject.Properties[$propertyName]
            if ($null -ne $property -and $null -ne $property.Value) {
                try {
                    $seconds = [Convert]::ToDouble($property.Value, [System.Globalization.CultureInfo]::InvariantCulture)
                    if ($seconds -ge 0) {
                        return $seconds
                    }
                }
                catch {
                    # Fall through to the next retry-delay source.
                }
            }
        }
    }

    if ($null -ne $Response.Headers) {
        $retryAfter = $null
        if ($Response.Headers -is [System.Collections.IDictionary]) {
            foreach ($key in $Response.Headers.Keys) {
                if ([string]::Equals([string]$key, 'Retry-After', [System.StringComparison]::OrdinalIgnoreCase)) {
                    $retryAfter = $Response.Headers[$key]
                    break
                }
            }
        }
        else {
            $property = $Response.Headers.PSObject.Properties['Retry-After']
            if ($null -ne $property) {
                $retryAfter = $property.Value
            }
            else {
                try {
                    $retryAfter = @($Response.Headers.GetValues('Retry-After'))[0]
                }
                catch {
                    # The response-header type does not expose Retry-After in this form.
                }
            }
        }

        if ($null -ne $retryAfter) {
            try {
                $seconds = [Convert]::ToDouble(@($retryAfter)[0], [System.Globalization.CultureInfo]::InvariantCulture)
                if ($seconds -ge 0) {
                    return $seconds
                }
            }
            catch {
                # Fall through to exponential backoff.
            }
        }
    }

    return [Math]::Pow(2, $Attempt)
}

function Invoke-SnipeITHttpRequestWithRetry {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('GET', 'DELETE')]
        [string]$Method,

        [Parameter(Mandatory)]
        [string]$Uri,

        [Parameter(Mandatory)]
        [hashtable]$Headers,

        [AllowNull()]
        [scriptblock]$HttpRequest,

        [Parameter(Mandatory)]
        [string]$AuthToken,

        [ValidateRange(0, 10)]
        [int]$MaxRetries = 5
    )

    $attempt = 0
    while ($true) {
        $response = Invoke-SnipeITHttpRequest -Method $Method -Uri $Uri -Headers $Headers `
            -HttpRequest $HttpRequest -AuthToken $AuthToken
        if ($response.Succeeded -or $response.StatusCode -ne 429 -or $attempt -ge $MaxRetries) {
            return $response
        }

        $delaySeconds = Get-SnipeITRetryDelaySeconds -Response $response -Attempt $attempt
        $jitter = (Get-Random -Minimum 500 -Maximum 1501) / 1000.0
        $sleepMilliseconds = [int][Math]::Ceiling($delaySeconds * $jitter * 1000)
        if ($sleepMilliseconds -gt 0) {
            Start-Sleep -Milliseconds $sleepMilliseconds
        }
        $attempt++
    }
}

function New-SnipeITResult {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$EmployeeNo,

        [AllowEmptyString()]
        [string]$Username = '',

        [AllowEmptyString()]
        [string]$Email = '',

        [AllowEmptyString()]
        [string]$UserId = '',

        [Parameter(Mandatory)]
        [ValidateSet('not_found', 'blocked_assets', 'planned', 'deleted', 'error')]
        [string]$Result,

        [AllowEmptyString()]
        [string]$Detail = ''
    )

    return [pscustomobject][ordered]@{
        EmployeeNo = $EmployeeNo
        Username   = $Username
        Email      = $Email
        UserId     = $UserId
        Result     = $Result
        Detail     = $Detail
    }
}

function Get-SnipeITUserMatch {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$EmployeeNo,

        [Parameter(Mandatory)]
        [string]$BaseUrl,

        [Parameter(Mandatory)]
        [hashtable]$Headers,

        [AllowNull()]
        [scriptblock]$HttpRequest,

        [Parameter(Mandatory)]
        [string]$AuthToken,

        [ValidateRange(0, 10)]
        [int]$MaxRetries = 5
    )

    $encodedEmployeeNo = [uri]::EscapeDataString($EmployeeNo)
    $uri = "$BaseUrl/api/v1/users?employee_num=$encodedEmployeeNo&limit=5"
    $response = Invoke-SnipeITHttpRequestWithRetry -Method GET -Uri $uri -Headers $Headers `
        -HttpRequest $HttpRequest -AuthToken $AuthToken -MaxRetries $MaxRetries

    if (-not $response.Succeeded) {
        return [pscustomobject]@{
            EmployeeNo = $EmployeeNo
            MatchState = 'error'
            Username   = ''
            Email      = ''
            UserId     = ''
            AssetsCount = 0
            MatchCount = 0
            Detail     = $response.Error
        }
    }

    try {
        if ($null -eq $response.Body) {
            throw 'Lookup response body was empty.'
        }
        $totalProperty = $response.Body.PSObject.Properties['total']
        $rowsProperty = $response.Body.PSObject.Properties['rows']
        if ($null -eq $totalProperty -or $null -eq $rowsProperty) {
            throw "Lookup response did not contain the expected 'total' and 'rows' fields."
        }

        $total = [int]$totalProperty.Value
        if ($total -eq 0) {
            return [pscustomobject]@{
                EmployeeNo = $EmployeeNo
                MatchState = 'not_found'
                Username   = ''
                Email      = ''
                UserId     = ''
                AssetsCount = 0
                MatchCount = 0
                Detail     = ''
            }
        }

        $rows = @($rowsProperty.Value)
        if ($rows.Count -eq 0 -or $null -eq $rows[0]) {
            throw "Lookup reported $total match(es) but returned no user rows."
        }

        $row = $rows[0]
        $idProperty = $row.PSObject.Properties['id']
        if ($null -eq $idProperty -or $null -eq $idProperty.Value) {
            throw 'The first lookup row did not contain a user id.'
        }

        $usernameProperty = $row.PSObject.Properties['username']
        $emailProperty = $row.PSObject.Properties['email']
        $assetsProperty = $row.PSObject.Properties['assets_count']
        $assetsCount = if ($null -eq $assetsProperty -or $null -eq $assetsProperty.Value) {
            0
        }
        else {
            [int]$assetsProperty.Value
        }

        return [pscustomobject]@{
            EmployeeNo = $EmployeeNo
            MatchState = 'matched'
            Username   = if ($null -eq $usernameProperty) { '' } else { [string]$usernameProperty.Value }
            Email      = if ($null -eq $emailProperty) { '' } else { [string]$emailProperty.Value }
            UserId     = [string]$idProperty.Value
            AssetsCount = $assetsCount
            MatchCount = $total
            Detail     = if ($total -gt 1) {
                "$total matches found; targeting the first user id and noting the ambiguity."
            }
            else {
                ''
            }
        }
    }
    catch {
        return [pscustomobject]@{
            EmployeeNo = $EmployeeNo
            MatchState = 'error'
            Username   = ''
            Email      = ''
            UserId     = ''
            AssetsCount = 0
            MatchCount = 0
            Detail     = Protect-SnipeITText -InputObject $_.Exception.Message -Token $AuthToken
        }
    }
}

function Remove-SnipeITUserByEmployeeNo {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Match,

        [Parameter(Mandatory)]
        [string]$BaseUrl,

        [Parameter(Mandatory)]
        [hashtable]$Headers,

        [Parameter(Mandatory)]
        [bool]$Apply,

        [Parameter(Mandatory)]
        [bool]$DeletionApproved,

        [AllowNull()]
        [scriptblock]$HttpRequest,

        [Parameter(Mandatory)]
        [string]$AuthToken,

        [ValidateRange(0, 10)]
        [int]$MaxRetries = 5
    )

    if ($Match.MatchState -eq 'not_found') {
        return New-SnipeITResult -EmployeeNo $Match.EmployeeNo -Result not_found
    }
    if ($Match.MatchState -eq 'error') {
        return New-SnipeITResult -EmployeeNo $Match.EmployeeNo -Result error -Detail $Match.Detail
    }

    if ($Match.AssetsCount -gt 0) {
        $detail = "User holds $($Match.AssetsCount) checked-out asset(s); deletion was blocked."
        return New-SnipeITResult -EmployeeNo $Match.EmployeeNo -Username $Match.Username `
            -Email $Match.Email -UserId $Match.UserId -Result blocked_assets -Detail $detail
    }

    if (-not $Apply) {
        return New-SnipeITResult -EmployeeNo $Match.EmployeeNo -Username $Match.Username `
            -Email $Match.Email -UserId $Match.UserId -Result planned -Detail $Match.Detail
    }

    if (-not $DeletionApproved) {
        return New-SnipeITResult -EmployeeNo $Match.EmployeeNo -Username $Match.Username `
            -Email $Match.Email -UserId $Match.UserId -Result error `
            -Detail 'Deletion was cancelled because confirmation was not granted.'
    }

    $encodedUserId = [uri]::EscapeDataString([string]$Match.UserId)
    $uri = "$BaseUrl/api/v1/users/$encodedUserId"
    $response = Invoke-SnipeITHttpRequestWithRetry -Method DELETE -Uri $uri -Headers $Headers `
        -HttpRequest $HttpRequest -AuthToken $AuthToken -MaxRetries $MaxRetries

    if (-not $response.Succeeded) {
        return New-SnipeITResult -EmployeeNo $Match.EmployeeNo -Username $Match.Username `
            -Email $Match.Email -UserId $Match.UserId -Result error -Detail $response.Error
    }
    if ($response.StatusCode -ne 200) {
        return New-SnipeITResult -EmployeeNo $Match.EmployeeNo -Username $Match.Username `
            -Email $Match.Email -UserId $Match.UserId -Result error `
            -Detail "Unexpected HTTP status $($response.StatusCode) from DELETE; expected 200."
    }

    return New-SnipeITResult -EmployeeNo $Match.EmployeeNo -Username $Match.Username `
        -Email $Match.Email -UserId $Match.UserId -Result deleted -Detail $Match.Detail
}

function Invoke-SnipeITUserRemoval {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$CsvPath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$BaseUrl,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$AuthToken,

        [switch]$Apply,

        [ValidateRange(0, 2147483647)]
        [int]$ConfirmRange = 0,

        [AllowNull()]
        [scriptblock]$HttpRequest,

        [ValidateRange(0, 30)]
        [double]$RequestDelaySeconds = 0.25,

        [ValidateRange(0, 10)]
        [int]$MaxRetries = 5
    )

    $normalizedBaseUrl = $BaseUrl.Trim().TrimEnd('/')
    if ([string]::IsNullOrWhiteSpace($normalizedBaseUrl)) {
        throw 'BaseUrl must not be empty.'
    }

    $csv = Read-SnipeITEmployeeNoCsv -CsvPath $CsvPath
    foreach ($duplicate in $csv.Duplicates) {
        Write-Warning "Duplicate Employee No '$($duplicate.EmployeeNo)' appears $($duplicate.Count) times; it will be acted on once."
    }

    $headers = @{
        Authorization = "Bearer $AuthToken"
        Accept        = 'application/json'
    }

    $matches = [System.Collections.Generic.List[object]]::new()
    $lookupIndex = 0
    foreach ($employeeNo in $csv.EmployeeNos) {
        if ($lookupIndex -gt 0 -and $null -eq $HttpRequest -and $RequestDelaySeconds -gt 0) {
            Start-Sleep -Milliseconds ([int][Math]::Ceiling($RequestDelaySeconds * 1000))
        }
        $match = Get-SnipeITUserMatch -EmployeeNo $employeeNo -BaseUrl $normalizedBaseUrl `
            -Headers $headers -HttpRequest $HttpRequest -AuthToken $AuthToken -MaxRetries $MaxRetries
        $matches.Add($match)
        $lookupIndex++
        if ($match.MatchCount -gt 1) {
            Write-Warning "Employee No '$employeeNo' returned $($match.MatchCount) matches; the first user id will be targeted."
        }
    }

    $deletionApproved = $true
    if ($Apply -and $ConfirmRange -gt 0) {
        $deleteCandidateCount = @(
            $matches | Where-Object { $_.MatchState -eq 'matched' -and $_.AssetsCount -le 0 }
        ).Count
        if ($deleteCandidateCount -gt $ConfirmRange) {
            $answer = Read-Host "Apply would delete $deleteCandidateCount users, exceeding ConfirmRange $ConfirmRange. Type YES to continue"
            $deletionApproved = $answer -ceq 'YES'
        }
    }

    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($match in $matches) {
        $result = Remove-SnipeITUserByEmployeeNo -Match $match -BaseUrl $normalizedBaseUrl `
            -Headers $headers -Apply ([bool]$Apply) -DeletionApproved $deletionApproved `
            -HttpRequest $HttpRequest -AuthToken $AuthToken -MaxRetries $MaxRetries
        $results.Add($result)
    }

    $resultArray = $results.ToArray()
    $notFoundCount = @($resultArray | Where-Object Result -eq 'not_found').Count
    $blockedCount = @($resultArray | Where-Object Result -eq 'blocked_assets').Count
    $errorCount = @($resultArray | Where-Object Result -eq 'error').Count
    $deletedCount = @($resultArray | Where-Object Result -eq 'deleted').Count
    $plannedCount = @($resultArray | Where-Object Result -eq 'planned').Count

    $summary = if ($Apply) {
        "$deletedCount deleted; $notFoundCount not found; $blockedCount blocked (assets checked out); $errorCount errors"
    }
    else {
        "$plannedCount would be deleted; $notFoundCount not found; $blockedCount blocked (assets checked out); $errorCount errors"
    }

    return [pscustomobject]@{
        Mode       = if ($Apply) { 'Apply' } else { 'DryRun' }
        Results    = $resultArray
        Duplicates = $csv.Duplicates
        Summary    = $summary
        ExitCode   = if ($blockedCount -gt 0 -or $errorCount -gt 0) { 1 } else { 0 }
    }
}

function Write-SnipeITRunReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Run,

        [Parameter(Mandatory)]
        [string]$AuthToken
    )

    $displayRows = @($Run.Results | ForEach-Object {
            [pscustomobject][ordered]@{
                'Employee No' = Protect-SnipeITText -InputObject $_.EmployeeNo -Token $AuthToken
                username      = Protect-SnipeITText -InputObject $_.Username -Token $AuthToken
                email         = Protect-SnipeITText -InputObject $_.Email -Token $AuthToken
                'user id'     = Protect-SnipeITText -InputObject $_.UserId -Token $AuthToken
                result        = $_.Result
            }
        })

    if ($displayRows.Count -gt 0) {
        Write-Output (($displayRows | Format-Table -AutoSize | Out-String).TrimEnd())
    }

    foreach ($result in $Run.Results) {
        if (-not [string]::IsNullOrWhiteSpace($result.Detail)) {
            $safeEmployeeNo = Protect-SnipeITText -InputObject $result.EmployeeNo -Token $AuthToken
            $safeDetail = Protect-SnipeITText -InputObject $result.Detail -Token $AuthToken
            Write-Warning "Employee No '$safeEmployeeNo': $safeDetail"
        }
    }

    Write-Output (Protect-SnipeITText -InputObject $Run.Summary -Token $AuthToken)
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        $run = Invoke-SnipeITUserRemoval -CsvPath $CsvPath -BaseUrl $BaseUrl -AuthToken $AuthToken `
            -Apply:$Apply -ConfirmRange $ConfirmRange -RequestDelaySeconds $RequestDelaySeconds `
            -MaxRetries $MaxRetries -HttpRequest $HttpRequest
        Write-SnipeITRunReport -Run $run -AuthToken $AuthToken
        exit $run.ExitCode
    }
    catch {
        $safeError = Protect-SnipeITText -InputObject $_.Exception.Message -Token $AuthToken
        Write-Error $safeError
        exit 1
    }
}
