# Migrate the most recent eligible end-user profile, not the local admin profile.
# Profile-aware version for ForensiT Azure/Entra migration packages.
# This version launches Profwiz with /SOURCEPROFILE and /TARGETACCOUNT so that
# the selected local profile is explicitly mapped to the correct Entra user.

$ErrorActionPreference = 'Stop'

$MachineFlagName = 'ForensiTMigrated'
$Debug = $true

function Write-DebugLog {
    param([string]$Message)
    if ($Debug) {
        Write-Host "[DEBUG] $Message"
    }
}

function Write-InfoLog {
    param([string]$Message)
    Write-Host "[INFO]  $Message"
}

function Get-ConfigXml {
    param([string]$Path)

    [xml]$xml = Get-Content -LiteralPath $Path
    $ns = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
    $ns.AddNamespace('f', 'http://www.ForensiT.com/schemas')

    [pscustomobject]@{
        Xml = $xml
        Ns  = $ns
    }
}

function Get-ConfigValue {
    param(
        [xml]$Xml,
        [System.Xml.XmlNamespaceManager]$Ns,
        [string]$NodeName
    )

    $node = $Xml.SelectSingleNode("/f:ForensiTUserProfileWizard/f:Parameters/f:$NodeName", $Ns)
    if ($null -eq $node) { return $null }
    return $node.InnerText
}

function Set-ConfigValue {
    param(
        [xml]$Xml,
        [System.Xml.XmlNamespaceManager]$Ns,
        [string]$NodeName,
        [string]$Value
    )

    $node = $Xml.SelectSingleNode("/f:ForensiTUserProfileWizard/f:Parameters/f:$NodeName", $Ns)
    if ($null -eq $node) {
        throw "Could not find <$NodeName> in Profwiz.config"
    }
    $node.InnerText = $Value
}

function Resolve-SidToAccount {
    param([string]$Sid)

    try {
        return ([System.Security.Principal.SecurityIdentifier]$Sid).Translate([System.Security.Principal.NTAccount]).Value
    }
    catch {
        return $null
    }
}

function Get-BareUserName {
    param([string]$Account)

    if ([string]::IsNullOrWhiteSpace($Account)) { return $null }
    if ($Account -match '^[^\\]+\\(.+)$') { return $matches[1] }
    return $Account
}

function Normalize-Account {
    param([string]$Account)
    if ([string]::IsNullOrWhiteSpace($Account)) { return $null }
    return $Account.Trim().ToLowerInvariant()
}

function Is-ExcludedAccount {
    param(
        [string]$Account,
        [string]$LocalPathLeaf,
        [System.Collections.Generic.HashSet[string]]$Excluded
    )

    $normalizedAccount = Normalize-Account $Account
    $bare = Normalize-Account (Get-BareUserName $Account)
    $leaf = Normalize-Account $LocalPathLeaf

    return ($normalizedAccount -and $Excluded.Contains($normalizedAccount)) -or
           ($bare -and $Excluded.Contains($bare)) -or
           ($leaf -and $Excluded.Contains($leaf))
}

function Build-ExcludedSet {
    param(
        [string]$ExcludeCsv,
        [string]$LocalAdmin,
        [string]$ComputerName
    )

    $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($entry in ($ExcludeCsv -split ',')) {
        $trimmed = $entry.Trim()
        if ($trimmed) {
            [void]$set.Add($trimmed.ToLowerInvariant())
        }
    }

    foreach ($extra in @('administrator','defaultuser0','public','default')) {
        [void]$set.Add($extra)
    }

    if ($LocalAdmin) {
        $la = $LocalAdmin.Trim()
        [void]$set.Add($la.ToLowerInvariant())

        $bare = Get-BareUserName $la
        if ($bare) {
            [void]$set.Add($bare.ToLowerInvariant())
            [void]$set.Add(("$ComputerName\\$bare").ToLowerInvariant())
            [void]$set.Add((".\\$bare").ToLowerInvariant())
        }
    }

    return $set
}

function Get-LookupMappings {
    param([string]$LookupPath)

    $map = @{}

    if ([string]::IsNullOrWhiteSpace($LookupPath) -or -not (Test-Path -LiteralPath $LookupPath)) {
        return $map
    }

    Get-Content -LiteralPath $LookupPath | ForEach-Object {
        $line = $_.Trim()
        if (-not $line) { return }

        $parts = $line.Split(',')
        if ($parts.Count -lt 2) { return }

        $oldUser = $parts[0].Trim().ToLowerInvariant()
        $newUser = $parts[1].Trim()
        if ($oldUser -and $newUser) {
            $map[$oldUser] = $newUser
        }
    }

    return $map
}

function Get-LookupUsers {
    param([hashtable]$LookupMap)

    $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($key in $LookupMap.Keys) {
        [void]$set.Add($key)
    }
    return $set
}

function Get-LastLoggedOnSamUser {
    $path = 'Registry::HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI'
    $value = (Get-ItemProperty -Path $path -ErrorAction Stop).LastLoggedOnSAMUser

    if ([string]::IsNullOrWhiteSpace($value)) {
        return $null
    }

    $parts = $value -split '\\', 2
    if ($parts.Count -eq 2 -and $parts[0] -eq '.') {
        return "$env:COMPUTERNAME\\$($parts[1])"
    }

    return $value
}

function Convert-WmiDateTime {
    param($Value)

    if (-not $Value) { return $null }

    try {
        return [System.Management.ManagementDateTimeConverter]::ToDateTime($Value)
    }
    catch {
        return $null
    }
}

function Get-EligibleProfileCandidates {
    param(
        [string]$OldDomain,
        [System.Collections.Generic.HashSet[string]]$Excluded,
        [System.Collections.Generic.HashSet[string]]$LookupUsers
    )

    $profiles = Get-CimInstance Win32_UserProfile | Where-Object {
        -not $_.Special -and $_.LocalPath -like 'C:\Users\*'
    }

    $candidates = foreach ($profile in $profiles) {
        $account = Resolve-SidToAccount -Sid $profile.SID
        $leaf = Split-Path -Path $profile.LocalPath -Leaf
        $bare = Get-BareUserName $account
        $accountDomain = if ($account -match '^([^\\]+)\\') { $matches[1] } else { $null }
        $lastUse = Convert-WmiDateTime -Value $profile.LastUseTime

        if (Is-ExcludedAccount -Account $account -LocalPathLeaf $leaf -Excluded $Excluded) {
            continue
        }

        $reasons = @()
        if ($accountDomain -and $OldDomain -and $accountDomain.Equals($OldDomain, [System.StringComparison]::OrdinalIgnoreCase)) {
            $reasons += 'old-domain-account'
        }
        if ($bare -and $LookupUsers.Contains($bare.ToLowerInvariant())) {
            $reasons += 'lookup-olduser'
        }
        if ($leaf -and $LookupUsers.Contains($leaf.ToLowerInvariant())) {
            $reasons += 'lookup-profileleaf'
        }

        if ($reasons.Count -eq 0) {
            continue
        }

        [pscustomobject]@{
            Account     = $account
            BareUser    = $bare
            LocalPath   = $profile.LocalPath
            ProfileLeaf = $leaf
            SID         = $profile.SID
            LastUseTime = $lastUse
            Reasons     = ($reasons -join ',')
        }
    }

    $candidates | Sort-Object -Property @{Expression='LastUseTime';Descending=$true}, @{Expression='ProfileLeaf';Descending=$false}
}

function Find-CandidateForRegistryUser {
    param(
        [string]$RegistryUser,
        [object[]]$Candidates
    )

    if ([string]::IsNullOrWhiteSpace($RegistryUser)) { return $null }

    $normalizedRegistry = Normalize-Account $RegistryUser
    $registryBare = Normalize-Account (Get-BareUserName $RegistryUser)

    foreach ($candidate in $Candidates) {
        $candidateAccount = Normalize-Account $candidate.Account
        $candidateBare = Normalize-Account $candidate.BareUser
        $candidateLeaf = Normalize-Account $candidate.ProfileLeaf

        if (($candidateAccount -and $candidateAccount -eq $normalizedRegistry) -or
            ($candidateBare -and $candidateBare -eq $registryBare) -or
            ($candidateLeaf -and $candidateLeaf -eq $registryBare)) {
            return $candidate
        }
    }

    return $null
}

function Resolve-TargetAccount {
    param(
        [object]$Candidate,
        [hashtable]$LookupMap
    )

    $keys = @()
    if ($Candidate.BareUser) { $keys += $Candidate.BareUser.ToLowerInvariant() }
    if ($Candidate.ProfileLeaf) { $keys += $Candidate.ProfileLeaf.ToLowerInvariant() }

    foreach ($key in ($keys | Select-Object -Unique)) {
        if ($LookupMap.ContainsKey($key)) {
            return [pscustomobject]@{
                KeyUsed = $key
                Value   = $LookupMap[$key]
            }
        }
    }

    return $null
}

function Get-AzureUpnSet {
    param([string]$AzureObjectIdPath)

    $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    if ([string]::IsNullOrWhiteSpace($AzureObjectIdPath) -or -not (Test-Path -LiteralPath $AzureObjectIdPath)) {
        return $set
    }

    [xml]$azureXml = Get-Content -LiteralPath $AzureObjectIdPath
    $userNodes = $azureXml.SelectNodes('//*[local-name()="UserPrincipalName"]')
    foreach ($node in $userNodes) {
        $value = $node.InnerText.Trim()
        if ($value) {
            [void]$set.Add($value)
        }
    }

    return $set
}

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProfwizExe = Join-Path $ScriptRoot 'Profwiz.exe'
$ConfigPath = Join-Path $ScriptRoot 'Profwiz.config'
$FlagFile   = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::ApplicationData)) $MachineFlagName

if (-not (Test-Path -LiteralPath $ProfwizExe)) {
    throw "Profwiz.exe not found at $ProfwizExe"
}
if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Profwiz.config not found at $ConfigPath"
}

if (Test-Path -LiteralPath $FlagFile) {
    if ($Debug) {
        $delete = Read-Host "The 'migrated' flag file has been set. Do you want to delete the flag file and continue? (Y/n)"
        if ($delete -eq '' -or $delete -match '^(?i)y(es)?$') {
            Remove-Item -LiteralPath $FlagFile -Force
        }
        else {
            exit 0
        }
    }
    else {
        exit 0
    }
}

$config = Get-ConfigXml -Path $ConfigPath
$xml = $config.Xml
$ns = $config.Ns

$oldDomain       = Get-ConfigValue -Xml $xml -Ns $ns -NodeName 'OldDomain'
$localAdmin      = Get-ConfigValue -Xml $xml -Ns $ns -NodeName 'LocalAdmin'
$excludeCsv      = Get-ConfigValue -Xml $xml -Ns $ns -NodeName 'Exclude'
$lookupPath      = Get-ConfigValue -Xml $xml -Ns $ns -NodeName 'UserLookupFile'
$azureObjectFile = Get-ConfigValue -Xml $xml -Ns $ns -NodeName 'AzureObjectIDFile'

if ($azureObjectFile -and -not [System.IO.Path]::IsPathRooted($azureObjectFile)) {
    $azureObjectFile = Join-Path $ScriptRoot $azureObjectFile
}

$excluded   = Build-ExcludedSet -ExcludeCsv $excludeCsv -LocalAdmin $localAdmin -ComputerName $env:COMPUTERNAME
$lookupMap  = Get-LookupMappings -LookupPath $lookupPath
$lookupUsers = Get-LookupUsers -LookupMap $lookupMap
$azureUpns  = Get-AzureUpnSet -AzureObjectIdPath $azureObjectFile

Write-DebugLog "OldDomain: $oldDomain"
Write-DebugLog "LocalAdmin: $localAdmin"
Write-DebugLog "LookupPath: $lookupPath"
Write-DebugLog "AzureObjectIDFile: $azureObjectFile"

$lastLoggedOnSamUser = Get-LastLoggedOnSamUser
Write-DebugLog "Registry LastLoggedOnSAMUser: $lastLoggedOnSamUser"

$candidates = @(Get-EligibleProfileCandidates -OldDomain $oldDomain -Excluded $excluded -LookupUsers $lookupUsers)
if ($candidates.Count -eq 0) {
    throw 'No eligible source-domain user profile was found after excluding the local admin account.'
}

Write-DebugLog "Eligible candidates found: $($candidates.Count)"
$index = 0
foreach ($candidate in $candidates | Select-Object -First 5) {
    $index++
    Write-DebugLog ("Candidate #{0}: Account={1}; ProfileLeaf={2}; Path={3}; LastUse={4}; Reasons={5}" -f `
        $index,
        $(if ($candidate.Account) { $candidate.Account } else { '<unresolved>' }),
        $candidate.ProfileLeaf,
        $candidate.LocalPath,
        $(if ($candidate.LastUseTime) { $candidate.LastUseTime.ToString('s') } else { '<none>' }),
        $candidate.Reasons)
}

$selectedCandidate = $null
$selectionReason = $null

if (-not (Is-ExcludedAccount -Account $lastLoggedOnSamUser -LocalPathLeaf $null -Excluded $excluded)) {
    $selectedCandidate = Find-CandidateForRegistryUser -RegistryUser $lastLoggedOnSamUser -Candidates $candidates
    if ($selectedCandidate) {
        $selectionReason = 'registry-last-logged-on-user'
    }
}

if (-not $selectedCandidate) {
    $selectedCandidate = $candidates | Select-Object -First 1
    $selectionReason = 'most-recent-eligible-profile'
}

if (-not $selectedCandidate.ProfileLeaf) {
    throw 'Selected candidate does not have a usable profile folder name.'
}

if (-not (Test-Path -LiteralPath $selectedCandidate.LocalPath)) {
    throw "Selected profile path does not exist: $($selectedCandidate.LocalPath)"
}

$target = Resolve-TargetAccount -Candidate $selectedCandidate -LookupMap $lookupMap
if (-not $target) {
    throw "Could not determine TARGETACCOUNT from userlookup.csv for profile '$($selectedCandidate.ProfileLeaf)'."
}

$targetAccount = $target.Value
$canonicalTargetAccount = $null
if ($azureUpns.Count -gt 0) {
    foreach ($upn in $azureUpns) {
        if ($upn -and $upn.ToLowerInvariant() -eq $targetAccount.ToLowerInvariant()) {
            $canonicalTargetAccount = $upn
            break
        }
    }

    if ($canonicalTargetAccount) {
        if ($canonicalTargetAccount -ne $targetAccount) {
            Write-DebugLog "AzureObjectIDFile canonical UPN match found: $canonicalTargetAccount"
        }
        $targetAccount = $canonicalTargetAccount
    } else {
        throw "TARGETACCOUNT '$targetAccount' was not found in ForensiTAzureID.xml."
    }
}

$selectedProfileLeaf = $selectedCandidate.ProfileLeaf
$selectedProfilePath = $selectedCandidate.LocalPath
$selectedAccount = if ($selectedCandidate.Account) { $selectedCandidate.Account } else { '<unresolved>' }
$selectedBare = if ($selectedCandidate.BareUser) { $selectedCandidate.BareUser } else { '<unresolved>' }
$lastUseText = if ($selectedCandidate.LastUseTime) { $selectedCandidate.LastUseTime.ToString('yyyy-MM-dd HH:mm:ss') } else { '<none>' }

Write-Host ''
Write-InfoLog 'Selected source profile for migration:'
Write-InfoLog "  Reason         : $selectionReason"
Write-InfoLog "  Account        : $selectedAccount"
Write-InfoLog "  Bare user      : $selectedBare"
Write-InfoLog "  Profile folder : $selectedProfilePath"
Write-InfoLog "  Profile leaf   : $selectedProfileLeaf"
Write-InfoLog "  Last use time  : $lastUseText"
Write-InfoLog "  SID            : $($selectedCandidate.SID)"
Write-InfoLog "  Match reasons  : $($selectedCandidate.Reasons)"
Write-InfoLog "  Target account : $targetAccount"
Write-InfoLog "  Lookup key     : $($target.KeyUsed)"

if ($selectedCandidate.BareUser -and ($selectedCandidate.BareUser -ne $selectedCandidate.ProfileLeaf)) {
    Write-InfoLog '  Note           : Account name and profile folder differ. Forcing /SOURCEPROFILE.'
}

$originalAll = Get-ConfigValue -Xml $xml -Ns $ns -NodeName 'All'
Set-ConfigValue -Xml $xml -Ns $ns -NodeName 'All' -Value 'False'
$xml.Save($ConfigPath)

$normalizedBare = if ($selectedCandidate.BareUser) {
    $selectedCandidate.BareUser.Trim().ToLowerInvariant()
} else {
    $null
}

$normalizedLeaf = if ($selectedProfileLeaf) {
    $selectedProfileLeaf.Trim().ToLowerInvariant()
} else {
    $null
}

$useSourceAccount = $false

# Use SOURCEACCOUNT only when the source account resolves cleanly
# AND the account name matches the actual local profile folder.
# Otherwise fall back to SOURCEPROFILE.
if ($selectedCandidate.Account `
    -and $normalizedBare `
    -and $normalizedLeaf `
    -and $normalizedBare -eq $normalizedLeaf) {
    $useSourceAccount = $true
}

if ($useSourceAccount) {
    Write-InfoLog '  Source mode    : SOURCEACCOUNT'
}
else {
    Write-InfoLog '  Source mode    : SOURCEPROFILE'

    if ($selectedCandidate.Account -and $normalizedBare -and $normalizedLeaf -and $normalizedBare -ne $normalizedLeaf) {
        Write-InfoLog '  Note           : Account name and profile folder differ. Falling back to /SOURCEPROFILE.'
    }
    elseif (-not $selectedCandidate.Account) {
        Write-InfoLog '  Note           : Source account could not be resolved. Falling back to /SOURCEPROFILE.'
    }
}

$originalAll = Get-ConfigValue -Xml $xml -Ns $ns -NodeName 'All'
Set-ConfigValue -Xml $xml -Ns $ns -NodeName 'All' -Value 'False'
$xml.Save($ConfigPath)

$argumentList = @('/TARGETACCOUNT', $targetAccount)

if ($useSourceAccount) {
    $argumentList += @('/SOURCEACCOUNT', $selectedCandidate.Account)
    $argumentString = '/TARGETACCOUNT "' + $targetAccount + '" /SOURCEACCOUNT "' + $selectedCandidate.Account + '"'
}
else {
    $argumentList += @('/SOURCEPROFILE', $selectedProfileLeaf)
    $argumentString = '/TARGETACCOUNT "' + $targetAccount + '" /SOURCEPROFILE "' + $selectedProfileLeaf + '"'
}

Write-Host ''
Write-InfoLog "Starting Profwiz.exe with: $argumentString"
Write-Host ''

try {
    $profwiz = Start-Process -FilePath $ProfwizExe -ArgumentList $argumentList -Wait -PassThru -NoNewWindow
    $exitCode = $profwiz.ExitCode

    if ($exitCode -eq 0) {
        Write-InfoLog 'Profwiz completed successfully.'
        New-Item -Path $FlagFile -ItemType File -Force | Out-Null
    }
    else {
        Write-Warning "Profwiz exited with status code $exitCode"
    }

    exit $exitCode
}
finally {
    try {
        Set-ConfigValue -Xml $xml -Ns $ns -NodeName 'All' -Value $originalAll
        $xml.Save($ConfigPath)
    }
    catch {
        Write-Warning "Could not restore original <All> value in Profwiz.config: $($_.Exception.Message)"
    }
}
