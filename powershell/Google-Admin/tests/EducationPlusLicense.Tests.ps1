$googleAdminRoot = Split-Path -Parent $PSScriptRoot
$entryPoint = Join-Path $googleAdminRoot 'Remove-EducationPlusLicense-InactiveOU.ps1'
$orchestratorModule = New-Module -Name EducationPlusOrchestrator -ScriptBlock {
    param($Path, $Root)

    $script:googleAdminRoot = $Root
    . $Path
    Export-ModuleMember -Function @(
        'Invoke-EducationPlusLicenseRemoval',
        'Get-SafeEduPlusErrorMessage'
    )
} -ArgumentList $entryPoint, $googleAdminRoot
Import-Module -ModuleInfo $orchestratorModule -Force

Describe 'Education Plus license tool' {
InModuleScope EducationPlusOrchestrator {
BeforeAll {
    $script:secretSentinel = 'CLIENT_SECRET_SENTINEL_9f77a2'
    $script:credentialsPath = Join-Path $TestDrive 'client-secrets.json'
    @{
        installed = @{
            client_id = 'test-client-id'
            client_secret = $script:secretSentinel
            token_uri = 'https://oauth2.googleapis.com/token'
        }
    } | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $script:credentialsPath -Encoding utf8NoBOM

}

    BeforeEach {
        Mock -CommandName Get-GApiDirectoryUsersByOU -MockWith { @() }
        Mock -CommandName Get-GApiUserLicenseSkus -MockWith { @() }
        Mock -CommandName Remove-GApiLicenseAssignment -MockWith { }
        Mock -CommandName Read-Host -MockWith { 'YES' }
    }

Describe 'ConvertFrom-EduPlusCsv' {
    It 'returns valid emails, deduplicates them case-insensitively, and warns for malformed or missing rows' {
        $csvPath = Join-Path $TestDrive 'mixed-users.csv'
        @'
Email,DisplayName
alice@example.com,Alice
ALICE@example.com,Alice Duplicate
not-an-email,Bad
,Missing
bob@example.com,Bob
'@ | Set-Content -LiteralPath $csvPath -Encoding utf8NoBOM

        $warnings = @()
        $emails = @(ConvertFrom-EduPlusCsv -CsvPath $csvPath -WarningVariable warnings)

        $emails | Should -HaveCount 2
        $emails[0] | Should -Be 'alice@example.com'
        $emails[1] | Should -Be 'bob@example.com'
        $warnings | Should -HaveCount 2
        ($warnings -join ' ') | Should -Match 'not a valid email address'
        ($warnings -join ' ') | Should -Match 'email value is missing'
    }

    It 'returns zero targets with a clear warning for an empty CSV' {
        $csvPath = Join-Path $TestDrive 'empty.csv'
        Set-Content -LiteralPath $csvPath -Value '' -Encoding utf8NoBOM

        $warnings = @()
        $emails = @(ConvertFrom-EduPlusCsv -CsvPath $csvPath -WarningVariable warnings)

        $emails | Should -HaveCount 0
        ($warnings -join ' ') | Should -Match 'zero targets'
    }
}

Describe 'Education Plus license orchestration' {
    It 'checks assigned SKUs in dry-run mode and never invokes removal' {
        $csvPath = Join-Path $TestDrive 'dry-run-users.csv'
        "Email`nalice@example.com`nbob@example.com" | Set-Content -LiteralPath $csvPath -Encoding utf8NoBOM
        $reportPath = Join-Path $TestDrive 'dry-run-report'
        Mock -CommandName Get-GApiUserLicenseSkus -MockWith {
            param($Email, $Credential)
            if ($Email -eq 'alice@example.com') {
                return @('Google-Apps-For-Education-Plus')
            }
            return @()
        }

        $exitCode = Invoke-EducationPlusLicenseRemoval -CsvPath $csvPath -CredentialsPath $script:credentialsPath -ReportPath $reportPath

        $exitCode | Should -Be 0
        Should -Invoke -CommandName Get-GApiUserLicenseSkus -Times 2 -Exactly
        Should -Invoke -CommandName Remove-GApiLicenseAssignment -Times 0 -Exactly
        $rows = @(Import-Csv -LiteralPath (Get-ChildItem -LiteralPath $reportPath -File -Filter '*.csv').FullName)
        ($rows | Where-Object Email -eq 'alice@example.com').Status | Should -Be 'dry-run-remove'
        ($rows | Where-Object Email -eq 'bob@example.com').Status | Should -Be 'already-clean'
    }

    It 'exits 2 and performs no removal when apply confirmation is not YES' {
        $csvPath = Join-Path $TestDrive 'declined-users.csv'
        "Email`nalice@example.com" | Set-Content -LiteralPath $csvPath -Encoding utf8NoBOM
        Mock -CommandName Get-GApiUserLicenseSkus -MockWith { @('Google-Apps-For-Education-Plus') }
        Mock -CommandName Read-Host -MockWith { 'no' }

        $exitCode = Invoke-EducationPlusLicenseRemoval -CsvPath $csvPath -CredentialsPath $script:credentialsPath `
            -ReportPath (Join-Path $TestDrive 'declined-report') -Apply

        $exitCode | Should -Be 2
        Should -Invoke -CommandName Read-Host -Times 1 -Exactly
        Should -Invoke -CommandName Remove-GApiLicenseAssignment -Times 0 -Exactly
    }

    It 'uses the requested OU and processes the returned email addresses' {
        $ouPath = 'NOMMA.net/zMisc/Inactive'
        $reportPath = Join-Path $TestDrive 'ou-report'
        Mock -CommandName Get-GApiDirectoryUsersByOU -MockWith {
            @(
                [pscustomobject]@{ Email = 'one@example.com' }
                [pscustomobject]@{ Email = 'two@example.com' }
            )
        }

        $exitCode = Invoke-EducationPlusLicenseRemoval -OuTarget -OuPath $ouPath `
            -CredentialsPath $script:credentialsPath -ReportPath $reportPath

        $exitCode | Should -Be 0
        Should -Invoke -CommandName Get-GApiDirectoryUsersByOU -Times 1 -Exactly -ParameterFilter {
            $OuPath -eq 'NOMMA.net/zMisc/Inactive'
        }
        Should -Invoke -CommandName Get-GApiUserLicenseSkus -Times 1 -Exactly -ParameterFilter {
            $Email -eq 'one@example.com'
        }
        Should -Invoke -CommandName Get-GApiUserLicenseSkus -Times 1 -Exactly -ParameterFilter {
            $Email -eq 'two@example.com'
        }
        Should -Invoke -CommandName Remove-GApiLicenseAssignment -Times 0 -Exactly
    }

    It 'removes only the Education Plus SKU and leaves another assigned SKU untouched' {
        $csvPath = Join-Path $TestDrive 'multiple-skus.csv'
        "Email`nalice@example.com" | Set-Content -LiteralPath $csvPath -Encoding utf8NoBOM
        $reportPath = Join-Path $TestDrive 'multiple-skus-report'
        Mock -CommandName Get-GApiUserLicenseSkus -MockWith {
            @('Google-Apps-For-Education-Plus', 'Google-Workspace-Other-Sku')
        }

        $exitCode = Invoke-EducationPlusLicenseRemoval -CsvPath $csvPath -CredentialsPath $script:credentialsPath `
            -ReportPath $reportPath -Apply

        $exitCode | Should -Be 0
        Should -Invoke -CommandName Remove-GApiLicenseAssignment -Times 1 -Exactly -ParameterFilter {
            $Email -eq 'alice@example.com' -and $SkuId -eq 'Google-Apps-For-Education-Plus'
        }
        Should -Invoke -CommandName Remove-GApiLicenseAssignment -Times 0 -Exactly -ParameterFilter {
            $SkuId -eq 'Google-Workspace-Other-Sku'
        }
    }

    It 'reports an already-clean user with false before and after values and makes no removal' {
        $csvPath = Join-Path $TestDrive 'clean-user.csv'
        "Email`nclean@example.com" | Set-Content -LiteralPath $csvPath -Encoding utf8NoBOM
        $reportPath = Join-Path $TestDrive 'clean-report'
        Mock -CommandName Get-GApiUserLicenseSkus -MockWith { @('Google-Workspace-Other-Sku') }

        $exitCode = Invoke-EducationPlusLicenseRemoval -CsvPath $csvPath -CredentialsPath $script:credentialsPath `
            -ReportPath $reportPath -Apply

        $exitCode | Should -Be 0
        Should -Invoke -CommandName Remove-GApiLicenseAssignment -Times 0 -Exactly
        $row = Import-Csv -LiteralPath (Get-ChildItem -LiteralPath $reportPath -File -Filter '*.csv').FullName
        $row.Status | Should -Be 'already-clean'
        $row.EduPlusBefore | Should -Be 'False'
        $row.EduPlusAfter | Should -Be 'False'
    }

    It 'continues after one user lookup fails and returns a nonzero exit code' {
        $csvPath = Join-Path $TestDrive 'partial-failure.csv'
        "Email`ngood1@example.com`nbad@example.com`ngood2@example.com" | Set-Content -LiteralPath $csvPath -Encoding utf8NoBOM
        $reportPath = Join-Path $TestDrive 'partial-failure-report'
        Mock -CommandName Get-GApiUserLicenseSkus -MockWith {
            param($Email, $Credential)
            if ($Email -eq 'bad@example.com') {
                throw 'simulated per-user failure'
            }
            return @()
        }

        $exitCode = Invoke-EducationPlusLicenseRemoval -CsvPath $csvPath -CredentialsPath $script:credentialsPath -ReportPath $reportPath

        $exitCode | Should -Be 1
        Should -Invoke -CommandName Get-GApiUserLicenseSkus -Times 3 -Exactly
        $rows = @(Import-Csv -LiteralPath (Get-ChildItem -LiteralPath $reportPath -File -Filter '*.csv').FullName)
        $rows | Should -HaveCount 3
        ($rows | Where-Object Email -eq 'bad@example.com').Status | Should -Be 'error'
        @($rows | Where-Object Email -ne 'bad@example.com').Status | Should -Not -Contain 'error'
    }

    It 'never includes the client secret or a token sentinel in output or report content' {
        $csvPath = Join-Path $TestDrive 'secret-check.csv'
        "Email`nclean@example.com" | Set-Content -LiteralPath $csvPath -Encoding utf8NoBOM
        $reportPath = Join-Path $TestDrive 'secret-report'
        $tokenSentinel = 'ACCESS_TOKEN_SENTINEL_a421c8'
        Mock -CommandName Get-GApiUserLicenseSkus -MockWith {
            throw "access_token=$tokenSentinel client_secret=$script:secretSentinel"
        }

        $capturedOutput = & {
            Invoke-EducationPlusLicenseRemoval -CsvPath $csvPath -CredentialsPath $script:credentialsPath -ReportPath $reportPath
        } *>&1 | Out-String
        $reportContent = Get-Content -LiteralPath (Get-ChildItem -LiteralPath $reportPath -File -Filter '*.csv').FullName -Raw

        $capturedOutput | Should -Not -Match ([regex]::Escape($script:secretSentinel))
        $capturedOutput | Should -Not -Match ([regex]::Escape($tokenSentinel))
        $reportContent | Should -Not -Match ([regex]::Escape($script:secretSentinel))
        $reportContent | Should -Not -Match ([regex]::Escape($tokenSentinel))
    }
}

Describe 'Report row formatting' {
    It 'includes every required per-user field plus mode and timestamp' {
        $result = New-EduPlusResult -Email 'alice@example.com' -Status 'removed' `
            -EduPlusBefore $true -EduPlusAfter $false -Error ''
        $timestamp = [datetime]'2026-08-11T12:34:56Z'

        $row = Format-EduPlusReportRows -Results @($result) -Mode apply -Timestamp $timestamp

        $row.Email | Should -Be 'alice@example.com'
        $row.Status | Should -Be 'removed'
        $row.EduPlusBefore | Should -BeTrue
        $row.EduPlusAfter | Should -BeFalse
        $row.Error | Should -Be ''
        $row.Mode | Should -Be 'apply'
        $row.Timestamp | Should -Be '2026-08-11T12:34:56.0000000Z'
    }
}
}
}
