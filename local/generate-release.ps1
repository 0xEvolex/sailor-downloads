<#
.SYNOPSIS
Generates a release note markdown from a manifest (new schema) and template.

.PARAMETER ProjectId
The project id from local/release-manifest.json (e.g., 'sailor-events').

.PARAMETER Output
Optional output path for the generated markdown. Defaults to local/releases/<project-id>/<tag>.md

.PARAMETER Publish
If provided, also creates/updates a GitHub Release for the computed tag and uploads assets.

.PARAMETER DryRun
Simulate publish actions (print commands) without executing them.

.EXAMPLE
./local/generate-release.ps1 -ProjectId sailor-events
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$ProjectId,
    [string]$Output,
    [switch]$Publish,
    [switch]$DryRun,
    [string]$Ref = 'HEAD',
    [switch]$ForceTag,
    [switch]$SeriesTag,
    [switch]$Latest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSCommandPath | Split-Path -Parent
# Resolve manifest: prefer local/release-manifest.json, fallback to repo-root release-manifest.json
$localManifest = Join-Path $root 'local/release-manifest.json'
$rootManifest  = Join-Path $root 'release-manifest.json'
if (Test-Path $localManifest) {
    $manifestPath = $localManifest
} elseif (Test-Path $rootManifest) {
    $manifestPath = $rootManifest
} else {
    throw "Manifest not found (looked for: $localManifest, $rootManifest)"
}

$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json

# New schema only
if (-not $manifest.repo -or -not $manifest.repo.owner -or -not $manifest.repo.name -or -not $manifest.repo.defaultBranch) {
    throw "Manifest is missing repo settings (repo.owner, repo.name, repo.defaultBranch)."
}
$repoOwner = $manifest.repo.owner
$repoName = $manifest.repo.name
$defaultBranch = $manifest.repo.defaultBranch

$project = $manifest.projects | Where-Object { $_.id -eq $ProjectId }
if (-not $project) { throw "Project '$ProjectId' not found in manifest." }

# Resolve version: prefer explicit manifest version, then versionFile in project dir
$projectDir = $project.projectDir
if (-not $projectDir) { throw "Project '$ProjectId' is missing 'projectDir' in manifest." }

$version = $null
if ($project.PSObject.Properties.Name -contains 'version' -and $project.version) {
    $version = [string]$project.version
} else {
    $versionFileName = $project.versionFile
    if ($versionFileName) {
        $versionFile = Join-Path (Join-Path $root $projectDir) $versionFileName
        if (Test-Path $versionFile) {
            $version = (Get-Content $versionFile -Raw).Trim()
        }
    }
}
if (-not $version) {
    $hint = 'Set "version" in the manifest for this project or add a version.txt in the project directory.'
    throw "Version is not defined for project '$ProjectId'. $hint"
}

# Construct tag and image URL (raw path in repo)
if (-not $project.tagFormat) { throw "Project '$ProjectId' is missing 'tagFormat' in manifest." }
$tag = $project.tagFormat.Replace('{version}', $version)

# Prefer GitHub raw URL format for images displayed in release notes
$imageRelPath = $null
if ($project.heroImage -and $project.heroImage.repoPath) { $imageRelPath = $project.heroImage.repoPath }
if (-not $imageRelPath) { throw "Project '$ProjectId' is missing heroImage.repoPath in manifest." }
$imageUrl = "https://raw.githubusercontent.com/$repoOwner/$repoName/$defaultBranch/$imageRelPath"

# Template: use path specified in manifest.template.releaseNotes or default to local/release-template.md
$templatePath = $null
if ($manifest.template -and $manifest.template.releaseNotes) {
    $templatePath = Join-Path $root $manifest.template.releaseNotes
} else {
    $templatePath = Join-Path $root 'local/release-template.md'
}
if (-not (Test-Path $templatePath)) { throw "Template not found: $templatePath" }
$template = Get-Content $templatePath -Raw

$releaseDate = (Get-Date).ToString('yyyy-MM-dd')
# Determine project display name with fallbacks
if ($project.PSObject.Properties.Name -contains 'displayName' -and $project.displayName) {
    $projectName = [string]$project.displayName
} elseif ($project.PSObject.Properties.Name -contains 'name' -and $project.name) {
    $projectName = [string]$project.name
} else {
    $projectName = [string]$project.id
}

# Simple variable replacement (literal string replace)
$content = $template
$replacements = @{
    '{{projectName}}' = $projectName
    '{{version}}'     = $version
    '{{tag}}'         = $tag
    '{{imageUrl}}'    = $imageUrl
    '{{releaseDate}}' = $releaseDate
}
foreach ($key in $replacements.Keys) {
    $content = $content.Replace($key, [string]$replacements[$key])
}

# Output path
if (-not $Output) {
    $draftsDir = if ($manifest.output -and $manifest.output.draftsDir) { $manifest.output.draftsDir } else { 'local/releases' }
    $draftsBase = Join-Path $root $draftsDir
    $Output = Join-Path (Join-Path $draftsBase $project.id) ("$tag.md")
}

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Output) | Out-Null
Set-Content -Path $Output -Value $content -Encoding UTF8

Write-Host "Release note generated: $Output"

if ($Publish) {
    Write-Host "Publishing GitHub release for tag '$tag'..."

    function Run-Cmd {
        param(
            [string]$Exe,
            [Parameter(ValueFromRemainingArguments=$true)]
            [string[]]$CmdArgs
        )
        $argsStr = ($CmdArgs | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
        Write-Host "> $Exe $argsStr"
        if ($DryRun) { return }
        & $Exe @CmdArgs
        if ($LASTEXITCODE -ne 0) { throw "$Exe exited with code $LASTEXITCODE" }
    }

    # Resolve executables (skip checks in DryRun)
    $gitExe = 'git'
    $ghExe = 'gh'
    if (-not $DryRun) {
        $gitCmd = Get-Command git -ErrorAction SilentlyContinue
        if (-not $gitCmd) { throw "git is not available in PATH. Install Git and retry." }
        $gitExe = $gitCmd.Source

        $ghCmd = Get-Command gh -ErrorAction SilentlyContinue
        if ($ghCmd) {
            $ghExe = $ghCmd.Source
        } else {
            $ghCandidates = @(
                (Join-Path $env:ProgramFiles 'GitHub CLI/gh.exe'),
                (Join-Path $env:LOCALAPPDATA 'Programs/GitHub CLI/gh.exe')
            )
            foreach ($cand in $ghCandidates) { if ($cand -and (Test-Path $cand)) { $ghExe = $cand; break } }
            if (-not (Test-Path $ghExe)) {
                throw 'gh (GitHub CLI) is not available in PATH. Install it or run: & "$env:ProgramFiles\GitHub CLI\gh.exe" auth login'
            }
        }
    }

    # Determine if release exists (only in real run)
    $releaseExists = $false
    if (-not $DryRun) {
        try { & $ghExe release view $tag | Out-Null; if ($LASTEXITCODE -eq 0) { $releaseExists = $true } } catch { $releaseExists = $false }
    }

    $title = "$projectName v$version"

    # Resolve desired ref commit
    $desiredSha = $Ref
    if (-not $DryRun) {
        $desiredSha = (& $gitExe rev-parse $Ref).Trim()
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($desiredSha)) {
            throw "Failed to resolve ref '$Ref' to a commit."
        }
    }

    # Ensure tag exists locally at desired ref
    $forcePush = $false
    if (-not $DryRun) {
        $existingTag = (& $gitExe tag --list $tag) | Where-Object { $_ -eq $tag }
        if (-not $existingTag) {
            Run-Cmd $gitExe 'tag' $tag $desiredSha
        } else {
            $existingSha = $null
            try { $existingSha = (& $gitExe rev-parse $tag).Trim() } catch { $existingSha = $null }
            if ($existingSha -and ($existingSha -ne $desiredSha)) {
                if ($ForceTag) {
                    Write-Host "Retagging '$tag' from $existingSha to $desiredSha ..."
                    Run-Cmd $gitExe 'tag' '-f' $tag $desiredSha
                    $forcePush = $true
                } else {
                    Write-Warning "Tag '$tag' already points to $existingSha, which differs from ref '$Ref' ($desiredSha). Use -ForceTag to retag, or specify -Ref 'main'."
                }
            } else {
                Write-Host "Tag '$tag' already exists at $existingSha."
            }
        }
    } else {
        Run-Cmd $gitExe 'tag' $tag $desiredSha
    }

    # Push tag (force if retagged)
    if ($forcePush) { Run-Cmd $gitExe 'push' '--force' 'origin' $tag } else { Run-Cmd $gitExe 'push' 'origin' $tag }

    # Optionally move/update a moving series tag (e.g., 'sailor-events') for easy filtering
    if ($SeriesTag -and $project.PSObject.Properties.Name -contains 'seriesTag' -and $project.seriesTag) {
        $series = [string]$project.seriesTag
        if (-not $DryRun) {
            $existingSeries = (& $gitExe tag --list $series) | Where-Object { $_ -eq $series }
            if (-not $existingSeries) {
                Run-Cmd $gitExe 'tag' $series $desiredSha
            } else {
                Run-Cmd $gitExe 'tag' '-f' $series $desiredSha
            }
        } else {
            Run-Cmd $gitExe 'tag' $series $desiredSha
        }
        Run-Cmd $gitExe 'push' '--force' 'origin' $series
    }

    if ($releaseExists -and -not $DryRun) {
           Run-Cmd $ghExe 'release' 'edit' $tag '--title' $title '--notes-file' $Output
    } else {
           Run-Cmd $ghExe 'release' 'create' $tag '--title' $title '--notes-file' $Output
    }

    # Gather assets based on manifest extensions
    $assetFiles = @()
    if ($project.assets -and $project.assets.extensions) {
        foreach ($ext in $project.assets.extensions) {
            if ([string]::IsNullOrWhiteSpace($ext)) { continue }
            $pattern = if ($ext.StartsWith('.')) { "*" + $ext } else { "*." + $ext }
            $found = Get-ChildItem -Path (Join-Path $root $projectDir) -Filter $pattern -File -ErrorAction SilentlyContinue
            if ($found) { $assetFiles += $found.FullName }
        }
    }

    if ($assetFiles.Count -gt 0) {
        Write-Host ("Uploading assets (" + ($assetFiles -join ', ') + ")")
        Run-Cmd $ghExe 'release' 'upload' $tag @assetFiles '--clobber'
    } else {
        Write-Warning "No assets found in '$projectDir' matching configured extensions. Skipping upload."
    }

    # Optionally move/update a per-app latest tag and create/update a matching release with stable asset name
    if ($Latest) {
        $latestTagName = $null
        if ($project.PSObject.Properties.Name -contains 'latestTag' -and $project.latestTag) {
            $latestTagName = [string]$project.latestTag
        } else {
            $latestTagName = [string]("{0}-latest" -f $project.id)
        }

        # Create or force-update the lightweight tag locally
        if (-not $DryRun) {
            $existingLatest = (& $gitExe tag --list $latestTagName) | Where-Object { $_ -eq $latestTagName }
            if (-not $existingLatest) {
                Run-Cmd $gitExe 'tag' $latestTagName $desiredSha
            } else {
                Run-Cmd $gitExe 'tag' '-f' $latestTagName $desiredSha
            }
        } else {
            Run-Cmd $gitExe 'tag' $latestTagName $desiredSha
        }
        Run-Cmd $gitExe 'push' '--force' 'origin' $latestTagName

        # Ensure a GitHub Release exists for the latest tag (so assets have a stable URL)
        $latestReleaseExists = $false
        if (-not $DryRun) {
            try { & $ghExe release view $latestTagName | Out-Null; if ($LASTEXITCODE -eq 0) { $latestReleaseExists = $true } } catch { $latestReleaseExists = $false }
        }

    $latestTitle = "$projectName v$version"
        if ($latestReleaseExists -and -not $DryRun) {
            Run-Cmd $ghExe 'release' 'edit' $latestTagName '--title' $latestTitle '--notes-file' $Output
        } else {
            Run-Cmd $ghExe 'release' 'create' $latestTagName '--title' $latestTitle '--notes-file' $Output
        }

        # Upload assets to the latest release with a stable name when possible
        if ($assetFiles.Count -gt 0) {
            # Determine stable asset name default: <project.id><ext> for single-asset case
            $assetArgs = @()
            if ($assetFiles.Count -eq 1) {
                $ext = [System.IO.Path]::GetExtension($assetFiles[0])
                $stableName = $null
                if ($project.assets -and $project.assets.PSObject.Properties.Name -contains 'stableName' -and $project.assets.stableName) {
                    $stableName = [string]$project.assets.stableName
                } else {
                    $stableName = [string]("{0}{1}" -f $project.id, $ext)
                }
                $assetArgs += ("{0}#{1}" -f $assetFiles[0], $stableName)
            } else {
                # Multiple assets: upload with original names unless stable names are explicitly configured per file (not supported here)
                $assetArgs += $assetFiles
            }
            Run-Cmd $ghExe 'release' 'upload' $latestTagName @assetArgs '--clobber'
        } else {
            Write-Warning "No assets found to upload to latest release '$latestTagName'."
        }
    }

    Write-Host "Publish complete for '$tag'."
}
