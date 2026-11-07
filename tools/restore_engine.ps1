# ==============================================================================
# AI Session Universal Vault - Transparent On-Demand Restore Engine
# Restores sessions by ID or Month. Automatically streams from cloud if missing locally.
# ==============================================================================
[CmdletBinding()]
param (
    [string]$SessionId = "",
    [string]$ArchiveName = "",
    [string]$ConfigFile = "$PSScriptRoot\..\config.json"
)

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path $ConfigFile)) {
    $ConfigFile = "$repoRoot\config.example.json"
}

$config = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
$archivesDir = Join-Path $repoRoot "archives"
$indexFile = Join-Path $repoRoot "session_index.json"
if (-not (Test-Path $indexFile)) {
    $indexFile = Join-Path $repoRoot "session_index.sample.json"
}

New-Item -ItemType Directory -Path $archivesDir -Force | Out-Null

function Ensure-ArchiveFile {
    param([string]$Name)
    $localPath = Join-Path $archivesDir $Name
    if (Test-Path $localPath) { return $localPath }

    $remote = $config.cloudRemote
    if (-not $remote) {
        Write-Host "[-] Archive '$Name' not found locally and no cloud remote configured." -ForegroundColor Red
        return $null
    }

    Write-Host "[!] Archive '$Name' not found locally. Streaming from cloud ($remote/archives/$Name)..." -ForegroundColor Cyan
    if (Get-Command rclone -ErrorAction SilentlyContinue) {
        rclone copy "$remote/archives/$Name" "$archivesDir" --progress
        if (Test-Path $localPath) {
            Write-Host "[OK] Successfully downloaded $Name from cloud." -ForegroundColor Green
            return $localPath
        }
    }
    Write-Host "[-] Failed to fetch archive from cloud." -ForegroundColor Red
    return $null
}

function Resolve-AgentDest {
    param([string]$Src)
    $match = $config.agentTargets | Where-Object { $_.name -eq $Src }
    if ($match) {
        return [System.Environment]::ExpandEnvironmentVariables($match.path)
    }
    return Join-Path $env:USERPROFILE ".codex\sessions"
}

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "    AI Session Vault - Universal Restore Engine           " -ForegroundColor Yellow
Write-Host "==========================================================" -ForegroundColor Cyan

# Interactive mode if no parameters
if (-not $SessionId -and -not $ArchiveName) {
    Write-Host "Choose restoration mode:" -ForegroundColor Cyan
    Write-Host "  1. Restore entire Month / Archive"
    Write-Host "  2. Search & Restore specific Session by ID or Project name"
    Write-Host "  Q. Quit"
    $mode = Read-Host "Select (1/2/Q)"

    if ($mode -eq "1") {
        $zips = Get-ChildItem -Path $archivesDir -Filter "*.zip"
        $names = [System.Collections.Generic.List[string]]::new()
        foreach ($z in $zips) { $names.Add($z.Name) }

        if ($names.Count -eq 0 -and $config.cloudRemote -and (Get-Command rclone -ErrorAction SilentlyContinue)) {
            Write-Host "Fetching available archives from cloud ($($config.cloudRemote))..." -ForegroundColor Gray
            $remoteFiles = rclone lsf "$($config.cloudRemote)/archives" 2>$null
            foreach ($rf in $remoteFiles) {
                $trimmed = $rf.TrimEnd("/").Trim()
                if ($trimmed -like "*.zip" -and -not $names.Contains($trimmed)) {
                    $names.Add($trimmed)
                }
            }
        }

        if ($names.Count -eq 0) {
            Write-Host "No archives found locally or in cloud." -ForegroundColor Yellow
            return
        }

        Write-Host "`nAvailable Archives:" -ForegroundColor Green
        for ($i = 0; $i -lt $names.Count; $i++) {
            $isLoc = Test-Path (Join-Path $archivesDir $names[$i])
            $tag = if ($isLoc) { "[Local SSD]" } else { "[Cloud Stream]" }
            Write-Host "  [$($i+1)] $($names[$i]) $tag"
        }

        $pick = Read-Host "Select archive number (1-$($names.Count))"
        $ArchiveName = $names[[int]$pick - 1]
    }
    elseif ($mode -eq "2") {
        $query = Read-Host "Enter Session ID or project name"
        $SessionId = $query.Trim()
    }
    else { return }
}

# Perform Archive Restore
if ($ArchiveName) {
    $zipPath = Ensure-ArchiveFile -Name $ArchiveName
    if (-not $zipPath) { return }

    $targetName = ($ArchiveName -split "_")[0]
    $dest = Resolve-AgentDest -Src $targetName
    New-Item -ItemType Directory -Path $dest -Force | Out-Null

    Write-Host "Restoring $ArchiveName into $dest ..." -ForegroundColor Yellow
    tar -xf $zipPath -C $dest
    Write-Host "[SUCCESS] Archive fully restored! AI Agent can now read past sessions." -ForegroundColor Green
    return
}

# Perform Single Session Restore
if ($SessionId) {
    if (-not (Test-Path $indexFile)) {
        Write-Host "Session index file not found: $indexFile" -ForegroundColor Red
        return
    }

    $index = Get-Content $indexFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $matched = $index | Where-Object { $_.id -like "*$SessionId*" -or $_.project -like "*$SessionId*" }

    if (-not $matched -or $matched.Count -eq 0) {
        Write-Host "No matching session found for: $SessionId" -ForegroundColor Yellow
        return
    }

    $target = if ($matched.Count -gt 1) {
        Write-Host "`nMultiple matches found:" -ForegroundColor Cyan
        for ($i = 0; $i -lt [math]::Min(10, $matched.Count); $i++) {
            $m = $matched[$i]
            Write-Host "  [$($i+1)] $($m.date) | $($m.src) | $($m.project) | ID: $($m.id.Substring(0,12))..."
        }
        $sel = Read-Host "Select match (1-$([math]::Min(10, $matched.Count)))"
        $matched[[int]$sel - 1]
    } else {
        $matched[0]
    }

    Write-Host "`nSelected Session: $($target.project) ($($target.date)) [ID: $($target.id)]" -ForegroundColor Green
    $zipPath = Ensure-ArchiveFile -Name $target.archive
    if (-not $zipPath) { return }

    $dest = Resolve-AgentDest -Src $target.src
    New-Item -ItemType Directory -Path $dest -Force | Out-Null

    Write-Host "Extracting $($target.rel) into $dest ..." -ForegroundColor Yellow
    tar -xf $zipPath -C $dest "$($target.rel)"
    Write-Host "[SUCCESS] Session successfully restored! You can now resume this conversation in $($target.src)." -ForegroundColor Green
}
