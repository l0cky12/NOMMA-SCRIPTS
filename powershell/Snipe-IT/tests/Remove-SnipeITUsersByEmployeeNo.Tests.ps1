BeforeAll {
    $scriptPath = Join-Path $PSScriptRoot '../Remove-SnipeITUsersByEmployeeNo.ps1'
    . $scriptPath -CsvPath '/tmp/not-used.csv' -BaseUrl 'https://snipe.test' -AuthToken 'not-used'

    function New-TestLookupResponse {
        param(
            [int]$Id = 42,
            [string]$EmployeeNo = 'E1001',
            [int]$AssetsCount = 0,
            [int]$Total = 1
        )

        if ($Total -eq 0) {
            return [pscustomobject]@{
                total = 0
                rows  = @()
            }
        }

        return [pscustomobject]@{
            total = $Total
            rows  = @(
                [pscustomobject]@{
                    id           = $Id
                    username     = "user-$EmployeeNo"
                    email        = "$EmployeeNo@example.test"
                    first_name   = 'Test'
                    last_name    = 'User'
                    employee_num = $EmployeeNo
                    assets_count = $AssetsCount
                }
            )
        }
    }

    function Invoke-TestScriptProcess {
        param(
            [Parameter(Mandatory)]
            [string]$CsvPath,

            [Parameter(Mandatory)]
            [string]$CapturePath,

            [AllowEmptyString()]
            [string]$BaseUrl,

            [AllowEmptyString()]
            [string]$AuthToken
        )

        $harnessPath = Join-Path $TestDrive 'invoke-snipeit-script.ps1'
        @'
param(
    [string]$TargetScript,
    [string]$CsvPath,
    [string]$CapturePath,
    [string]$BaseUrl,
    [string]$AuthToken
)

$httpMock = {
    param($Method, $Uri, $Headers)

    [pscustomobject]@{
        Method        = $Method
        Uri           = $Uri
        Authorization = $Headers.Authorization
    } | ConvertTo-Json -Compress | Set-Content -LiteralPath $CapturePath -Encoding utf8NoBOM

    return [pscustomobject]@{
        total = 0
        rows  = @()
    }
}

$invokeParameters = @{
    CsvPath     = $CsvPath
    HttpRequest = $httpMock
}
if ($PSBoundParameters.ContainsKey('BaseUrl')) {
    $invokeParameters.BaseUrl = $BaseUrl
}
if ($PSBoundParameters.ContainsKey('AuthToken')) {
    $invokeParameters.AuthToken = $AuthToken
}

& $TargetScript @invokeParameters
'@ | Set-Content -LiteralPath $harnessPath -Encoding utf8NoBOM

        $arguments = @(
            '-NoProfile'
            '-NonInteractive'
            '-File'
            $harnessPath
            '-TargetScript'
            $scriptPath
            '-CsvPath'
            $CsvPath
            '-CapturePath'
            $CapturePath
        )
        if ($PSBoundParameters.ContainsKey('BaseUrl')) {
            $arguments += @('-BaseUrl', $BaseUrl)
        }
        if ($PSBoundParameters.ContainsKey('AuthToken')) {
            $arguments += @('-AuthToken', $AuthToken)
        }

        $output = & (Get-Process -Id $PID).Path @arguments 2>&1
        return [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Output   = $output | Out-String
        }
    }
}

Describe 'Remove-SnipeITUsersByEmployeeNo' {
    BeforeEach {
        $script:requests = [System.Collections.Generic.List[object]]::new()
        $script:lookupResponses = @{}
        $script:deleteStatusCode = 200
        $script:deleteBody = [pscustomobject]@{ status = 'success' }
        $script:httpMock = {
            param($Method, $Uri, $Headers)

            $script:requests.Add([pscustomobject]@{
                    Method  = $Method
                    Uri     = $Uri
                    Headers = $Headers
                })

            if ($Method -eq 'DELETE') {
                return [pscustomobject]@{
                    StatusCode = $script:deleteStatusCode
                    Body       = $script:deleteBody
                }
            }

            $employeeNoMatch = [regex]::Match($Uri, '[?&]employee_num=([^&]+)')
            $employeeNo = [uri]::UnescapeDataString($employeeNoMatch.Groups[1].Value)
            if ($script:lookupResponses.ContainsKey($employeeNo)) {
                return $script:lookupResponses[$employeeNo]
            }

            return [pscustomobject]@{
                total = 0
                rows  = @()
            }
        }
    }

    It 'looks up one valid Employee No in DryRun, reports planned, and never deletes' {
        $csvPath = Join-Path $TestDrive 'dry-run.csv'
        'E1001' | Set-Content -LiteralPath $csvPath -Encoding utf8NoBOM
        $script:lookupResponses['E1001'] = New-TestLookupResponse -EmployeeNo E1001 -Id 42

        $run = Invoke-SnipeITUserRemoval -CsvPath $csvPath -BaseUrl 'https://snipe.test/' `
            -AuthToken 'offline-token' -HttpRequest $script:httpMock

        $run.Mode | Should -Be 'DryRun'
        $run.Results | Should -HaveCount 1
        $run.Results[0].Result | Should -Be 'planned'
        $run.Summary | Should -Be '1 would be deleted; 0 not found; 0 blocked (assets checked out); 0 errors'
        @($script:requests | Where-Object Method -eq 'GET') | Should -HaveCount 1
        @($script:requests | Where-Object Method -eq 'DELETE') | Should -HaveCount 0
    }

    It 'deletes one clean user in Apply mode using the correct user id' {
        $csvPath = Join-Path $TestDrive 'apply.csv'
        'E1001' | Set-Content -LiteralPath $csvPath -Encoding utf8NoBOM
        $script:lookupResponses['E1001'] = New-TestLookupResponse -EmployeeNo E1001 -Id 913

        $run = Invoke-SnipeITUserRemoval -CsvPath $csvPath -BaseUrl 'https://snipe.test' `
            -AuthToken 'offline-token' -Apply -HttpRequest $script:httpMock

        $run.Results[0].Result | Should -Be 'deleted'
        $run.ExitCode | Should -Be 0
        $deleteRequests = @($script:requests | Where-Object Method -eq 'DELETE')
        $deleteRequests | Should -HaveCount 1
        $deleteRequests[0].Uri | Should -Be 'https://snipe.test/api/v1/users/913'
    }

    It 'blocks an Apply deletion when the user has checked-out assets' {
        $csvPath = Join-Path $TestDrive 'blocked.csv'
        'E2002' | Set-Content -LiteralPath $csvPath -Encoding utf8NoBOM
        $script:lookupResponses['E2002'] = New-TestLookupResponse -EmployeeNo E2002 -Id 73 -AssetsCount 2

        $run = Invoke-SnipeITUserRemoval -CsvPath $csvPath -BaseUrl 'https://snipe.test' `
            -AuthToken 'offline-token' -Apply -HttpRequest $script:httpMock

        $run.Results[0].Result | Should -Be 'blocked_assets'
        $run.Results[0].Detail | Should -Match '2 checked-out asset'
        $run.ExitCode | Should -Be 1
        @($script:requests | Where-Object Method -eq 'DELETE') | Should -HaveCount 0
    }

    It 'reports an Employee No that is not found without deleting' {
        $csvPath = Join-Path $TestDrive 'not-found.csv'
        'E4040' | Set-Content -LiteralPath $csvPath -Encoding utf8NoBOM

        $run = Invoke-SnipeITUserRemoval -CsvPath $csvPath -BaseUrl 'https://snipe.test' `
            -AuthToken 'offline-token' -Apply -HttpRequest $script:httpMock

        $run.Results[0].Result | Should -Be 'not_found'
        $run.ExitCode | Should -Be 0
        @($script:requests | Where-Object Method -eq 'DELETE') | Should -HaveCount 0
    }

    It 'handles blank lines and headerless multi-row input and rejects an empty-data file' {
        $csvPath = Join-Path $TestDrive 'multiple.csv'
        "`n  E1001`r`n`t`n E2002  `n" | Set-Content -LiteralPath $csvPath -Encoding utf8NoBOM
        $script:lookupResponses['E1001'] = New-TestLookupResponse -EmployeeNo E1001 -Id 1
        $script:lookupResponses['E2002'] = New-TestLookupResponse -EmployeeNo E2002 -Id 2

        $run = Invoke-SnipeITUserRemoval -CsvPath $csvPath -BaseUrl 'https://snipe.test' `
            -AuthToken 'offline-token' -HttpRequest $script:httpMock

        $run.Results | Should -HaveCount 2
        $run.Results.EmployeeNo | Should -Be @('E1001', 'E2002')
        $run.Results.Result | Should -Be @('planned', 'planned')

        $emptyPath = Join-Path $TestDrive 'empty.csv'
        " `n`t`n`r`n" | Set-Content -LiteralPath $emptyPath -Encoding utf8NoBOM
        { Read-SnipeITEmployeeNoCsv -CsvPath $emptyPath } | Should -Throw '*zero data rows*'
    }

    It 'parses the first field from an Excel row with trailing empty columns' {
        $csvPath = Join-Path $TestDrive 'excel-trailing-columns.csv'
        '0016171,,,,,,,,' | Set-Content -LiteralPath $csvPath -Encoding utf8NoBOM

        $csv = Read-SnipeITEmployeeNoCsv -CsvPath $csvPath

        $csv.EmployeeNos | Should -Be @('0016171')
    }

    It 'strips surrounding quotes from a single-column Employee No' {
        $csvPath = Join-Path $TestDrive 'quoted.csv'
        '"0023456"' | Set-Content -LiteralPath $csvPath -Encoding utf8NoBOM

        $csv = Read-SnipeITEmployeeNoCsv -CsvPath $csvPath

        $csv.EmployeeNos | Should -Be @('0023456')
    }

    It 'parses mixed real-world CSV lines in order without empty values' {
        $csvPath = Join-Path $TestDrive 'mixed-real-world.csv'
        @('0016171,,,,,,,,', '', '"0017225"', '3015958,,,') |
            Set-Content -LiteralPath $csvPath -Encoding utf8NoBOM

        $csv = Read-SnipeITEmployeeNoCsv -CsvPath $csvPath

        $csv.EmployeeNos | Should -Be @('0016171', '0017225', '3015958')
        $csv.EmployeeNos | Should -HaveCount 3
    }

    It 'reports duplicate Employee Nos and acts on each unique value once' {
        $csvPath = Join-Path $TestDrive 'duplicates.csv'
        "E1001`nE1001`nE2002`nE1001" | Set-Content -LiteralPath $csvPath -Encoding utf8NoBOM
        $script:lookupResponses['E1001'] = New-TestLookupResponse -EmployeeNo E1001 -Id 1
        $script:lookupResponses['E2002'] = New-TestLookupResponse -EmployeeNo E2002 -Id 2
        $duplicateWarnings = @()

        $run = Invoke-SnipeITUserRemoval -CsvPath $csvPath -BaseUrl 'https://snipe.test' `
            -AuthToken 'offline-token' -HttpRequest $script:httpMock -WarningVariable duplicateWarnings

        $run.Results | Should -HaveCount 2
        @($script:requests | Where-Object Method -eq 'GET') | Should -HaveCount 2
        @($script:requests | Where-Object Method -eq 'DELETE') | Should -HaveCount 0
        ($duplicateWarnings -join ' ') | Should -Match "Duplicate Employee No 'E1001' appears 3 times"
    }

    It 'captures a DELETE 4xx as an error and returns a nonzero status' {
        $csvPath = Join-Path $TestDrive 'delete-error.csv'
        'E1001' | Set-Content -LiteralPath $csvPath -Encoding utf8NoBOM
        $script:lookupResponses['E1001'] = New-TestLookupResponse -EmployeeNo E1001 -Id 42
        $script:deleteStatusCode = 409
        $script:deleteBody = [pscustomobject]@{ messages = 'User could not be deleted' }

        $run = Invoke-SnipeITUserRemoval -CsvPath $csvPath -BaseUrl 'https://snipe.test' `
            -AuthToken 'offline-token' -Apply -HttpRequest $script:httpMock

        $run.Results[0].Result | Should -Be 'error'
        $run.Results[0].Detail | Should -Match 'HTTP 409'
        $run.Results[0].Detail | Should -Match 'User could not be deleted'
        $run.ExitCode | Should -Be 1
        @($script:requests | Where-Object Method -eq 'DELETE') | Should -HaveCount 1
    }

    It 'retries one lookup 429 and returns the successful matched result' {
        $csvPath = Join-Path $TestDrive 'retry-once.csv'
        'E4291' | Set-Content -LiteralPath $csvPath -Encoding utf8NoBOM
        $script:retryLookupCalls = 0
        $retryMock = {
            param($Method, $Uri, $Headers)

            $script:retryLookupCalls++
            if ($script:retryLookupCalls -eq 1) {
                return [pscustomobject]@{
                    StatusCode = 429
                    Body       = [pscustomobject]@{ retryAfter = 0 }
                }
            }

            return [pscustomobject]@{
                StatusCode = 200
                Body       = New-TestLookupResponse -EmployeeNo E4291 -Id 4291
            }
        }

        $run = Invoke-SnipeITUserRemoval -CsvPath $csvPath -BaseUrl 'https://snipe.test' `
            -AuthToken 'offline-token' -HttpRequest $retryMock -MaxRetries 2

        $run.Results[0].Result | Should -Be 'planned'
        $run.Results[0].Result | Should -Not -Be 'error'
        $script:retryLookupCalls | Should -Be 2
    }

    It 'caps persistent lookup 429 retries and returns an error' {
        $csvPath = Join-Path $TestDrive 'retry-exhausted.csv'
        'E4299' | Set-Content -LiteralPath $csvPath -Encoding utf8NoBOM
        $script:retryLookupCalls = 0
        $persistent429Mock = {
            param($Method, $Uri, $Headers)

            $script:retryLookupCalls++
            return [pscustomobject]@{
                StatusCode = 429
                Body       = [pscustomobject]@{ retry_after = 0 }
            }
        }

        $run = Invoke-SnipeITUserRemoval -CsvPath $csvPath -BaseUrl 'https://snipe.test' `
            -AuthToken 'offline-token' -HttpRequest $persistent429Mock -MaxRetries 2

        $run.Results[0].Result | Should -Be 'error'
        $run.Results[0].Detail | Should -Match 'HTTP 429'
        $run.ExitCode | Should -Be 1
        $script:retryLookupCalls | Should -Be 3
    }

    It 'never renders the AuthToken when a request errors' {
        $csvPath = Join-Path $TestDrive 'redaction.csv'
        'E1001' | Set-Content -LiteralPath $csvPath -Encoding utf8NoBOM
        $token = 'AUTH_TOKEN_SENTINEL_7f1c9a'
        $script:deleteStatusCode = 401
        $script:deleteBody = "Authorization: Bearer $token; token=$token"
        $script:lookupResponses['E1001'] = New-TestLookupResponse -EmployeeNo E1001 -Id 42

        $rendered = & {
            $run = Invoke-SnipeITUserRemoval -CsvPath $csvPath -BaseUrl 'https://snipe.test' `
                -AuthToken $token -Apply -HttpRequest $script:httpMock
            Write-SnipeITRunReport -Run $run -AuthToken $token
            $run.Results[0].Detail
        } *>&1 | Out-String

        $rendered | Should -Not -Match ([regex]::Escape($token))
        $rendered | Should -Match 'HTTP 401'
        $rendered | Should -Match '\[REDACTED\]'
    }
}

Describe 'Remove-SnipeITUsersByEmployeeNo environment defaults' {
    BeforeAll {
        $script:hadOriginalSnipeITBaseUrl = Test-Path Env:SNIPEIT_BASE_URL
        $script:hadOriginalSnipeITToken = Test-Path Env:SNIPEIT_TOKEN
        $script:originalSnipeITBaseUrl = [Environment]::GetEnvironmentVariable('SNIPEIT_BASE_URL', 'Process')
        $script:originalSnipeITToken = [Environment]::GetEnvironmentVariable('SNIPEIT_TOKEN', 'Process')
        $script:testSnipeITBaseUrl = 'https://env.snipe.test'
        $script:testSnipeITToken = "  env-offline-token  `n"
        $env:SNIPEIT_BASE_URL = $script:testSnipeITBaseUrl
        $env:SNIPEIT_TOKEN = $script:testSnipeITToken
    }

    AfterAll {
        if ($script:hadOriginalSnipeITBaseUrl) {
            [Environment]::SetEnvironmentVariable(
                'SNIPEIT_BASE_URL', $script:originalSnipeITBaseUrl, 'Process'
            )
        }
        else {
            Remove-Item Env:SNIPEIT_BASE_URL -ErrorAction SilentlyContinue
        }

        if ($script:hadOriginalSnipeITToken) {
            [Environment]::SetEnvironmentVariable(
                'SNIPEIT_TOKEN', $script:originalSnipeITToken, 'Process'
            )
        }
        else {
            Remove-Item Env:SNIPEIT_TOKEN -ErrorAction SilentlyContinue
        }
    }

    It 'uses SNIPEIT_BASE_URL and trims SNIPEIT_TOKEN when explicit values are omitted' {
        $csvPath = Join-Path $TestDrive 'env-defaults.csv'
        $capturePath = Join-Path $TestDrive 'env-defaults-request.json'
        'E-ENV' | Set-Content -LiteralPath $csvPath -Encoding utf8NoBOM

        $process = Invoke-TestScriptProcess -CsvPath $csvPath -CapturePath $capturePath
        $request = Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json

        $process.ExitCode | Should -Be 0
        $request.Uri | Should -Be 'https://env.snipe.test/api/v1/users?employee_num=E-ENV&limit=5'
        $request.Authorization | Should -Be 'Bearer env-offline-token'
    }

    It 'prefers and trims explicit BaseUrl and AuthToken values over environment values' {
        $csvPath = Join-Path $TestDrive 'explicit-values.csv'
        $capturePath = Join-Path $TestDrive 'explicit-values-request.json'
        'E-EXPLICIT' | Set-Content -LiteralPath $csvPath -Encoding utf8NoBOM

        $process = Invoke-TestScriptProcess -CsvPath $csvPath -CapturePath $capturePath `
            -BaseUrl ' https://x.example ' -AuthToken '  tok456  '
        $request = Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json

        $process.ExitCode | Should -Be 0
        $request.Uri | Should -Be 'https://x.example/api/v1/users?employee_num=E-EXPLICIT&limit=5'
        $request.Authorization | Should -Be 'Bearer tok456'
    }

    It 'throws the friendly SNIPEIT_TOKEN error for an explicit whitespace-only AuthToken' {
        $csvPath = Join-Path $TestDrive 'empty-explicit-token.csv'
        $capturePath = Join-Path $TestDrive 'empty-explicit-token-request.json'
        'E-EMPTY-TOKEN' | Set-Content -LiteralPath $csvPath -Encoding utf8NoBOM
        Remove-Item Env:SNIPEIT_TOKEN -ErrorAction SilentlyContinue

        try {
            $process = Invoke-TestScriptProcess -CsvPath $csvPath -CapturePath $capturePath `
                -BaseUrl 'https://explicit.snipe.test' -AuthToken '   '

            $process.ExitCode | Should -Be 1
            $process.Output | Should -Match 'AuthToken was not provided\. Pass -AuthToken or set SNIPEIT_TOKEN\.'
            $process.Output | Should -Not -Match 'Cannot validate argument on parameter'
        }
        finally {
            $env:SNIPEIT_TOKEN = $script:testSnipeITToken
        }
    }

    It 'throws clear errors when BaseUrl or AuthToken has no parameter or environment value' {
        $csvPath = Join-Path $TestDrive 'missing-environment.csv'
        'E-MISSING' | Set-Content -LiteralPath $csvPath -Encoding utf8NoBOM
        Remove-Item Env:SNIPEIT_BASE_URL -ErrorAction SilentlyContinue
        Remove-Item Env:SNIPEIT_TOKEN -ErrorAction SilentlyContinue

        try {
            $baseUrlOutput = & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $scriptPath `
                -CsvPath $csvPath 2>&1 | Out-String
            $baseUrlExitCode = $LASTEXITCODE

            $env:SNIPEIT_BASE_URL = 'https://env.snipe.test'
            $authTokenOutput = & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $scriptPath `
                -CsvPath $csvPath 2>&1 | Out-String
            $authTokenExitCode = $LASTEXITCODE

            $baseUrlExitCode | Should -Be 1
            $baseUrlOutput | Should -Match 'BaseUrl was not provided\. Pass -BaseUrl or set SNIPEIT_BASE_URL\.'
            $authTokenExitCode | Should -Be 1
            $authTokenOutput | Should -Match 'AuthToken was not provided\. Pass -AuthToken or set SNIPEIT_TOKEN\.'
        }
        finally {
            $env:SNIPEIT_BASE_URL = $script:testSnipeITBaseUrl
            $env:SNIPEIT_TOKEN = $script:testSnipeITToken
        }
    }

    It 'keeps CsvPath mandatory' {
        $output = & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $scriptPath 2>&1 | Out-String
        $exitCode = $LASTEXITCODE

        $exitCode | Should -Be 1
        $output | Should -Match 'missing mandatory parameter.*CsvPath'
    }
}
