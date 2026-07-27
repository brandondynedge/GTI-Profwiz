<#
.SYNOPSIS
    ProfileWiz Migration Script Generator

.DESCRIPTION
    Prompts for the client specific configuration values and writes out a
    completed copy of the ProfileWiz migration script for that client.
    Run this once per client instead of hand editing the config block.

.NOTES
    Expects ProfileWiz-Migration-Template.ps1 to be in the same folder as
    this script unless -TemplatePath is supplied.
#>

param(
    [string]$TemplatePath = "$PSScriptRoot\ProfileWiz-Migration-Template.ps1",
    [string]$OutputDirectory = "$PSScriptRoot\Generated"
)

function Read-RequiredValue {
    param([string]$Prompt)
    do {
        $value = Read-Host $Prompt
    } while ([string]::IsNullOrWhiteSpace($value))
    return $value
}

if (-not (Test-Path $TemplatePath)) {
    Write-Host "Template not found at $TemplatePath" -ForegroundColor Red
    exit 1
}

Write-Host "ProfileWiz Migration Script Generator" -ForegroundColor Cyan
Write-Host "Enter the client specific values below." -ForegroundColor Cyan
Write-Host ""

$ClientTag = Read-RequiredValue "Client tag, alphanumeric only, e.g. Contoso"

$SourceType = ""
while ($SourceType -notin @("GitHub", "FileShare")) {
    $SourceType = Read-Host "Source type, enter GitHub or FileShare"
}

if ($SourceType -eq "GitHub") {
    $SourcePath = Read-RequiredValue "GitHub repo, format OrgName/repo-name"
    $branchInput = Read-Host "GitHub branch, press Enter for main"
    if ([string]::IsNullOrWhiteSpace($branchInput)) {
        $GitHubBranch = "main"
    } else {
        $GitHubBranch = $branchInput
    }
} else {
    $SourcePath = Read-RequiredValue "FileShare UNC path, example \\server\share\folder"
    $GitHubBranch = "main"
}

$DomainShortName    = Read-RequiredValue "On prem AD domain short name, NetBIOS format, e.g. CONTOSO"
$FileNamePPKG       = Read-RequiredValue "Provisioning package filename, .ppkg"
$FileNameAzureID    = Read-RequiredValue "Azure AD object ID filename, .xml"
$FileNameUserLookup = Read-RequiredValue "User lookup filename, .csv"

$content = Get-Content -Path $TemplatePath -Raw

$oldLines = @(
    '$SourceType         = "FileShare"     # "GitHub" or "FileShare"',
    '$SourcePath         = ""',
    '$GitHubBranch       = "main"',
    '$DomainShortName    = ""',
    '$FileNamePPKG       = ""     # e.g. "Contoso-Entra.ppkg - whatever you named your provisioning package"',
    '$FileNameAzureID    = ""     # e.g. "Contoso-ForensiTAzureID.xml - whatever you named your Azure object ID file"',
    '$FileNameUserLookup = ""     # e.g. "Contoso-UserLookup.csv - whatever you named your usermapping file"',
    '$ClientTag          = ""'
)

$newLines = @(
    ('$SourceType         = "' + $SourceType + '"'),
    ('$SourcePath         = "' + $SourcePath + '"'),
    ('$GitHubBranch       = "' + $GitHubBranch + '"'),
    ('$DomainShortName    = "' + $DomainShortName + '"'),
    ('$FileNamePPKG       = "' + $FileNamePPKG + '"'),
    ('$FileNameAzureID    = "' + $FileNameAzureID + '"'),
    ('$FileNameUserLookup = "' + $FileNameUserLookup + '"'),
    ('$ClientTag          = "' + $ClientTag + '"')
)

for ($i = 0; $i -lt $oldLines.Count; $i++) {
    if ($content -notlike "*$($oldLines[$i])*") {
        Write-Host "Warning, expected line not found in template, check template has not changed:" -ForegroundColor Yellow
        Write-Host "  $($oldLines[$i])" -ForegroundColor Yellow
    }
    $content = $content.Replace($oldLines[$i], $newLines[$i])
}

if (-not (Test-Path $OutputDirectory)) {
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
}

$outputPath = Join-Path $OutputDirectory "$ClientTag-ProfileWiz-Migration.ps1"
$content | Out-File -FilePath $outputPath -Encoding UTF8 -Force

Write-Host ""
Write-Host "Generated script written to:" -ForegroundColor Green
Write-Host "  $outputPath" -ForegroundColor Green
Write-Host ""
Write-Host "Review the file, then deploy it through your RMM for this client." -ForegroundColor Green
