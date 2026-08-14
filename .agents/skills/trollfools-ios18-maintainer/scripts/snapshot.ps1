param(
    [string]$RepoPath = '',
    [string]$ArtifactsPath = ''
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepoPath)) {
    $currentPath = (Get-Location).Path
    $detectedPath = & git -C $currentPath rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -eq 0 -and $detectedPath) {
        $RepoPath = $detectedPath.Trim()
    } else {
        $candidate = $PSScriptRoot
        1 .. 4 | ForEach-Object { $candidate = Split-Path -Parent $candidate }
        if (Test-Path -LiteralPath (Join-Path $candidate '.git')) {
            $RepoPath = $candidate
        }
    }
}

if ([string]::IsNullOrWhiteSpace($RepoPath) -or -not (Test-Path -LiteralPath (Join-Path $RepoPath '.git'))) {
    throw 'Git repository not found. Run from the repository or pass -RepoPath.'
}

$RepoPath = (Resolve-Path -LiteralPath $RepoPath).Path

Write-Output '=== Repository ==='
git -C $RepoPath status --short --branch
git -C $RepoPath remote -v

Write-Output "`n=== Recent Commits ==="
git -C $RepoPath log -10 --oneline --decorate

Write-Output "`n=== Version And Identity ==="
Get-Content -LiteralPath (Join-Path $RepoPath 'TrollFools\Version.xcconfig')
Get-Content -LiteralPath (Join-Path $RepoPath 'control')
Select-String -LiteralPath (Join-Path $RepoPath 'TrollFools.xcodeproj\project.pbxproj') -Pattern 'PRODUCT_BUNDLE_IDENTIFIER|CFBundleDisplayName' |
    Select-Object -First 8 Path, LineNumber, Line

Write-Output "`n=== Critical Helper ==="
$helper = Join-Path $RepoPath 'TrollFools\ct_bypass'
$helperItem = Get-Item -LiteralPath $helper
$helperHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $helper).Hash
Write-Output "Path: $($helperItem.FullName)"
Write-Output "Length: $($helperItem.Length)"
Write-Output "SHA256: $helperHash"

Write-Output "`n=== Latest Artifacts ==="
if ([string]::IsNullOrWhiteSpace($ArtifactsPath)) {
    Write-Output 'Not scanned. Pass -ArtifactsPath when artifact verification is needed.'
} elseif (Test-Path -LiteralPath $ArtifactsPath) {
    Get-ChildItem -LiteralPath $ArtifactsPath -Recurse -File |
        Where-Object { $_.Extension -in '.tipa', '.deb' } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 10 |
        ForEach-Object {
            $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash
            Write-Output "$($_.FullName) | $($_.Length) bytes | SHA256 $hash"
        }
} else {
    throw "Artifact directory not found: $ArtifactsPath"
}
