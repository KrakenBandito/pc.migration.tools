<#
.SYNOPSIS
Exports lean Chrome profile backups without copying cache-heavy browser data.

.DESCRIPTION
Copies the profile files that are usually needed for a migration or backup:
profile registry, bookmarks, preferences, favicons, web form data, shortcuts,
and top sites.

Extension packages are skipped by default because Chrome can normally download
them again after sign-in or sync. Extension data, cookies, and saved passwords
are opt-in because they may be machine-specific or unnecessary for migration.

Use -Zip to create a compressed archive that can be restored by
Restore-ChromeProfilesLite.ps1.

.EXAMPLE
.\scripts\Export-ChromeProfilesLite.ps1 -DryRun

.EXAMPLE
.\scripts\Export-ChromeProfilesLite.ps1 -Destination D:\ChromeProfileExport -Zip

.EXAMPLE
.\scripts\Export-ChromeProfilesLite.ps1 -Profiles "Default","Profile 4" -IncludeHistory -IncludeSessions -Zip
#>

[CmdletBinding()]
param(
    [string]$SourceUserData = (Join-Path $env:LOCALAPPDATA "Google\Chrome\User Data"),

    [string]$Destination = (Join-Path (Get-Location) ("chrome-profile-export-{0}" -f (Get-Date -Format "yyyyMMdd-HHmmss"))),

    [string]$ZipPath,

    [string[]]$Profiles,

    [switch]$IncludeHistory,

    [switch]$IncludeCookies,

    [switch]$IncludePasswords,

    [switch]$IncludeSessions,

    [switch]$IncludeExtensionData,

    [switch]$Zip,

    [switch]$DryRun,

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message"
}

function Write-Warn {
    param([string]$Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Get-LocalState {
    param([string]$UserDataPath)

    $localStatePath = Join-Path $UserDataPath "Local State"
    if (-not (Test-Path -LiteralPath $localStatePath -PathType Leaf)) {
        return $null
    }

    try {
        return Get-Content -LiteralPath $localStatePath -Raw | ConvertFrom-Json
    }
    catch {
        Write-Warn "Could not parse Local State. Falling back to directory detection. $($_.Exception.Message)"
        return $null
    }
}

function Get-ProfileMap {
    param(
        [string]$UserDataPath,
        $LocalState
    )

    $profilesByDirectory = @{}

    if ($null -ne $LocalState -and
        $LocalState.PSObject.Properties.Name -contains "profile" -and
        $null -ne $LocalState.profile -and
        $LocalState.profile.PSObject.Properties.Name -contains "info_cache" -and
        $null -ne $LocalState.profile.info_cache) {

        foreach ($profileProperty in $LocalState.profile.info_cache.PSObject.Properties) {
            $directoryName = $profileProperty.Name
            $displayName = $directoryName
            if ($profileProperty.Value.PSObject.Properties.Name -contains "name" -and
                -not [string]::IsNullOrWhiteSpace($profileProperty.Value.name)) {
                $displayName = [string]$profileProperty.Value.name
            }

            $profilesByDirectory[$directoryName] = [pscustomobject]@{
                DirectoryName = $directoryName
                DisplayName = $displayName
                Path = Join-Path $UserDataPath $directoryName
            }
        }
    }

    $candidateDirectories = Get-ChildItem -LiteralPath $UserDataPath -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -eq "Default" -or
            $_.Name -like "Profile *" -or
            $_.Name -eq "Guest Profile"
        }

    foreach ($directory in $candidateDirectories) {
        if (-not $profilesByDirectory.ContainsKey($directory.Name)) {
            $profilesByDirectory[$directory.Name] = [pscustomobject]@{
                DirectoryName = $directory.Name
                DisplayName = $directory.Name
                Path = $directory.FullName
            }
        }
    }

    return @($profilesByDirectory.Values | Sort-Object DirectoryName)
}

function Select-Profiles {
    param(
        [object[]]$ProfileMap,
        [string[]]$RequestedProfiles
    )

    if ($null -eq $RequestedProfiles -or $RequestedProfiles.Count -eq 0) {
        return @($ProfileMap)
    }

    $selected = New-Object System.Collections.Generic.List[object]
    foreach ($requestedProfile in $RequestedProfiles) {
        $match = @($ProfileMap | Where-Object {
            $_.DirectoryName -eq $requestedProfile -or $_.DisplayName -eq $requestedProfile
        })

        if ($match.Count -eq 0) {
            throw "Requested profile '$requestedProfile' was not found by directory name or display name."
        }

        foreach ($profileMatch in $match) {
            $selected.Add($profileMatch)
        }
    }

    return @($selected | Sort-Object DirectoryName -Unique)
}

function Add-CopyPlanItem {
    param(
        [System.Collections.Generic.List[object]]$Plan,
        [string]$SourceRoot,
        [string]$RelativePath,
        [string]$TargetRoot,
        [string]$Category
    )

    $sourcePath = Join-Path $SourceRoot $RelativePath
    if (-not (Test-Path -LiteralPath $sourcePath)) {
        return
    }

    $targetPath = Join-Path $TargetRoot $RelativePath
    $item = Get-Item -LiteralPath $sourcePath -Force
    $Plan.Add([pscustomobject]@{
        Category = $Category
        RelativePath = $RelativePath
        SourcePath = $sourcePath
        TargetPath = $targetPath
        IsDirectory = [bool]$item.PSIsContainer
    })
}

function Copy-PlanItem {
    param([object]$Item)

    $targetParent = Split-Path -Parent $Item.TargetPath
    if (-not (Test-Path -LiteralPath $targetParent)) {
        New-Item -ItemType Directory -Force -Path $targetParent | Out-Null
    }

    if ($Item.IsDirectory) {
        Copy-Item -LiteralPath $Item.SourcePath -Destination $Item.TargetPath -Recurse -Force
    }
    else {
        Copy-Item -LiteralPath $Item.SourcePath -Destination $Item.TargetPath -Force
    }
}

function Repair-ZipCompatibleTimestamps {
    param([string]$Path)

    $minimumZipTime = [datetime]"1980-01-01T00:00:00"
    $maximumZipTime = [datetime]"2107-12-31T23:59:58"

    Get-ChildItem -LiteralPath $Path -Recurse -Force | ForEach-Object {
        if ($_.LastWriteTime -lt $minimumZipTime) {
            $_.LastWriteTime = $minimumZipTime
        }
        elseif ($_.LastWriteTime -gt $maximumZipTime) {
            $_.LastWriteTime = $maximumZipTime
        }
    }
}

function Write-Readme {
    param(
        [string]$OutputPath,
        [object[]]$ProfilesToExport,
        [string]$SourceUserDataPath
    )

    $profileLines = @($ProfilesToExport | ForEach-Object {
        "- $($_.DirectoryName) ($($_.DisplayName))"
    })

    $readme = @(
        "Chrome Profile Lite Export",
        "",
        "Created: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")",
        "Source: $SourceUserDataPath",
        "",
        "Profiles:",
        $profileLines,
        "",
        "Restore:",
        "- Close Chrome before restoring.",
        "- From a folder export: .\scripts\Restore-ChromeProfilesLite.ps1 -Source <export-folder>",
        "- From a zip export: .\scripts\Restore-ChromeProfilesLite.ps1 -Source <export.zip>",
        "- Use -DryRun first to preview restore operations.",
        "",
        "Notes:",
        "- This export intentionally skips cache-heavy folders such as Cache, Code Cache, GPUCache, Service Worker cache, blob_storage, ShaderCache, and storage buckets.",
        "- Extension packages are skipped by default because Chrome can normally download them again after sign-in or sync.",
        "- Cookies and saved passwords are encrypted by Chrome and Windows. If included, they may not work on a different PC or Windows account."
    )

    $readme | Set-Content -LiteralPath (Join-Path $OutputPath "README.txt") -Encoding UTF8
}

if (-not (Test-Path -LiteralPath $SourceUserData -PathType Container)) {
    throw "Chrome User Data folder was not found: $SourceUserData"
}

if ($ZipPath -and -not $Zip) {
    $Zip = $true
}

if ($Zip -and [string]::IsNullOrWhiteSpace($ZipPath)) {
    $ZipPath = "$Destination.zip"
}

if ($IncludeCookies -or $IncludePasswords) {
    Write-Warn "Cookies and saved passwords are encrypted per Windows user and machine. Copying them may not make them usable on another PC."
}

$destinationExists = Test-Path -LiteralPath $Destination
if ($destinationExists -and -not $Force -and -not $DryRun) {
    throw "Destination already exists. Use -Force to merge into it or choose a new -Destination. Path: $Destination"
}

if ($Zip -and (Test-Path -LiteralPath $ZipPath) -and -not $Force -and -not $DryRun) {
    throw "Zip destination already exists. Use -Force to overwrite it or choose a new -ZipPath. Path: $ZipPath"
}

$localState = Get-LocalState -UserDataPath $SourceUserData
$profileMap = @(Get-ProfileMap -UserDataPath $SourceUserData -LocalState $localState)
if ($profileMap.Count -eq 0) {
    throw "No Chrome profiles were found in: $SourceUserData"
}

$profilesToExport = @(Select-Profiles -ProfileMap $profileMap -RequestedProfiles $Profiles)
Write-Info "Profiles selected: $($profilesToExport.Count)"

$copyPlan = New-Object System.Collections.Generic.List[object]
Add-CopyPlanItem -Plan $copyPlan -SourceRoot $SourceUserData -RelativePath "Local State" -TargetRoot $Destination -Category "Chrome root"
Add-CopyPlanItem -Plan $copyPlan -SourceRoot $SourceUserData -RelativePath "First Run" -TargetRoot $Destination -Category "Chrome root"

$defaultProfileFiles = @(
    "Bookmarks",
    "Bookmarks.bak",
    "Preferences",
    "Secure Preferences",
    "Favicons",
    "Favicons-journal",
    "Shortcuts",
    "Shortcuts-journal",
    "Top Sites",
    "Top Sites-journal",
    "Web Data",
    "Web Data-journal",
    "Visited Links",
    "Network Action Predictor",
    "Network Action Predictor-journal"
)

$historyFiles = @(
    "History",
    "History-journal",
    "Archived History",
    "History Provider Cache"
)

$cookieFiles = @(
    "Network\Cookies",
    "Network\Cookies-journal"
)

$passwordFiles = @(
    "Login Data",
    "Login Data-journal"
)

$sessionDirectories = @(
    "Sessions"
)

$extensionDataDirectories = @(
    "Extension Rules",
    "Extension State",
    "Managed Extension Settings",
    "Local Extension Settings",
    "Sync Extension Settings",
    "Sync Data"
)

foreach ($profileEntry in $profilesToExport) {
    if (-not (Test-Path -LiteralPath $profileEntry.Path -PathType Container)) {
        Write-Warn "Skipping missing profile directory: $($profileEntry.Path)"
        continue
    }

    foreach ($relativePath in $defaultProfileFiles) {
        Add-CopyPlanItem -Plan $copyPlan -SourceRoot $profileEntry.Path -RelativePath $relativePath -TargetRoot (Join-Path $Destination $profileEntry.DirectoryName) -Category $profileEntry.DirectoryName
    }

    if ($IncludeHistory) {
        foreach ($relativePath in $historyFiles) {
            Add-CopyPlanItem -Plan $copyPlan -SourceRoot $profileEntry.Path -RelativePath $relativePath -TargetRoot (Join-Path $Destination $profileEntry.DirectoryName) -Category "$($profileEntry.DirectoryName) history"
        }
    }

    if ($IncludeCookies) {
        foreach ($relativePath in $cookieFiles) {
            Add-CopyPlanItem -Plan $copyPlan -SourceRoot $profileEntry.Path -RelativePath $relativePath -TargetRoot (Join-Path $Destination $profileEntry.DirectoryName) -Category "$($profileEntry.DirectoryName) cookies"
        }
    }

    if ($IncludePasswords) {
        foreach ($relativePath in $passwordFiles) {
            Add-CopyPlanItem -Plan $copyPlan -SourceRoot $profileEntry.Path -RelativePath $relativePath -TargetRoot (Join-Path $Destination $profileEntry.DirectoryName) -Category "$($profileEntry.DirectoryName) passwords"
        }
    }

    if ($IncludeSessions) {
        foreach ($relativePath in $sessionDirectories) {
            Add-CopyPlanItem -Plan $copyPlan -SourceRoot $profileEntry.Path -RelativePath $relativePath -TargetRoot (Join-Path $Destination $profileEntry.DirectoryName) -Category "$($profileEntry.DirectoryName) sessions"
        }
    }

    if ($IncludeExtensionData) {
        foreach ($relativePath in $extensionDataDirectories) {
            Add-CopyPlanItem -Plan $copyPlan -SourceRoot $profileEntry.Path -RelativePath $relativePath -TargetRoot (Join-Path $Destination $profileEntry.DirectoryName) -Category "$($profileEntry.DirectoryName) extension data"
        }
    }
}

if ($copyPlan.Count -eq 0) {
    throw "No files matched the export plan."
}

Write-Info "Items in copy plan: $($copyPlan.Count)"
if ($Zip) {
    Write-Info "Zip output: $ZipPath"
}

if ($DryRun) {
    Write-Info "Dry run only. Nothing will be copied or zipped."
    $copyPlan |
        Sort-Object Category, RelativePath |
        Select-Object Category, RelativePath, SourcePath, TargetPath |
        Format-Table -AutoSize
    exit 0
}

if ($destinationExists -and $Force) {
    Remove-Item -LiteralPath $Destination -Recurse -Force
}

New-Item -ItemType Directory -Force -Path $Destination | Out-Null

$manifest = New-Object System.Collections.Generic.List[object]
foreach ($item in ($copyPlan | Sort-Object Category, RelativePath)) {
    try {
        Copy-PlanItem -Item $item
        $manifest.Add([pscustomobject]@{
            Category = $item.Category
            RelativePath = $item.RelativePath
            SourcePath = $item.SourcePath
            TargetPath = $item.TargetPath
            Status = "Copied"
        })
    }
    catch {
        $manifest.Add([pscustomobject]@{
            Category = $item.Category
            RelativePath = $item.RelativePath
            SourcePath = $item.SourcePath
            TargetPath = $item.TargetPath
            Status = "Failed: $($_.Exception.Message)"
        })
        Write-Warn "Failed to copy '$($item.SourcePath)': $($_.Exception.Message)"
    }
}

$manifestPath = Join-Path $Destination "manifest.json"
$manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
Write-Readme -OutputPath $Destination -ProfilesToExport $profilesToExport -SourceUserDataPath $SourceUserData

$failedCount = @($manifest | Where-Object { $_.Status -like "Failed:*" }).Count
if ($Zip) {
    $zipParent = Split-Path -Parent $ZipPath
    if (-not [string]::IsNullOrWhiteSpace($zipParent) -and -not (Test-Path -LiteralPath $zipParent)) {
        New-Item -ItemType Directory -Force -Path $zipParent | Out-Null
    }

    if ((Test-Path -LiteralPath $ZipPath) -and $Force) {
        Remove-Item -LiteralPath $ZipPath -Force
    }

    Repair-ZipCompatibleTimestamps -Path $Destination
    Compress-Archive -Path (Join-Path $Destination "*") -DestinationPath $ZipPath -Force:$Force
    Write-Info "Zip complete: $ZipPath"
}

Write-Info "Export complete: $Destination"
Write-Info "Manifest: $manifestPath"
if ($failedCount -gt 0) {
    Write-Warn "$failedCount item(s) failed. Check manifest.json for details."
}
