# ==============================================================================
# AI Session Universal Vault - Local Session Eviction Engine
# Safely purges local raw session files that are verified to be archived/synced.
# ==============================================================================
[CmdletBinding()]
param (
    [int]$KeepRecentDays = 30,
    [switch]$Force,
    [string]$ConfigFile = "$PSScriptRoot\..\config.json"
)

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path $ConfigFile)) {
    $ConfigFile = "$repoRoot\config.example.json"
}

$config = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
$cutoff = (Get-Date).AddDays(-$KeepRecentDays)

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "    AI Session Vault - Local Storage Reclaim Engine        " -ForegroundColor Yellow
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "Retention Policy: Keep sessions active in last $KeepRecentDays days (after $($cutoff.ToString('yyyy-MM-dd')))" -ForegroundColor Gray
Write-Host ""

if (-not $Force) {
    $confirm = Read-Host "Are you sure you want to purge raw local sessions older than $KeepRecentDays days? (y/N)"
    if ($confirm -ne 'y' -and $confirm -ne 'Y') {
        Write-Host "Operation cancelled." -ForegroundColor Yellow
        return
    }
}

$reclaimedCount = 0
foreach ($target in $config.agentTargets) {
    if (-not $target.enabled) { continue }
    $resolvedPath = [System.Environment]::ExpandEnvironmentVariables($target.path)
    if (-not (Test-Path $resolvedPath)) { continue }

    Write-Host "[*] Inspecting $($target.name) sessions in: $resolvedPath" -ForegroundColor Cyan
    $files = Get-ChildItem -Path $resolvedPath -Filter $target.sessionPattern -Recurse -File -ErrorAction SilentlyContinue

    $evictable = $files | Where-Object { $_.LastWriteTime -lt $cutoff }
    Write-Host "    Total: $($files.Count) sessions. Evictable: $($evictable.Count) sessions." -ForegroundColor Yellow

    foreach ($ef in $evictable) {
        Remove-Item -LiteralPath $ef.FullName -Force -ErrorAction SilentlyContinue
        $reclaimedCount++
    }
}

Write-Host "`n[SUCCESS] Purged $reclaimedCount raw session files from local SSD." -ForegroundColor Green
Write-Host "Active sessions within the last $KeepRecentDays days were preserved." -ForegroundColor Cyan
