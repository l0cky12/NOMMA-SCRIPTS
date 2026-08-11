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
