<#
.SYNOPSIS
    Bulk-creates Entra ID user accounts for cadets from a CSV file.

.DESCRIPTION
    Reads a CSV with FirstName and LastName columns, creates corresponding user
    accounts in Entra ID with UPN format cadet<firstInitial><lastname>@nomma.net,
    generates secure random passwords, and adds each user to a specified Entra ID
    security group. No emails are sent — results are exported to a CSV for external
    email distribution.

    Duplicate UPNs are handled automatically by appending a numeric suffix
    (e.g. cadetjdoe2@nomma.net, cadetjdoe3@nomma.net) until a unique name is found.

.PARAMETER CsvPath
    Path to the input CSV file. Must contain at least two columns: FirstName, LastName.
    Default: ./cadets.csv

.PARAMETER OutputPath
    Path for the results CSV. Default: ./cadet-accounts.csv

.PARAMETER GroupId
    Object ID of the Entra ID group to add each new user to.
    Default: 1572586f-9d8b-4447-bb5d-83edd3e78599

.PARAMETER UsageLocation
    Two-letter ISO 3166-1 country code for the user's UsageLocation.
    Default: US

.PARAMETER Domain
    Domain portion of the UserPrincipalName. Default: nomma.net

.PARAMETER WhatIf
    Shows what would happen without actually creating any users.

.EXAMPLE
    .\New-CadetAccounts.ps1 -CsvPath .\cadets.csv -OutputPath .\accounts.csv

    Processes cadets.csv, creates users, and writes results to accounts.csv.

.EXAMPLE
    .\New-CadetAccounts.ps1 -CsvPath .\cadets.csv -WhatIf

    Dry-run showing what would be created without making any changes.

.EXAMPLE
    .\New-CadetAccounts.ps1 -CsvPath .\cadets.csv -Verbose

    Full verbose output for debugging or audit.

.NOTES
    Version:  1.0
    Author:   NOMMA IT
    Requires: PowerShell 7+, Microsoft.Graph module
    Scopes:   User.ReadWrite.All, GroupMember.ReadWrite.All
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param (
    [Parameter(Mandatory = $false, Position = 0)]
    [ValidateScript({
        if (-not (Test-Path $_ -PathType Leaf)) {
            throw "CSV file '$_' not found."
        }
        $true
    })]
    [string]$CsvPath = './cadets.csv',

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = './cadet-accounts.csv',

    [Parameter(Mandatory = $false)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$GroupId = '1572586f-9d8b-4447-bb5d-83edd3e78599',

    [Parameter(Mandatory = $false)]
    [ValidatePattern('^[A-Z]{2}$')]
    [string]$UsageLocation = 'US',

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$Domain = 'nomma.net'
)

begin {
    # ── Module & scope checks ──────────────────────────────────────────────
    $requiredModules = @('Microsoft.Graph.Users', 'Microsoft.Graph.Groups', 'Microsoft.Graph.Identity.SignIns')

    Write-Host '🔍 Checking required modules...' -ForegroundColor Cyan
    $missingModules = @()
    foreach ($module in $requiredModules) {
        if (-not (Get-Module -ListAvailable -Name $module)) {
            $missingModules += $module
        }
    }

    if ($missingModules.Count -gt 0) {
        Write-Warning "Missing required Microsoft.Graph sub-modules: $($missingModules -join ', ')"
        Write-Host 'Attempting auto-install...' -ForegroundColor Yellow
        foreach ($module in $missingModules) {
            try {
                Install-Module -Name $module -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
                Write-Host "  ✅ Installed $module" -ForegroundColor Green
            }
            catch {
                Write-Error "Failed to install $module : $($_.Exception.Message)"
                Write-Host "Install manually: Install-Module $module -Scope CurrentUser -Force" -ForegroundColor Red
                exit 1
            }
        }
    }

    # Import modules so cmdlets are available
    Write-Verbose 'Importing Microsoft.Graph modules...'
    foreach ($module in $requiredModules) {
        Import-Module $module -Force -ErrorAction Stop | Out-Null
    }

    # Check for Graph connection
    try {
        $context = Get-MgContext -ErrorAction SilentlyContinue
        if (-not $context) {
            Write-Host '🔌 Connecting to Microsoft Graph...' -ForegroundColor Cyan
            Connect-MgGraph -Scopes 'User.ReadWrite.All', 'GroupMember.ReadWrite.All' -ErrorAction Stop
        }
        else {
            Write-Host "✅ Already connected to Graph as $($context.Account)" -ForegroundColor Green
            # Verify required scopes are present
            $scopes = $context.Scopes
            $requiredScopes = @('User.ReadWrite.All', 'GroupMember.ReadWrite.All')
            $missingScopes = $requiredScopes | Where-Object { $_ -notin $scopes }
            if ($missingScopes.Count -gt 0) {
                Write-Warning "Missing required scope(s): $($missingScopes -join ', ')"
                Write-Host 'Reconnecting with full scopes...' -ForegroundColor Yellow
                Connect-MgGraph -Scopes $requiredScopes -Force -ErrorAction Stop
            }
        }
    }
    catch {
        Write-Error "Failed to connect to Microsoft Graph: $($_.Exception.Message)"
        exit 1
    }

    # ── Password character set (avoiding ambiguous chars) ──────────────────
    # No l, I, 1, O, 0
    $upperChars  = 'ABCDEFGHJKMNPQRSTUVWXYZ'.ToCharArray()   # no I, O
    $lowerChars  = 'abcdefghjkmnpqrstuvwxyz'.ToCharArray()    # no l, o
    $digitChars  = '23456789'.ToCharArray()                   # no 0, 1
    $specialChars = '!@#$%&*+-=?'.ToCharArray()

    $allCharSets = @($upperChars, $lowerChars, $digitChars, $specialChars)

    # ── Results accumulator ────────────────────────────────────────────────
    $results = [System.Collections.Generic.List[pscustomobject]]::new()

    # ── Load CSV ───────────────────────────────────────────────────────────
    Write-Host "📂 Loading CSV from: $CsvPath" -ForegroundColor Cyan
    try {
        $cadets = Import-Csv -Path $CsvPath -ErrorAction Stop
        Write-Host "   Loaded $($cadets.Count) cadet record(s)." -ForegroundColor Green
    }
    catch {
        Write-Error "Failed to read CSV '$CsvPath': $($_.Exception.Message)"
        exit 1
    }

    # Validate required columns
    $csvColumns = $cadets[0].PSObject.Properties.Name
    if ('FirstName' -notin $csvColumns -or 'LastName' -notin $csvColumns) {
        Write-Error "CSV must contain 'FirstName' and 'LastName' columns. Found: $($csvColumns -join ', ')"
        exit 1
    }

    Write-Host "🔍 Checking group $GroupId exists..." -ForegroundColor Cyan
    try {
        $null = Get-MgGroup -GroupId $GroupId -ErrorAction Stop
        Write-Host "   ✅ Group verified." -ForegroundColor Green
    }
    catch {
        Write-Error "Group with ID '$GroupId' not found or inaccessible: $($_.Exception.Message)"
        Write-Warning 'You can still create users without group membership. Results will show group-add failures.'
    }

    Write-Host "`n🚀 Starting cadet account creation for $($cadets.Count) user(s)...`n" -ForegroundColor Cyan

    if ($WhatIfPreference) {
        Write-Host '⚠️  WHATIF mode — no changes will be made.' -ForegroundColor Yellow
    }
}

process {
    $total   = $cadets.Count
    $current = 0
    $successCount = 0
    $failCount    = 0
    $groupFailures = 0

    foreach ($cadet in $cadets) {
        $current++
        $firstName = $cadet.FirstName.Trim()
        $lastName  = $cadet.LastName.Trim()

        Write-Progress -Activity 'Creating Cadet Accounts' `
                       -Status "$current of $total : $firstName $lastName" `
                       -PercentComplete (($current / $total) * 100)

        # ── Build base UPN ──────────────────────────────────────────────────
        $firstInitial = $firstName.Substring(0, 1).ToLower()
        $lastNameClean = $lastName -replace '[^a-zA-Z-]', ''   # strip non-alpha
        $baseUpn  = "cadet$firstInitial$($lastNameClean.ToLower())"
        $upn      = "$baseUpn@$Domain"
        $suffix   = 0

        # ── Duplicate check ─────────────────────────────────────────────────
        Write-Verbose "Checking UPN: $upn"
        do {
            $existingUser = Get-MgUser -Filter "userPrincipalName eq '$upn'" -ErrorAction SilentlyContinue
            if ($existingUser) {
                $suffix++
                $upn = "$baseUpn$suffix@$Domain"
                Write-Verbose "   UPN taken, trying: $upn"
            }
        } while ($existingUser)

        if ($suffix -gt 0) {
            Write-Host "   ⚠️  Duplicate resolved: final UPN is $upn" -ForegroundColor Yellow
        }

        $displayName = "$firstName $lastName"

        # ── Generate password ───────────────────────────────────────────────
        # Ensure at least one char from each category, then fill to 12-16 chars
        $passwordLength = Get-Random -Minimum 12 -Maximum 17
        $password = [System.Text.StringBuilder]::new()

        # Guarantee one from each category
        foreach ($charSet in $allCharSets) {
            $null = $password.Append($charSet[(Get-Random -Maximum $charSet.Length)])
        }

        # Fill remaining length
        for ($i = $password.Length; $i -lt $passwordLength; $i++) {
            $set = $allCharSets[(Get-Random -Maximum $allCharSets.Length)]
            $null = $password.Append($set[(Get-Random -Maximum $set.Length)])
        }

        # Shuffle the password characters
        $passwordArray = $password.ToString().ToCharArray()
        for ($i = $passwordArray.Length - 1; $i -gt 0; $i--) {
            $j = Get-Random -Maximum ($i + 1)
            $tmp = $passwordArray[$i]
            $passwordArray[$i] = $passwordArray[$j]
            $passwordArray[$j] = $tmp
        }
        $plainPassword = -join $passwordArray

        # ── Create user ─────────────────────────────────────────────────────
        $userParams = @{
            UserPrincipalName     = $upn
            DisplayName           = $displayName
            GivenName             = $firstName
            Surname               = $lastName
            UsageLocation         = $UsageLocation
            AccountEnabled        = $true
            PasswordProfile       = @{
                ForceChangePasswordNextSignIn = $true
                Password                      = $plainPassword
            }
            MailNickname          = $baseUpn.Replace('cadet', '')   # avoid cadetcadet repetition
            ErrorAction           = 'Stop'
        }

        $userCreated = $false
        $createError = $null

        try {
            if ($PSCmdlet.ShouldProcess($upn, "Create user $displayName")) {
                Write-Host "   👤 Creating: $displayName ($upn)" -ForegroundColor Magenta
                $newUser = New-MgUser @userParams
                Write-Host "      ✅ Created successfully." -ForegroundColor Green
                $userCreated = $true
                $successCount++
            }
            else {
                Write-Host "   🚫 WhatIf: Would create user $displayName ($upn)" -ForegroundColor DarkYellow
                $results.Add([pscustomobject]@{
                    FirstName = $firstName
                    LastName  = $lastName
                    Email     = $upn
                    Password  = $plainPassword
                    Status    = 'WhatIf (would be created)'
                })
                continue
            }
        }
        catch {
            $createError = $_.Exception.Message
            $failCount++
            Write-Host "      ❌ FAILED: $createError" -ForegroundColor Red

            $results.Add([pscustomobject]@{
                FirstName = $firstName
                LastName  = $lastName
                Email     = $upn
                Password  = ''
                Status    = "FAILED - $createError"
            })
            continue
        }

        # ── Set initial password via auth method (for clean audit trail) ────
        # Note: The PasswordProfile on creation already sets the password, but
        # New-MgUserAuthenticationMethod provides a more robust reset pathway.
        # We do both for reliability.
        if ($userCreated -and -not $WhatIfPreference) {
            try {
                $authMethodParams = @{
                    UserId = $newUser.Id
                    BodyParameter = @{
                        '@odata.type' = '#microsoft.graph.passwordAuthenticationMethod'
                        DisplayName   = 'Initial Password'
                        Password      = $plainPassword
                    }
                    ErrorAction = 'Stop'
                }
                Write-Verbose "      Setting password authentication method..."
                $null = New-MgUserAuthenticationMethod @authMethodParams
                Write-Verbose "      ✅ Password method registered."
            }
            catch {
                Write-Warning "      ⚠️  Auth method registration failed (password still set via creation): $($_.Exception.Message)"
            }
        }

        # ── Add to group ────────────────────────────────────────────────────
        if ($userCreated -and -not $WhatIfPreference) {
            try {
                $groupParams = @{
                    DirectoryObjectId = $newUser.Id
                    GroupId           = $GroupId
                    ErrorAction       = 'Stop'
                }
                Write-Host "      🔗 Adding to group..." -ForegroundColor Magenta
                $null = New-MgGroupMember @groupParams
                Write-Host "      ✅ Added to group." -ForegroundColor Green
            }
            catch {
                $groupFailures++
                Write-Host "      ⚠️  Group add failed: $($_.Exception.Message)" -ForegroundColor Yellow
                $status = "Created (group add failed: $($_.Exception.Message))"
                $results.Add([pscustomobject]@{
                    FirstName = $firstName
                    LastName  = $lastName
                    Email     = $upn
                    Password  = $plainPassword
                    Status    = $status
                })
                continue
            }
        }

        # ── Record success ──────────────────────────────────────────────────
        if ($userCreated -and -not $WhatIfPreference) {
            $results.Add([pscustomobject]@{
                FirstName = $firstName
                LastName  = $lastName
                Email     = $upn
                Password  = $plainPassword
                Status    = 'Success'
            })
        }
    }

    Write-Progress -Activity 'Creating Cadet Accounts' -Completed
}

end {
    # ── Export results ─────────────────────────────────────────────────────
    $resolvedPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)

    if ($results.Count -gt 0) {
        try {
            $results | Export-Csv -Path $resolvedPath -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
            Write-Host "`n📄 Results exported to: $resolvedPath" -ForegroundColor Cyan
        }
        catch {
            Write-Error "Failed to write results CSV: $($_.Exception.Message)"
        }
    }

    # ── Summary ────────────────────────────────────────────────────────────
    Write-Host "`n═══════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  📊 SUMMARY" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════" -ForegroundColor Cyan

    if ($WhatIfPreference) {
        Write-Host "  Mode:        WHATIF (no changes made)" -ForegroundColor Yellow
        Write-Host "  Would create: $($results.Count) user(s)" -ForegroundColor Yellow
    }
    else {
        Write-Host "  ✅ Created successfully:    $successCount" -ForegroundColor Green
        if ($groupFailures -gt 0) {
            Write-Host "  ⚠️  Group add failures:      $groupFailures" -ForegroundColor Yellow
        }
        if ($failCount -gt 0) {
            Write-Host "  ❌ Failed:                  $failCount" -ForegroundColor Red
        }
        Write-Host "  📄 Results file:            $resolvedPath" -ForegroundColor Cyan
    }

    Write-Host "═══════════════════════════════════════════════`n" -ForegroundColor Cyan

    if (-not $WhatIfPreference -and $failCount -gt 0) {
        Write-Host '⚠️  Some accounts failed. Check the results CSV for details and re-run for failures.' -ForegroundColor Yellow
    }

    if (-not $WhatIfPreference) {
        Write-Host '📬 No emails were sent. Use the results CSV to distribute credentials to cadets.' -ForegroundColor Cyan
    }
}