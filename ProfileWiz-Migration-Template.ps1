#Requires -RunAsAdministrator
<#
.SYNOPSIS
    ProfileWiz Domain-to-Azure AD Migration Script (Client-Agnostic Template)
    Designed to run as SYSTEM from ConnectWise Automate (or any RMM).

.DESCRIPTION
    Pulls all required ProfileWiz files from either a GitHub repo or a UNC file
    share, verifies them, and executes a full silent profile migration from an
    on-prem AD domain to Entra ID. Machine reboots automatically on success.

    ┌─────────────────────────────────────────────────────────────────────────┐
    │  ENGINEER SETUP - Fill in the CLIENT CONFIGURATION block below before   │
    │  deploying. Everything else is generic and should not need changes.      │
    └─────────────────────────────────────────────────────────────────────────┘

    Source type selection:
        Set $SourceType to "GitHub" or "FileShare", then set $SourcePath:
            GitHub    →  "OrgName/repo-name"
            FileShare →  "\\server\share\folder"

        Use GitHub for remote/VPN-unreliable clients.
        Use FileShare for on-site or reliably LAN-connected machines.

    Files that are STATIC across all migrations (must exist at the source):
        Profwiz.exe
        Profwiz.config

    Files that are CLIENT-SPECIFIC (set the filenames in the config block):
        <client>.ppkg
        <client>-ForensiTAzureID.xml
        <client>-UserLookup.csv

    Pre-flight checks:
        - Verifies at least one user in the lookup CSV has a local profile on
          this machine. Aborts with exit 1 if zero matches found.
        - Profiles not in the lookup are skipped silently by ProfileWiz.

    Local account detection:
        - Any non-domain profile is flagged with !! in the log.
        - Filter RMM job results for "LOCAL ACCOUNT" to build your manual
          follow-up list.

.NOTES
    Run context : SYSTEM (via RMM)
    Working dir : C:\workspace
    Log file    : C:\workspace\Migration.log
    Template ver: 1.0
#>

[CmdletBinding()]
param(
    [switch]$NoReboot
)

# ===========================================================================
# CLIENT CONFIGURATION — Fill these in before deploying
# ===========================================================================

# --- Source type ---
# "GitHub"    → pulls files from a public/private GitHub repo via raw URL
#               Use for remote users or VPN-unreliable environments
# "FileShare" → copies files from a UNC path
#               Use for on-site or reliably LAN-connected machines
$SourceType         = "FileShare"     # "GitHub" or "FileShare"

# --- Source path ---
# GitHub    →  repo in "OrgName/repo-name" format (files must be in repo root)
# FileShare →  full UNC path to the folder containing the migration files
#              e.g. "\\fileserver\migrations\Contoso"
#              SYSTEM must have read access to this share
$SourcePath         = ""

# --- GitHub only — branch to pull from (ignored for FileShare) ---
$GitHubBranch       = "main"

# --- Domain ---
# On-prem AD domain short name (NetBIOS name) — used for profile detection
# Example: "REHARRIS", "CONTOSO", "ACMECORP"
$DomainShortName    = ""

# --- Client-specific filenames ---
# Just the filename, not a path. Files must exist at the source location.
$FileNamePPKG       = ""     # e.g. "Contoso-Entra.ppkg - whatever you named your provisioning package"
$FileNameAzureID    = ""     # e.g. "Contoso-ForensiTAzureID.xml - whatever you named your Azure object ID file"
$FileNameUserLookup = ""     # e.g. "Contoso-UserLookup.csv - whatever you named your usermapping file"

# --- Client tag ---
# Short identifier used in log headers and scheduled task names.
# Alphanumeric + hyphens only, no spaces. Example: "Contoso", "ACME", "REHIA"
$ClientTag          = ""

# ===========================================================================
# END CLIENT CONFIGURATION — Do not edit below this line
# ===========================================================================

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$WorkDir    = "C:\workspace"
$LogFile    = "$WorkDir\Migration.log"
$ProfwizExe = "$WorkDir\Profwiz.exe"
$ConfigFile = "$WorkDir\Profwiz.config"
$TaskName   = "$ClientTag-PostRebootValidation"

# Static files (same across all clients)
$StaticFiles = @(
    "Profwiz.exe",
    "Profwiz.config"
)

# Client-specific files — built from the config block above
$ClientFiles = @(
    $FileNamePPKG,
    $FileNameAzureID,
    $FileNameUserLookup
)

$RequiredFiles = $StaticFiles + $ClientFiles

# Profiles to always skip during local account scan
$IgnoredProfiles = @(
    "Administrator","Default","Public","Guest","defaultuser0","WDAGUtilityAccount"
)

# ---------------------------------------------------------------------------
# CONFIG VALIDATION — Catch missing config values before doing any real work
# ---------------------------------------------------------------------------
function Assert-Config {
    $errors = @()

    if ($SourceType -notin @("GitHub","FileShare"))        { $errors += "SourceType must be 'GitHub' or 'FileShare'" }
    if ([string]::IsNullOrWhiteSpace($SourcePath))         { $errors += "SourcePath is not set" }
    if ([string]::IsNullOrWhiteSpace($DomainShortName))    { $errors += "DomainShortName is not set" }
    if ([string]::IsNullOrWhiteSpace($FileNamePPKG))       { $errors += "FileNamePPKG is not set" }
    if ([string]::IsNullOrWhiteSpace($FileNameAzureID))    { $errors += "FileNameAzureID is not set" }
    if ([string]::IsNullOrWhiteSpace($FileNameUserLookup)) { $errors += "FileNameUserLookup is not set" }
    if ([string]::IsNullOrWhiteSpace($ClientTag))          { $errors += "ClientTag is not set" }

    if ($SourceType -eq "FileShare" -and -not (Test-Path $SourcePath)) {
        $errors += "FileShare path '$SourcePath' is not reachable - check the UNC path and SYSTEM share permissions"
    }

    if ($errors.Count -gt 0) {
        Write-Host "[ERROR] Script is missing required configuration values:" -ForegroundColor Red
        foreach ($e in $errors) {
            Write-Host "  - $e" -ForegroundColor Red
        }
        Write-Host "Fill in the CLIENT CONFIGURATION block at the top of the script and redeploy." -ForegroundColor Red
        exit 1
    }
}

# ---------------------------------------------------------------------------
# LOGGING
# ---------------------------------------------------------------------------
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO','SUCCESS','WARN','ERROR')]
        [string]$Level = 'INFO'
    )
    $ts   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts][$Level] $Message"
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
    switch ($Level) {
        'INFO'    { Write-Host $line -ForegroundColor Cyan   }
        'SUCCESS' { Write-Host $line -ForegroundColor Green  }
        'WARN'    { Write-Host $line -ForegroundColor Yellow }
        'ERROR'   { Write-Host $line -ForegroundColor Red    }
    }
}

# ---------------------------------------------------------------------------
# STEP 1 - Create working directory
# ---------------------------------------------------------------------------
function Initialize-WorkDir {
    if (-not (Test-Path $WorkDir)) {
        New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
        Write-Log "Created working directory: $WorkDir" -Level SUCCESS
    } else {
        Write-Log "Working directory already exists: $WorkDir" -Level INFO
    }
}

# ---------------------------------------------------------------------------
# STEP 2 - Log machine context + detect local accounts
# ---------------------------------------------------------------------------
function Write-MachineContext {
    Write-Log "--- Machine Context ---" -Level INFO

    $hostname   = $env:COMPUTERNAME
    $domainInfo = (Get-WmiObject Win32_ComputerSystem).Domain
    $osCaption  = (Get-WmiObject Win32_OperatingSystem).Caption
    $runAs      = [Security.Principal.WindowsIdentity]::GetCurrent().Name

    Write-Log "  Client tag : $ClientTag"
    Write-Log "  Source     : [$SourceType] $SourcePath"
    Write-Log "  Hostname   : $hostname"
    Write-Log "  Domain     : $domainInfo"
    Write-Log "  OS         : $osCaption"
    Write-Log "  RunAs      : $runAs"

    Write-Log "--- Profile Scan ---" -Level INFO

    $profiles = Get-WmiObject Win32_UserProfile | Where-Object { -not $_.Special }
    $localAccountsFound = @()

    foreach ($p in $profiles) {
        $folderName = Split-Path $p.LocalPath -Leaf
        if ($IgnoredProfiles -contains $folderName) { continue }

        $accountName = $null
        try {
            $accountName = (New-Object Security.Principal.SecurityIdentifier($p.SID)).Translate([Security.Principal.NTAccount]).Value
        }
        catch {
            Write-Log "  ORPHANED PROFILE: $($p.LocalPath) (SID: $($p.SID) unresolvable - manual review needed)" -Level WARN
            $localAccountsFound += "ORPHANED: $($p.LocalPath)"
            continue
        }

        if ($accountName -match "^$DomainShortName\\") {
            Write-Log "  DOMAIN PROFILE   : $accountName -> $($p.LocalPath)" -Level INFO
        }
        elseif ($accountName -match "^(NT AUTHORITY|NT SERVICE|BUILTIN)\\") {
            continue
        }
        else {
            Write-Log "  !! LOCAL ACCOUNT DETECTED: $accountName -> $($p.LocalPath) - will NOT be auto-migrated by ProfileWiz" -Level WARN
            $localAccountsFound += "$accountName ($($p.LocalPath))"
        }
    }

    if ($localAccountsFound.Count -gt 0) {
        Write-Log "  !! MANUAL MIGRATION REQUIRED on $hostname - $($localAccountsFound.Count) local account(s):" -Level WARN
        foreach ($entry in $localAccountsFound) {
            Write-Log "     - $entry" -Level WARN
        }
    }
    else {
        Write-Log "  All eligible profiles are domain accounts - no manual follow-up needed." -Level SUCCESS
    }
}

# ---------------------------------------------------------------------------
# STEP 3 - Pull files from source (GitHub or FileShare)
# ---------------------------------------------------------------------------
function Get-MigrationFiles {
    $failed = @()

    if ($SourceType -eq "GitHub") {
        $gitBase = "https://raw.githubusercontent.com/$SourcePath/$GitHubBranch"
        Write-Log "--- Pulling files from GitHub ($SourcePath @ $GitHubBranch) ---" -Level INFO

        foreach ($file in $RequiredFiles) {
            $url  = "$gitBase/$file"
            $dest = "$WorkDir\$file"

            Write-Log "Downloading: $file" -Level INFO
            try {
                Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing -ErrorAction Stop
                $size = (Get-Item $dest).Length
                if ($size -eq 0) {
                    Write-Log "  Zero-byte file: $file - possible 404 or missing file in repo" -Level WARN
                    $failed += $file
                } else {
                    Write-Log "  OK: $file ($size bytes)" -Level SUCCESS
                }
            }
            catch {
                Write-Log "  FAILED: $file - $_" -Level ERROR
                $failed += $file
            }
        }
    }
    elseif ($SourceType -eq "FileShare") {
        Write-Log "--- Copying files from FileShare ($SourcePath) ---" -Level INFO

        foreach ($file in $RequiredFiles) {
            $src  = "$SourcePath\$file"
            $dest = "$WorkDir\$file"

            Write-Log "Copying: $file" -Level INFO
            try {
                Copy-Item -Path $src -Destination $dest -Force -ErrorAction Stop
                $size = (Get-Item $dest).Length
                if ($size -eq 0) {
                    Write-Log "  Zero-byte file after copy: $file - source file may be empty" -Level WARN
                    $failed += $file
                } else {
                    Write-Log "  OK: $file ($size bytes)" -Level SUCCESS
                }
            }
            catch {
                Write-Log "  FAILED: $file - $_" -Level ERROR
                $failed += $file
            }
        }
    }

    if ($failed.Count -gt 0) {
        Write-Log "File transfer failures: $($failed -join ', ') - aborting." -Level ERROR
        exit 1
    }
}

# ---------------------------------------------------------------------------
# STEP 4 - Verify all files present and non-zero
# ---------------------------------------------------------------------------
function Confirm-Files {
    Write-Log "--- Verifying required files ---" -Level INFO
    $missing = @()

    foreach ($file in $RequiredFiles) {
        $path = "$WorkDir\$file"
        if (-not (Test-Path $path) -or (Get-Item $path).Length -eq 0) {
            Write-Log "  MISSING or empty: $file" -Level ERROR
            $missing += $file
        } else {
            Write-Log "  PRESENT: $file" -Level SUCCESS
        }
    }

    if ($missing.Count -gt 0) {
        Write-Log "File verification failed. Missing: $($missing -join ', ')" -Level ERROR
        exit 1
    }

    Write-Log "All required files verified." -Level SUCCESS
}

# ---------------------------------------------------------------------------
# STEP 5 - Confirm at least one lookup user has a profile on this machine
# ---------------------------------------------------------------------------
function Confirm-MappedProfileExists {
    Write-Log "--- Checking userlookup against local profiles ---" -Level INFO

    $csvPath = "$WorkDir\$FileNameUserLookup"
    $csv     = Import-Csv $csvPath

    $localProfiles = Get-WmiObject Win32_UserProfile |
        Where-Object { -not $_.Special } |
        ForEach-Object { Split-Path $_.LocalPath -Leaf }

    $matchFound = $false

    foreach ($row in $csv) {
        # OldUser format is DOMAIN\username — strip the domain prefix
        $username = ($row.OldUser -split "\\")[-1]

        if ($localProfiles | Where-Object { $_ -ieq $username }) {
            Write-Log "  MATCH: $($row.OldUser) -> $($row.NewUser) (profile folder present on this machine)" -Level SUCCESS
            $matchFound = $true
        } else {
            Write-Log "  NO LOCAL PROFILE: $($row.OldUser) - not on this machine, will be skipped by ProfileWiz" -Level INFO
        }
    }

    if (-not $matchFound) {
        Write-Log "ABORT: No users in the lookup CSV have a local profile on this machine. Nothing to migrate." -Level ERROR
        exit 1
    }
}

# ---------------------------------------------------------------------------
# STEP 6 - Register post-reboot Entra join validator
# ---------------------------------------------------------------------------
function Register-PostRebootValidator {
    Write-Log "--- Registering post-reboot Entra join validator ---" -Level INFO

    $ppkgPath   = "$WorkDir\$FileNamePPKG"
    $clientTag  = $ClientTag
    $taskName   = $TaskName

    $validatorScript = @"
`$log = "C:\workspace\PostReboot-Validation.log"
function Write-VLog {
    param([string]`$m, [string]`$l = 'INFO')
    Add-Content `$log "[`$((Get-Date -f 'yyyy-MM-dd HH:mm:ss'))][`$l] `$m"
}

Write-VLog "--- Post-reboot Entra join validation ($clientTag) ---"
Write-VLog "Hostname  : `$env:COMPUTERNAME"
Write-VLog "Timestamp : `$(Get-Date)"

Start-Sleep -Seconds 30

`$dsreg = dsregcmd /status

`$azureJoined  = `$dsreg | Select-String "AzureAdJoined\s*:\s*YES"
`$domainJoined = `$dsreg | Select-String "DomainJoined\s*:\s*YES"

if (`$azureJoined) {
    Write-VLog "SUCCESS: Machine is Entra (Azure AD) joined. Migration completed successfully." INFO
} elseif (`$domainJoined) {
    Write-VLog "WARNING: Machine is still domain joined - ProfileWiz migration may not have completed fully." WARN
    Write-VLog "Check C:\workspace\Migration.log and C:\workspace\Migrate.Log for details." WARN
} else {
    Write-VLog "!! CRITICAL: Machine is NOT Entra joined and NOT domain joined." ERROR
    Write-VLog "!! Possible workgroup limbo state - ppkg may have failed to apply." ERROR
    Write-VLog "!! Manual intervention required before user can log in." ERROR
    Write-VLog "!! Steps: boot to local admin, re-apply ppkg manually, or re-run migration." ERROR

    `$ppkgPath = "$ppkgPath"
    if (Test-Path `$ppkgPath) {
        Write-VLog "Attempting to re-apply provisioning package: `$ppkgPath" WARN
        try {
            Install-ProvisioningPackage -PackagePath `$ppkgPath -ForceInstall -QuietInstall
            Write-VLog "Provisioning package re-applied. A reboot may be required to complete join." WARN
        } catch {
            Write-VLog "!! Failed to re-apply ppkg: `$_" ERROR
        }
    } else {
        Write-VLog "!! ppkg not found at `$ppkgPath - manual re-staging required." ERROR
    }
}

Write-VLog "--- dsregcmd /status output ---"
`$dsreg | ForEach-Object { Add-Content `$log "    `$_" }

Unregister-ScheduledTask -TaskName "$taskName" -Confirm:`$false
"@

    $scriptPath = "$WorkDir\Invoke-PostRebootValidation.ps1"
    $validatorScript | Out-File -FilePath $scriptPath -Encoding UTF8 -Force

    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Log "  Removed existing validator task." -Level WARN
    }

    $action    = New-ScheduledTaskAction -Execute "powershell.exe" `
                     -Argument "-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptPath`""
    $trigger   = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet `
                     -ExecutionTimeLimit (New-TimeSpan -Minutes 10) `
                     -StartWhenAvailable

    Register-ScheduledTask -TaskName $TaskName `
        -Action $action -Trigger $trigger -Principal $principal `
        -Settings $settings `
        -Description "$ClientTag one-time post-migration Entra join validator" `
        -Force | Out-Null

    Write-Log "  Validator task registered ($TaskName) - will run once on next startup as SYSTEM." -Level SUCCESS
}

# ---------------------------------------------------------------------------
# STEP 7 - Run ProfileWiz
# ---------------------------------------------------------------------------
function Invoke-ProfileWiz {
    Write-Log "--- Launching ProfileWiz ---" -Level INFO
    Write-Log "  Executable : $ProfwizExe"
    Write-Log "  Config     : $ConfigFile"
    Write-Log "  Working dir: $WorkDir"

    Set-Location $WorkDir

    try {
        $proc = Start-Process -FilePath $ProfwizExe `
                              -ArgumentList "/config `"$ConfigFile`"" `
                              -Wait `
                              -PassThru `
                              -NoNewWindow

        Write-Log "  ProfileWiz exit code: $($proc.ExitCode)" -Level INFO

        switch ($proc.ExitCode) {
            0       { Write-Log "ProfileWiz completed successfully." -Level SUCCESS }
            1       { Write-Log "ProfileWiz partial success - check C:\workspace\Migrate.Log for details." -Level WARN }
            default { Write-Log "ProfileWiz returned error code $($proc.ExitCode) - check C:\workspace\Migrate.Log." -Level ERROR }
        }
    }
    catch {
        Write-Log "Fatal error launching ProfileWiz: $_" -Level ERROR
        exit 1
    }
}

# ---------------------------------------------------------------------------
# STEP 8 - Reboot
# ---------------------------------------------------------------------------
function Invoke-MigrationReboot {
    if ($NoReboot) {
        Write-Log "--- -NoReboot flag set - skipping reboot. Reboot manually to finalize. ---" -Level WARN
        return
    }

    Write-Log "--- Initiating forced reboot in 60 seconds to finalize Azure AD join ---" -Level INFO
    shutdown.exe /r /f /t 60 /c "$ClientTag Profile Migration complete - rebooting to finalize Azure AD join"
}

# ---------------------------------------------------------------------------
# MAIN
# ---------------------------------------------------------------------------
Assert-Config   # Validate config block before touching anything on disk

Write-Log "========================================================" -Level INFO
Write-Log " $ClientTag ProfileWiz Migration - START" -Level INFO
Write-Log " Timestamp : $(Get-Date)" -Level INFO
Write-Log " Template  : 1.1" -Level INFO
Write-Log "========================================================" -Level INFO

Initialize-WorkDir
Write-MachineContext
Get-MigrationFiles
Confirm-Files
Confirm-MappedProfileExists
Register-PostRebootValidator
Invoke-ProfileWiz
Invoke-MigrationReboot

Write-Log "========================================================" -Level INFO
Write-Log " $ClientTag ProfileWiz Migration - COMPLETE" -Level INFO
Write-Log "========================================================" -Level INFO
