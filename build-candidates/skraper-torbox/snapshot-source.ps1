#requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $AppRoot,
    [Parameter(Mandatory)] [string] $OutputDirectory
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = (Resolve-Path -LiteralPath $AppRoot).ProviderPath
$output = (Resolve-Path -LiteralPath $OutputDirectory).ProviderPath
if ($output.Equals($root, [StringComparison]::OrdinalIgnoreCase) -or
    $output.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Source evidence must be outside the source tree.'
}
$archivePath = Join-Path $output 'source-before-build.zip'
$reportPath = Join-Path $output 'source-before-build.json'
if ((Test-Path -LiteralPath $archivePath) -or (Test-Path -LiteralPath $reportPath)) {
    throw 'Refusing to replace an existing source snapshot.'
}
. (Join-Path $root 'scripts/windows-common.ps1')

foreach ($directory in @((Get-Item -LiteralPath $root -Force)) + @(Get-ChildItem -LiteralPath $root -Recurse -Directory -Force)) {
    if ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Source snapshot contains a directory link.' }
}

$inventory = @(Get-ChildItem -LiteralPath $root -Recurse -File -Force | ForEach-Object {
    if ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Source snapshot contains a link.' }
    $relative = [IO.Path]::GetRelativePath($root, $_.FullName).Replace('\', '/')
    if ($relative -match '(?i)(^|/)(\.git|\.dart_tool|build|dist|ephemeral|\.plugin_symlinks)/' -or
        $relative -match '(?i)(\.dpapi|\.pem|\.pfx|\.p12|\.key)$|screenscraper-build-private') {
        throw "Unexpected private/generated source input: $relative"
    }
    [ordered]@{
        path = $relative
        bytes = $_.Length
        sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
})

# Retain the actual Windows ordering used by the unchanged build helper.
$paths = @('pubspec.yaml', 'pubspec.lock', 'LICENSE')
foreach ($folder in @('lib', 'assets', 'windows', 'patches', 'native', 'config')) {
    $base = Join-Path $root $folder
    if ($folder -eq 'config' -and -not (Test-Path -LiteralPath $base -PathType Container)) { continue }
    $paths += @(Get-ChildItem -LiteralPath $base -Recurse -File | Where-Object {
        $_.FullName -notmatch '[\\/]ephemeral[\\/]' -and $_.FullName -notmatch '[\\/]\.plugin_symlinks[\\/]'
    } | ForEach-Object { $_.FullName.Substring($root.Length + 1).Replace('\', '/') })
}
$rows = @($paths | Sort-Object -Unique | ForEach-Object {
    "$_ $((Get-FileHash -LiteralPath (Join-Path $root $_) -Algorithm SHA256).Hash.ToLowerInvariant())"
})
$rowHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
    [Text.Encoding]::UTF8.GetBytes(($rows -join "`n")))).ToLowerInvariant()
$sourceHash = Get-SourceFingerprint
if ($sourceHash -cne $rowHash) { throw 'Source row inventory does not match the build helper.' }

[IO.Compression.ZipFile]::CreateFromDirectory($root, $archivePath, [IO.Compression.CompressionLevel]::Optimal, $true)
$report = [ordered]@{
    operatingSystem = [Environment]::OSVersion.Platform.ToString()
    sourceRoot = [IO.Path]::GetFileName($root)
    sourceSha256 = $sourceHash
    archiveSha256 = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    fileCount = $inventory.Count
    files = $inventory
    fingerprintRows = $rows
}
[IO.File]::WriteAllText($reportPath, ($report | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
Write-Host "Saved exact source bytes before the Windows build: $($inventory.Count) files; source SHA256 $sourceHash"
