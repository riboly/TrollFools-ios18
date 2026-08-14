param(
    [string]$RepoPath = 'C:\GitHun\TrollFools-ios18',
    [string]$ArtifactsPath = (Join-Path ([Environment]::GetFolderPath('Desktop')) ('TrollFools' + [char]0x4E8C + [char]0x6539))
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath (Join-Path $RepoPath '.git'))) {
    throw "Git repository not found: $RepoPath"
}

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
if (Test-Path -LiteralPath $ArtifactsPath) {
    Get-ChildItem -LiteralPath $ArtifactsPath -Recurse -File |
        Where-Object { $_.Extension -in '.tipa', '.deb' } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 10 |
        ForEach-Object {
            $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash
            Write-Output "$($_.FullName) | $($_.Length) bytes | SHA256 $hash"
        }
}
