# ==============================================================================
# AI Session Universal Vault - Tiered Storage Archive Engine
# Compresses sessions older than threshold (default: 30 days) into monthly archives
# and syncs to cloud storage (Google Drive / S3 / R2) via rclone.
# ==============================================================================
[CmdletBinding()]
param (
    [int]$IdleDays = 30,
    [switch]$UploadToCloud,
    [string]$ConfigFile = "$PSScriptRoot\..\config.json"
)

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path $ConfigFile)) {
    $ConfigFile = "$repoRoot\config.example.json"
}

$config = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
if ($PSBoundParameters.ContainsKey('IdleDays')) {
    $thresholdDays = $IdleDays
} else {
    $thresholdDays = if ($config.idleDaysThreshold) { [int]$config.idleDaysThreshold } else { 30 }
}

$cutoffDate = (Get-Date).AddDays(-$thresholdDays)
$archivesDir = Join-Path $repoRoot "archives"
New-Item -ItemType Directory -Path $archivesDir -Force | Out-Null

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "    AI Session Vault - Tiered Archiving Engine            " -ForegroundColor Yellow
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "Idle Threshold: $thresholdDays days (Cutoff: $($cutoffDate.ToString('yyyy-MM-dd HH:mm:ss')))" -ForegroundColor Gray
Write-Host "Archives Path : $archivesDir" -ForegroundColor Gray
Write-Host ""

foreach ($target in $config.agentTargets) {
    if (-not $target.enabled) { continue }
    $resolvedPath = [System.Environment]::ExpandEnvironmentVariables($target.path)
    if (-not (Test-Path $resolvedPath)) { continue }

    Write-Host "[*] Evaluating $($target.name) sessions in: $resolvedPath" -ForegroundColor Cyan
    $files = Get-ChildItem -Path $resolvedPath -Filter $target.sessionPattern -Recurse -File -ErrorAction SilentlyContinue

    $idleFiles = $files | Where-Object { $_.LastWriteTime -lt $cutoffDate }
    Write-Host "    Found $($files.Count) total sessions, $($idleFiles.Count) are idle (> $thresholdDays days)." -ForegroundColor Yellow

    if ($idleFiles.Count -eq 0) { continue }

    # Group idle files by Year and Month
    $grouped = $idleFiles | Group-Object {
        if ($_.Directory.Name -match "^\d{2}$" -and $_.Directory.Parent.Name -match "^\d{4}$") {
            "$($_.Directory.Parent.Name)_$($_.Directory.Name)"
        } else {
            $_.LastWriteTime.ToString("yyyy_MM")
        }
    }

    foreach ($grp in $grouped) {
        $zipName = "$($target.name)_$($grp.Name).zip"
        $zipPath = Join-Path $archivesDir $zipName
        Write-Host "    -> Archiving $($grp.Count) files into $zipName ..." -ForegroundColor Green

        # Create temporary file list for tar or compress
        $tmpList = [System.IO.Path]::GetTempFileName()
        $relFiles = $grp.Group | ForEach-Object {
            $_.FullName.Substring($resolvedPath.Length).TrimStart("\", "/")
        }
        $relFiles | Set-Content -Path $tmpList -Encoding UTF8

        # Prefer native tar.exe (fastest on Windows/macOS/Linux)
        if (Get-Command tar -ErrorAction SilentlyContinue) {
            tar -cf $zipPath -C $resolvedPath -T $tmpList
        } else {
            Compress-Archive -Path ($grp.Group | Select-Object -ExpandProperty FullName) -DestinationPath $zipPath -Force
        }
        Remove-Item -Path $tmpList -Force -ErrorAction SilentlyContinue

        if (Test-Path $zipPath) {
            $sizeMB = [math]::Round((Get-Item $zipPath).Length / 1MB, 2)
            Write-Host "       [OK] Created $zipName ($sizeMB MB)" -ForegroundColor Green
        }
    }
}

# Re-index to update archive mappings
Write-Host "`n[*] Re-building session index..." -ForegroundColor Cyan
& "$PSScriptRoot\indexer.ps1" -ConfigFile $ConfigFile

# Cloud Upload
if ($UploadToCloud -or $config.cloudRemote) {
    $remote = $config.cloudRemote
    Write-Host "`n[*] Cloud Sync configured: $remote" -ForegroundColor Cyan
    if (Get-Command rclone -ErrorAction SilentlyContinue) {
        Write-Host "    Uploading archives to $remote/archives ..." -ForegroundColor Yellow
        rclone copy $archivesDir "$remote/archives" --transfers 4 --progress
        Write-Host "    Uploading session_index.json to $remote ..." -ForegroundColor Yellow
        rclone copy (Join-Path $repoRoot "session_index.json") $remote --progress
        Write-Host "    [SUCCESS] Cloud sync complete!" -ForegroundColor Green
    } else {
        Write-Host "    [!] rclone not found on PATH. Please upload '$archivesDir' manually." -ForegroundColor Yellow
    }
}

Write-Host "`n[COMPLETE] Archiving process finished." -ForegroundColor Green
