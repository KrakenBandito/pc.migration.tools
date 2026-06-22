<#
.SYNOPSIS
Runs integration tests for the Chrome profile export and restore scripts.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$exportScript = Join-Path $scriptRoot "Export-ChromeProfilesLite.ps1"
$restoreScript = Join-Path $scriptRoot "Restore-ChromeProfilesLite.ps1"
$testRoot = Join-Path $env:TEMP ("chrome-profile-lite-tests-{0}" -f ([guid]::NewGuid().ToString("N")))

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
}

function Assert-PathExists {
    param([string]$Path)
    Assert-True -Condition (Test-Path -LiteralPath $Path) -Message "Expected path to exist: $Path"
}

function Assert-PathMissing {
    param([string]$Path)
    Assert-True -Condition (-not (Test-Path -LiteralPath $Path)) -Message "Expected path to be absent: $Path"
}

function Write-TestInfo {
    param([string]$Message)
    Write-Host "[TEST] $Message"
}

try {
    $sourceUserData = Join-Path $testRoot "Source User Data"
    $exportDestination = Join-Path $testRoot "Export"
    $zipPath = Join-Path $testRoot "Export.zip"
    $restoreTarget = Join-Path $testRoot "Restored User Data"

    New-Item -ItemType Directory -Force -Path $sourceUserData | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $sourceUserData "Default\Extensions\abc\1.0.0") | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $sourceUserData "Default\Network") | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $sourceUserData "Profile 4\Sessions") | Out-Null

    @"
{
  "profile": {
    "info_cache": {
      "Default": { "name": "Person 1" },
      "Profile 4": { "name": "Work" }
    }
  }
}
"@ | Set-Content -LiteralPath (Join-Path $sourceUserData "Local State") -Encoding UTF8

    "first-run" | Set-Content -LiteralPath (Join-Path $sourceUserData "First Run") -Encoding UTF8
    "bookmarks" | Set-Content -LiteralPath (Join-Path $sourceUserData "Default\Bookmarks") -Encoding UTF8
    "prefs" | Set-Content -LiteralPath (Join-Path $sourceUserData "Default\Preferences") -Encoding UTF8
    "extension" | Set-Content -LiteralPath (Join-Path $sourceUserData "Default\Extensions\abc\1.0.0\manifest.json") -Encoding UTF8
    "cookies" | Set-Content -LiteralPath (Join-Path $sourceUserData "Default\Network\Cookies") -Encoding UTF8
    "history" | Set-Content -LiteralPath (Join-Path $sourceUserData "Default\History") -Encoding UTF8
    "session" | Set-Content -LiteralPath (Join-Path $sourceUserData "Profile 4\Sessions\Session_1") -Encoding UTF8
    "work bookmarks" | Set-Content -LiteralPath (Join-Path $sourceUserData "Profile 4\Bookmarks") -Encoding UTF8
    (Get-Item -LiteralPath (Join-Path $sourceUserData "Default\Bookmarks")).LastWriteTime = [datetime]"1979-12-31T23:59:58"

    Write-TestInfo "Dry-run export"
    & $exportScript -SourceUserData $sourceUserData -Destination $exportDestination -Profiles "Default","Work" -IncludeCookies -IncludeHistory -IncludeSessions -ZipPath $zipPath -DryRun | Out-Null
    Assert-True -Condition (-not (Test-Path -LiteralPath $exportDestination)) -Message "Dry-run export should not create destination"
    Assert-True -Condition (-not (Test-Path -LiteralPath $zipPath)) -Message "Dry-run export should not create zip"

    Write-TestInfo "Export with zip"
    & $exportScript -SourceUserData $sourceUserData -Destination $exportDestination -Profiles "Default","Work" -IncludeCookies -IncludeHistory -IncludeSessions -ZipPath $zipPath
    Assert-PathExists -Path (Join-Path $exportDestination "Local State")
    Assert-PathExists -Path (Join-Path $exportDestination "README.txt")
    Assert-PathExists -Path (Join-Path $exportDestination "manifest.json")
    Assert-PathExists -Path (Join-Path $exportDestination "Default\Bookmarks")
    Assert-PathExists -Path (Join-Path $exportDestination "Default\Network\Cookies")
    Assert-PathExists -Path (Join-Path $exportDestination "Default\History")
    Assert-PathExists -Path (Join-Path $exportDestination "Profile 4\Sessions\Session_1")
    Assert-PathMissing -Path (Join-Path $exportDestination "Default\Extensions\abc\1.0.0\manifest.json")
    Assert-PathExists -Path $zipPath

    Write-TestInfo "Dry-run restore from zip"
    & $restoreScript -Source $zipPath -TargetUserData $restoreTarget -DryRun -SkipChromeProcessCheck | Out-Null
    Assert-True -Condition (-not (Test-Path -LiteralPath $restoreTarget)) -Message "Dry-run restore should not create target"

    Write-TestInfo "Restore from zip"
    & $restoreScript -Source $zipPath -TargetUserData $restoreTarget -SkipChromeProcessCheck
    Assert-PathExists -Path (Join-Path $restoreTarget "Local State")
    Assert-PathExists -Path (Join-Path $restoreTarget "Default\Bookmarks")
    Assert-PathExists -Path (Join-Path $restoreTarget "Default\Network\Cookies")
    Assert-PathExists -Path (Join-Path $restoreTarget "Profile 4\Sessions\Session_1")
    Assert-PathExists -Path (Join-Path $restoreTarget "restore-manifest.json")

    Write-TestInfo "Restore overwrite protection"
    $failedAsExpected = $false
    try {
        & $restoreScript -Source $zipPath -TargetUserData $restoreTarget -SkipChromeProcessCheck | Out-Null
    }
    catch {
        $failedAsExpected = $true
    }
    Assert-True -Condition $failedAsExpected -Message "Restore should require -Force when target files already exist"

    Write-TestInfo "Restore overwrite with force"
    & $restoreScript -Source $zipPath -TargetUserData $restoreTarget -SkipChromeProcessCheck -Force | Out-Null

    Write-TestInfo "All tests passed"
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
