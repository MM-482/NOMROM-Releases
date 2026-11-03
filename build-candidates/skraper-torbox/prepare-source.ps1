#requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Manifest,
    [Parameter(Mandatory)] [string] $Patch,
    [Parameter(Mandatory)] [string] $OutputDirectory,
    # Optional verified local copy, used by the offline reconstruction test.
    [string] $ArchivePath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$utf8 = [Text.UTF8Encoding]::new($false, $true)

function Assert-Sha256([object] $Value, [string] $Name) {
    if ($Value -isnot [string] -or $Value -cnotmatch '^[a-f0-9]{64}$') {
        throw "$Name must be a lowercase SHA-256 digest."
    }
}

function Assert-RelativePath([string] $Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.Contains('\') -or
        $Path.StartsWith('/') -or $Path -match '[\x00-\x1f\x7f:<>"|?*]') {
        throw "Unsupported relative path: $Path"
    }
    foreach ($part in $Path.Split('/')) {
        if (-not $part -or $part -in @('.', '..') -or $part.EndsWith('.') -or
            $part.EndsWith(' ') -or $part -ieq '.git' -or
            $part -match '^(?i:con|prn|aux|nul|com[0-9]|lpt[0-9])(?:\.|$)') {
            throw "Unsafe path component in: $Path"
        }
    }
}

function Get-ContainedPath([string] $Root, [string] $Relative) {
    Assert-RelativePath $Relative
    $prefix = $Root.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $full = [IO.Path]::GetFullPath((Join-Path $Root $Relative))
    if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path escapes its permitted directory: $Relative"
    }
    return $full
}

function Assert-RegularFile([string] $Path) {
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Expected a regular file: $Path"
    }
}

function Get-NormalizedText([string] $Path) {
    Assert-RegularFile $Path
    $text = $utf8.GetString([IO.File]::ReadAllBytes($Path))
    if ($text.IndexOf([char]0) -ge 0) { throw "NUL byte in a declared text target: $Path" }
    # This matches candidate-manifest.json: CRLF -> LF only; retain BOM/lone CR.
    $bytes = $utf8.GetBytes($text.Replace("`r`n", "`n"))
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    return [pscustomobject]@{ Bytes = $bytes; Hash = $hash }
}

function Invoke-Git([string[]] $Arguments) {
    $result = @(& git @Arguments 2>&1)
    $code = $LASTEXITCODE
    if ($code -ne 0) { throw "Git failed with exit code ${code}: $($result -join "`n")" }
    return $result
}

$manifestPath = (Resolve-Path -LiteralPath $Manifest).ProviderPath
$patchPath = (Resolve-Path -LiteralPath $Patch).ProviderPath
Assert-RegularFile $manifestPath
Assert-RegularFile $patchPath
$data = $utf8.GetString([IO.File]::ReadAllBytes($manifestPath)) | ConvertFrom-Json -AsHashtable
foreach ($key in @('base_archive_url', 'base_archive_sha256', 'patch_sha256', 'source_root', 'changed_files', 'candidate_version')) {
    if (-not $data.ContainsKey($key)) { throw "Manifest is missing $key." }
}
Assert-Sha256 $data.base_archive_sha256 'base_archive_sha256'
Assert-Sha256 $data.patch_sha256 'patch_sha256'
if ($data.candidate_version -isnot [string] -or $data.candidate_version -notmatch '^\d+\.\d+\.\d+\+\d+$') {
    throw 'Manifest candidate_version is invalid.'
}
Assert-RelativePath $data.source_root
$baseUri = [Uri]$data.base_archive_url
if (-not $baseUri.IsAbsoluteUri -or $baseUri.Scheme -ne 'https' -or
    $baseUri.UserInfo -or $baseUri.Query -or $baseUri.Fragment) {
    throw 'The source archive must use an absolute HTTPS URL without credentials, query, or fragment.'
}
if ((Get-FileHash -LiteralPath $patchPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $data.patch_sha256) {
    throw 'Candidate patch SHA-256 differs from the manifest.'
}
$patchText = $utf8.GetString([IO.File]::ReadAllBytes($patchPath))
if ($patchText -match '(?m)^(?:deleted file mode|old mode|new mode|rename from|rename to|copy from|copy to|GIT binary patch|Binary files )' -or
    $patchText -match '(?m)^new file mode (?!100644\r?$)') {
    throw 'The candidate patch must contain regular UTF-8 file additions/modifications only.'
}

$targets = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
$targetNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
if ($data.changed_files -isnot [System.Collections.IList] -or $data.changed_files.Count -eq 0) {
    throw 'Manifest changed_files must be a nonempty array.'
}
foreach ($entry in $data.changed_files) {
    foreach ($key in @('path', 'base_normalized_sha256', 'result_normalized_sha256')) {
        if (-not $entry.ContainsKey($key)) { throw "A changed_files entry is missing $key." }
    }
    Assert-RelativePath $entry.path
    if ($entry.path -notmatch '^[A-Za-z0-9_./-]+$' -or -not $targetNames.Add($entry.path)) {
        throw "Unsupported or duplicate patch target: $($entry.path)"
    }
    if ($null -ne $entry.base_normalized_sha256) {
        Assert-Sha256 $entry.base_normalized_sha256 "Base hash for $($entry.path)"
    }
    Assert-Sha256 $entry.result_normalized_sha256 "Result hash for $($entry.path)"
    $targets.Add($entry.path, $entry)
}

if (-not $env:RUNNER_TEMP -or -not (Test-Path -LiteralPath $env:RUNNER_TEMP -PathType Container)) {
    throw 'RUNNER_TEMP must name an existing temporary directory.'
}
$runnerRoot = [IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd([IO.Path]::DirectorySeparatorChar)
if ((Get-Item -LiteralPath $runnerRoot -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
    throw 'RUNNER_TEMP cannot be a reparse point.'
}
$output = [IO.Path]::GetFullPath($OutputDirectory)
if (-not [IO.Path]::GetDirectoryName($output).Equals($runnerRoot, [StringComparison]::OrdinalIgnoreCase) -or
    [IO.Path]::GetFileName($output) -cnotmatch '^nomrom-app-[a-f0-9]{32}$') {
    throw 'OutputDirectory must be a new RUNNER_TEMP/nomrom-app-<32 lowercase hex GUID> directory.'
}
if (Test-Path -LiteralPath $output) { throw 'Refusing to reuse an existing output directory.' }
[IO.Directory]::CreateDirectory($output) | Out-Null
$appRoot = Get-ContainedPath $output $data.source_root
$downloaded = $false
try {
    if ($ArchivePath) {
        $archivePathToUse = (Resolve-Path -LiteralPath $ArchivePath).ProviderPath
        Assert-RegularFile $archivePathToUse
    } else {
        $archivePathToUse = Join-Path $output 'base-source.zip'
        $downloaded = $true
        Write-Host 'Downloading the pinned NOMROM source archive.'
        Invoke-WebRequest -Uri $baseUri -OutFile $archivePathToUse
    }
    if ((Get-FileHash -LiteralPath $archivePathToUse -Algorithm SHA256).Hash.ToLowerInvariant() -cne $data.base_archive_sha256) {
        throw 'Base source archive SHA-256 differs from the manifest.'
    }
    Write-Host 'Base archive and candidate patch SHA-256 verified.'

    $archive = [IO.Compression.ZipFile]::OpenRead($archivePathToUse)
    try {
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $totalBytes = [long]0
        if ($archive.Entries.Count -gt 20000) { throw 'Unexpected source archive entry count.' }
        # Validate every entry before writing any extracted file.
        foreach ($entry in $archive.Entries) {
            $name = $entry.FullName.TrimEnd('/')
            Assert-RelativePath $name
            if (-not $seen.Add($name)) { throw "Duplicate/aliased archive path: $name" }
            if ($name -cne $data.source_root -and -not $name.StartsWith($data.source_root + '/', [StringComparison]::Ordinal)) {
                throw "Archive entry is outside source_root: $name"
            }
            $type = ($entry.ExternalAttributes -shr 16) -band 0xf000
            if ($type -notin @(0, 0x4000, 0x8000) -or ($entry.ExternalAttributes -band 0x400)) {
                throw "Archive contains a link or unsupported file type: $name"
            }
            $totalBytes += $entry.Length
            if ($entry.Length -gt 268435456 -or $totalBytes -gt 536870912) { throw 'Unexpected source archive size.' }
            $null = Get-ContainedPath $output $name
        }
        foreach ($entry in $archive.Entries) {
            $name = $entry.FullName.TrimEnd('/')
            $destination = Get-ContainedPath $output $name
            if ($entry.FullName.EndsWith('/')) {
                [IO.Directory]::CreateDirectory($destination) | Out-Null
                continue
            }
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination)) | Out-Null
            $entryStream = $entry.Open()
            try {
                $outputStream = [IO.File]::Open($destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                try { $entryStream.CopyTo($outputStream) } finally { $outputStream.Dispose() }
            } finally { $entryStream.Dispose() }
        }
    } finally { $archive.Dispose() }
} finally {
    if ($downloaded -and (Test-Path -LiteralPath $archivePathToUse -PathType Leaf)) {
        Remove-Item -LiteralPath $archivePathToUse -Force
    }
}

$originalFiles = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
foreach ($file in Get-ChildItem -LiteralPath $appRoot -Recurse -File -Force) {
    Assert-RegularFile $file.FullName
    $relative = [IO.Path]::GetRelativePath($appRoot, $file.FullName).Replace('\', '/')
    $originalFiles.Add($relative, (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant())
}

# Git's parsed path list must equal the declared manifest, including additions.
$patchTargets = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$stats = @(Invoke-Git @('-C', $appRoot, 'apply', '--numstat', '--', $patchPath))
foreach ($line in $stats) {
    $fields = ([string]$line).Split("`t")
    if ($fields.Count -ne 3 -or $fields[0] -notmatch '^\d+$' -or $fields[1] -notmatch '^\d+$' -or
        -not $targets.ContainsKey($fields[2]) -or -not $patchTargets.Add($fields[2])) {
        throw "Unexpected or duplicate path in Git's patch inventory: $line"
    }
}
if ($patchTargets.Count -ne $targets.Count) { throw 'Patch paths do not exactly match changed_files.' }

# Validate all baseline targets before normalizing any file.
$normalized = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
foreach ($entry in $data.changed_files) {
    $path = Get-ContainedPath $appRoot $entry.path
    if ($null -eq $entry.base_normalized_sha256) {
        if (Test-Path -LiteralPath $path) { throw "New patch target already exists: $($entry.path)" }
    } else {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing baseline target: $($entry.path)" }
        $text = Get-NormalizedText $path
        if ($text.Hash -cne $entry.base_normalized_sha256) { throw "Baseline hash mismatch: $($entry.path)" }
        $normalized.Add($entry.path, $text.Bytes)
    }
}
foreach ($name in $normalized.Keys) {
    [IO.File]::WriteAllBytes((Get-ContainedPath $appRoot $name), $normalized[$name])
}
$null = Invoke-Git @('-C', $appRoot, 'apply', '--check', '--', $patchPath)
$null = Invoke-Git @('-C', $appRoot, 'apply', '--', $patchPath)

foreach ($entry in $data.changed_files) {
    $text = Get-NormalizedText (Get-ContainedPath $appRoot $entry.path)
    if ($text.Hash -cne $entry.result_normalized_sha256) { throw "Result hash mismatch: $($entry.path)" }
}
# Also prove that no undeclared source file was added, removed, or modified.
$resultFiles = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($file in Get-ChildItem -LiteralPath $appRoot -Recurse -File -Force) {
    Assert-RegularFile $file.FullName
    $relative = [IO.Path]::GetRelativePath($appRoot, $file.FullName).Replace('\', '/')
    $null = $resultFiles.Add($relative)
    if (-not $targets.ContainsKey($relative)) {
        if (-not $originalFiles.ContainsKey($relative) -or
            (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant() -cne $originalFiles[$relative]) {
            throw "Undeclared source change: $relative"
        }
    }
}
foreach ($relative in $originalFiles.Keys) {
    if (-not $resultFiles.Contains($relative)) { throw "Unexpected source deletion: $relative" }
}
$pubspec = $utf8.GetString([IO.File]::ReadAllBytes((Join-Path $appRoot 'pubspec.yaml')))
if ($pubspec -notmatch ('(?m)^version:\s*' + [regex]::Escape($data.candidate_version) + '\s*$')) {
    throw 'Prepared pubspec version does not match candidate_version.'
}
$proof = [ordered]@{
    candidateVersion = $data.candidate_version
    baseArchiveUrl = $baseUri.AbsoluteUri
    baseArchiveSha256 = $data.base_archive_sha256
    patchSha256 = $data.patch_sha256
    changedFileCount = $targets.Count
    normalizedText = 'Strict UTF-8; CRLF to LF only; BOM and lone CR preserved.'
    allBaselineAndResultHashesVerified = $true
    undeclaredSourceChanges = 0
    preparedUtc = [DateTime]::UtcNow.ToString('o')
}
[IO.File]::WriteAllText((Join-Path $output 'preparation.json'), ($proof | ConvertTo-Json), $utf8)
Write-Host "Prepared $($data.candidate_version): verified all $($targets.Count) declared file changes."
Write-Output $appRoot
