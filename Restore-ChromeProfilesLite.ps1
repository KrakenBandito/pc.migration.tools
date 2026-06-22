<#
.SYNOPSIS
Restores a lite Chrome profile export created by Export-ChromeProfilesLite.ps1.

.DESCRIPTION
Restores either an export folder or a zip archive into a Chrome User Data
folder. By default this script requires Chrome to be closed and refuses to
overwrite existing files unless -Force is supplied.

.EXAMPLE
.\scripts\Restore-ChromeProfilesLite.ps1 -Source D:\ChromeProfileExport -DryRun

.EXAMPLE
.\scripts\Restore-ChromeProfilesLite.ps1 -Source D:\ChromeProfileExport.zip -TargetUserData "$env:LOCALAPPDATA\Google\Chrome\User Data" -Force
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Source,

    [string]$TargetUserData = (Join-Path $env:LOCALAPPDATA "Google\Chrome\User Data"),

    [string]$WorkingDirectory = (Join-Path $env:TEMP ("chrome-profile-restore-{0}" -f ([guid]::NewGuid().ToString("N")))),

    [switch]$DryRun,

    [switch]$Force,

    [switch]$SkipChromeProcessCheck,

    [switch]$KeepExtractedFiles
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

function Test-ZipPath {
    param([string]$Path)
    return [System.IO.Path]::GetExtension($Path).Equals(".zip", [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-RelativePath {
    param(
        [string]$Root,
        [string]$Path
    )

    $rootFullPath = [System.IO.Path]::GetFullPath($Root)
    $rootFullPath = $rootFullPath.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $rootFullPath = $rootFullPath + [System.IO.Path]::DirectorySeparatorChar
    $fullPath = [System.IO.Path]::GetFullPath($Path)

    if (-not $fullPath.StartsWith($rootFullPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Path is not under root. Root: $Root Path: $Path"
    }

    return $fullPath.Substring($rootFullPath.Length)
}

function Assert-ChromeClosed {
    $chromeProcesses = @(Get-Process -Name "chrome" -ErrorAction SilentlyContinue)
    if ($chromeProcesses.Count -gt 0) {
        throw "Chrome is running. Close Chrome before restore, or use -SkipChromeProcessCheck if you are restoring test data."
    }
}

function Resolve-RestoreRoot {
    param(
        [string]$InputSource,
        [string]$ExtractRoot
    )

    if (-not (Test-Path -LiteralPath $InputSource)) {
        throw "Restore source was not found: $InputSource"
    }

    if ((Test-Path -LiteralPath $InputSource -PathType Leaf) -and (Test-ZipPath -Path $InputSource)) {
        if (Test-Path -LiteralPath $ExtractRoot) {
            Remove-Item -LiteralPath $ExtractRoot -Recurse -Force
        }

        New-Item -ItemType Directory -Force -Path $ExtractRoot | Out-Null
        Expand-Archive -LiteralPath $InputSource -DestinationPath $ExtractRoot -Force
        return $ExtractRoot
    }

    if (Test-Path -LiteralPath $InputSource -PathType Container) {
        return $InputSource
    }

    throw "Restore source must be an export folder or .zip archive: $InputSource"
}

function Get-RestorePlan {
    param(
        [string]$RestoreRoot,
        [string]$TargetRoot
    )

    $excludedRootFiles = @(
        "README.txt",
        "manifest.json"
    )

    $files = Get-ChildItem -LiteralPath $RestoreRoot -File -Recurse -Force |
        Where-Object {
            $relative = Get-RelativePath -Root $RestoreRoot -Path $_.FullName
            $relativeParts = $relative -split '[\\/]'
            -not ($relativeParts.Count -eq 1 -and $excludedRootFiles -contains $relativeParts[0])
        }

    return @($files | ForEach-Object {
        $relativePath = Get-RelativePath -Root $RestoreRoot -Path $_.FullName
        [pscustomobject]@{
            RelativePath = $relativePath
            SourcePath = $_.FullName
            TargetPath = Join-Path $TargetRoot $relativePath
            TargetExists = Test-Path -LiteralPath (Join-Path $TargetRoot $relativePath)
        }
    })
}

function Copy-RestorePlanItem {
    param([object]$Item)

    $targetParent = Split-Path -Parent $Item.TargetPath
    if (-not (Test-Path -LiteralPath $targetParent)) {
        New-Item -ItemType Directory -Force -Path $targetParent | Out-Null
    }

    Copy-Item -LiteralPath $Item.SourcePath -Destination $Item.TargetPath -Force
}

if (-not $SkipChromeProcessCheck) {
    Assert-ChromeClosed
}

$sourceIsZip = (Test-Path -LiteralPath $Source -PathType Leaf) -and (Test-ZipPath -Path $Source)
$restoreRoot = Resolve-RestoreRoot -InputSource $Source -ExtractRoot $WorkingDirectory

try {
    if (-not (Test-Path -LiteralPath (Join-Path $restoreRoot "Local State") -PathType Leaf)) {
        Write-Warn "The restore source does not contain a root 'Local State' file. Verify this is a Chrome profile export."
    }

    $restorePlan = @(Get-RestorePlan -RestoreRoot $restoreRoot -TargetRoot $TargetUserData)
    if ($restorePlan.Count -eq 0) {
        throw "No files were found to restore from: $restoreRoot"
    }

    $existingTargets = @($restorePlan | Where-Object { $_.TargetExists })
    Write-Info "Items in restore plan: $($restorePlan.Count)"
    Write-Info "Target User Data: $TargetUserData"

    if ($existingTargets.Count -gt 0 -and -not $Force) {
        Write-Warn "$($existingTargets.Count) target file(s) already exist."
        if ($DryRun) {
            Write-Warn "Use -Force when ready to overwrite existing files."
        }
        else {
            throw "Restore would overwrite existing files. Re-run with -DryRun to preview or -Force to overwrite."
        }
    }

    if ($DryRun) {
        Write-Info "Dry run only. Nothing will be restored."
        $restorePlan |
            Sort-Object RelativePath |
            Select-Object RelativePath, SourcePath, TargetPath, TargetExists |
            Format-Table -AutoSize
        exit 0
    }

    New-Item -ItemType Directory -Force -Path $TargetUserData | Out-Null

    $manifest = New-Object System.Collections.Generic.List[object]
    foreach ($item in ($restorePlan | Sort-Object RelativePath)) {
        try {
            Copy-RestorePlanItem -Item $item
            $manifest.Add([pscustomobject]@{
                RelativePath = $item.RelativePath
                SourcePath = $item.SourcePath
                TargetPath = $item.TargetPath
                Status = "Restored"
            })
        }
        catch {
            $manifest.Add([pscustomobject]@{
                RelativePath = $item.RelativePath
                SourcePath = $item.SourcePath
                TargetPath = $item.TargetPath
                Status = "Failed: $($_.Exception.Message)"
            })
            Write-Warn "Failed to restore '$($item.SourcePath)': $($_.Exception.Message)"
        }
    }

    $restoreManifestPath = Join-Path $TargetUserData "restore-manifest.json"
    $manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $restoreManifestPath -Encoding UTF8

    $failedCount = @($manifest | Where-Object { $_.Status -like "Failed:*" }).Count
    Write-Info "Restore complete: $TargetUserData"
    Write-Info "Restore manifest: $restoreManifestPath"
    if ($failedCount -gt 0) {
        Write-Warn "$failedCount item(s) failed. Check restore-manifest.json for details."
    }
}
finally {
    if ($sourceIsZip -and -not $KeepExtractedFiles -and (Test-Path -LiteralPath $WorkingDirectory)) {
        Remove-Item -LiteralPath $WorkingDirectory -Recurse -Force
    }
}
