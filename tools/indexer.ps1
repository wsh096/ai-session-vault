# ==============================================================================
# AI Session Universal Vault - Metadata Indexer
# Extracts lightweight metadata from raw session logs into session_index.json
# ==============================================================================
[CmdletBinding()]
param (
    [string]$ConfigFile = "$PSScriptRoot\..\config.json"
)

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path $ConfigFile)) {
    $ConfigFile = "$repoRoot\config.example.json"
}

Write-Host ">>> Loading configuration from: $ConfigFile" -ForegroundColor Cyan
$config = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json

$outputIndexFile = Join-Path $repoRoot "session_index.json"
$sessionsList = [System.Collections.Generic.List[PSObject]]::new()

foreach ($target in $config.agentTargets) {
    if (-not $target.enabled) { continue }
    
    # Resolve environment variables in path
    $resolvedPath = [System.Environment]::ExpandEnvironmentVariables($target.path)
    if (-not (Test-Path $resolvedPath)) {
        Write-Host "  [-] Target path not found: $resolvedPath ($($target.name))" -ForegroundColor Gray
        continue
    }

    Write-Host "  [+] Scanning $($target.name) sessions in: $resolvedPath" -ForegroundColor Green
    $files = Get-ChildItem -Path $resolvedPath -Filter $target.sessionPattern -Recurse -File -ErrorAction SilentlyContinue

    Write-Host "      Found $($files.Count) session files. Indexing..." -ForegroundColor Yellow

    foreach ($f in $files) {
        $sessionId = $f.BaseName -replace "^rollout-", ""
        $relPath = $f.FullName.Substring($resolvedPath.Length).TrimStart("\", "/")
        
        # Estimate month archive name
        $yearMonth = if ($f.Directory.Name -match "^\d{2}$" -and $f.Directory.Parent.Name -match "^\d{4}$") {
            "$($f.Directory.Parent.Name)_$($f.Directory.Name)"
        } else {
            $f.LastWriteTime.ToString("yyyy_MM")
        }
        $archiveName = "$($target.name)_$yearMonth.zip"

        # Read first lines to extract project/cwd and first user prompt
        $cwd = ""
        $project = "Untitled"
        $firstPrompt = ""
        $firstTime = $f.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")

        try {
            $stream = [System.IO.File]::OpenText($f.FullName)
            $lineCount = 0
            while (-not $stream.EndOfStream -and $lineCount -lt 30) {
                $line = $stream.ReadLine()
                $lineCount++
                if (-not $line) { continue }

                # Check for timestamp
                if ($line -match '"timestamp":\s*"([^"]+)"') {
                    $ts = $Matches[1]
                    if ($ts -as [DateTime]) {
                        $firstTime = ([DateTime]$ts).ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss")
                    }
                }

                # Check for cwd
                if (-not $cwd -and $line -match '"cwd":\s*"([^"]+)"') {
                    $cwd = $Matches[1].Replace('\\', '/')
                    $project = Split-Path -Leaf $cwd
                }

                # Check for first user prompt
                if (-not $firstPrompt -and $line -match '"(text|content)":\s*"([^"]{5,300})"') {
                    $candidate = $Matches[2].Trim()
                    if ($candidate -notmatch "^\s*\{\s*\"" -and $candidate.Length -gt 5) {
                        $firstPrompt = $candidate
                    }
                }

                if ($cwd -and $firstPrompt) { break }
            }
            $stream.Close()
        } catch {}

        if (-not $firstPrompt) {
            $firstPrompt = "Session created in $project"
        }

        $sessionsList.Add([PSCustomObject]@{
            id      = $sessionId
            src     = $target.name
            project = $project
            date    = $firstTime
            cwd     = $cwd
            preview = $firstPrompt
            archive = $archiveName
            rel     = $relPath
        })
    }
}

# Sort descending by date
$sortedList = $sessionsList | Sort-Object -Property date -Descending
$sortedList | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $outputIndexFile -Encoding UTF8

Write-Host ">>> [SUCCESS] Indexed $($sortedList.Count) sessions to: $outputIndexFile" -ForegroundColor Green
