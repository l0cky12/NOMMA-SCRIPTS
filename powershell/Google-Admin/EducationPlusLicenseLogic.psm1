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

Export-ModuleMember -Function @(
    'ConvertFrom-EduPlusCsv',
    'Test-EducationPlusAssigned',
    'New-EduPlusResult',
    'Format-EduPlusReportRows'
)
