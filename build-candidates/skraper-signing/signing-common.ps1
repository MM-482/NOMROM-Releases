# Local preparation only. This file never publishes a release or opens a private key.
#requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:SigningUtf8 = [Text.UTF8Encoding]::new($false, $true)

function Assert-Signing([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw [InvalidOperationException]::new($Message) }
}

function Get-SigningHash([string] $Path) {
    $item = Get-Item -LiteralPath $Path -Force
    Assert-Signing (-not $item.PSIsContainer -and -not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) 'Expected a regular input file.'
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Read-SigningJson([string] $Path, [long] $Limit = 2097152) {
    $null = Get-SigningHash $Path
    Assert-Signing ((Get-Item -LiteralPath $Path).Length -le $Limit) 'JSON input exceeds its permitted size.'
    return ($script:SigningUtf8.GetString([IO.File]::ReadAllBytes($Path)) | ConvertFrom-Json -AsHashtable)
}

function Write-SigningJson([string] $Path, [object] $Value) {
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 12), $script:SigningUtf8)
}

function Assert-SigningHash([object] $Value) {
    Assert-Signing ($Value -is [string] -and $Value -cmatch '^[a-f0-9]{64}$') 'Expected a lowercase SHA-256 digest.'
}

function Read-SigningRequest([string] $Path, [switch] $AllowDisabled) {
    $request = Read-SigningJson $Path
    Assert-Signing ($request['schema_version'] -eq 1) 'Unsupported signing request schema.'
    Assert-Signing ($request['mode'] -cin @('audit', 'sign')) 'Preparation mode must be audit or sign.'
    Assert-Signing ($AllowDisabled -or $request['enabled'] -eq $true) 'This preparation request is disabled for local review.'
    Assert-Signing ($request['repository'] -ceq 'MM-482/NOMROM-Releases') 'Unexpected candidate repository.'
    Assert-Signing ($request['candidate_branch'] -ceq 'codex/nomrom-skraper-torbox-20261103') 'Unexpected candidate branch.'
    Assert-Signing ($request['candidate_workflow_path'] -ceq '.github/workflows/nomrom-candidate.yml') 'Unexpected candidate workflow.'
    Assert-Signing ($request['source_input_directory'] -ceq 'build-candidates/skraper-torbox') 'Unexpected candidate source input directory.'
    Assert-Signing ($request['candidate_head_sha'] -cmatch '^[a-f0-9]{40}$') 'An exact candidate commit is required.'
    Assert-Signing ($request['candidate_version'] -cmatch '^\d+\.\d+\.\d+\+\d+$') 'An exact candidate version and build are required.'
    foreach ($key in @('candidate_run_id', 'candidate_run_attempt', 'artifact_id', 'artifact_size_in_bytes')) {
        Assert-Signing ($request[$key] -is [long] -or $request[$key] -is [int]) 'Candidate identifiers and byte size must be integers.'
        Assert-Signing ($request[$key] -gt 0) 'Candidate identifiers and byte size must be positive.'
    }
    Assert-Signing ($request['artifact_size_in_bytes'] -le 1610612736) 'Candidate artifact exceeds the 1.5 GB limit.'
    foreach ($key in @('artifact_sha256', 'base_archive_sha256', 'release_notes_sha256')) {
        Assert-SigningHash $request[$key]
    }
    $expectedInputs = @('candidate-manifest.json', 'candidate.patch', 'prepare-source.ps1')
    Assert-Signing ($request['source_inputs'].Count -eq $expectedInputs.Count) 'Unexpected source input set.'
    foreach ($name in $expectedInputs) { Assert-SigningHash $request['source_inputs'][$name] }
    $scripts = @('scripts/new-windows-update-feed.ps1', 'scripts/windows-update-common.ps1', 'scripts/windows-common.ps1', 'scripts/verify-windows.ps1')
    Assert-Signing ($request['trusted_signing_scripts'].Count -eq $scripts.Count) 'Unexpected trusted signing script set.'
    foreach ($name in $scripts) { Assert-SigningHash $request['trusted_signing_scripts'][$name] }
    Assert-Signing ($request['public_update']['url'] -ceq 'https://github.com/MM-482/NOMROM-Releases/releases/latest/download/windows-stable.json') 'The existing public update URL must be preserved.'
    Assert-Signing ($request['public_update']['key_id'] -ceq 'nomrom-windows-2026') 'The existing publisher key identifier must be preserved.'
    Assert-Signing ($request['public_update']['algorithm'] -ceq 'rsa-pss-sha256' -and $request['public_update']['channel'] -ceq 'stable') 'Unexpected update protocol.'
    Assert-SigningHash $request['public_update']['public_key_sha256']
    return $request
}

function Assert-SigningWorkRoot([string] $Path) {
    Assert-Signing ([bool]$env:RUNNER_TEMP) 'RUNNER_TEMP is required.'
    $root = [IO.Path]::GetFullPath($Path)
    $parent = [IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd([IO.Path]::DirectorySeparatorChar)
    Assert-Signing ([IO.Path]::GetDirectoryName($root).Equals($parent, [StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($root) -cmatch '^nomrom-signing-[a-f0-9]{32}$') 'Signing work must use a fresh immediate RUNNER_TEMP child.'
    $item = Get-Item -LiteralPath $root -Force
    Assert-Signing ($item.PSIsContainer -and -not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) 'Signing work root must be a regular directory.'
    return $root
}

function Assert-SigningRelativePath([string] $Name) {
    Assert-Signing (-not [string]::IsNullOrWhiteSpace($Name) -and -not $Name.Contains('\') -and -not $Name.StartsWith('/') -and $Name -notmatch '[\x00-\x1f\x7f:<>"|?*]') 'An archive path is invalid.'
    foreach ($part in $Name.Split('/')) {
        Assert-Signing ($part -and $part -notin @('.', '..') -and -not $part.EndsWith('.') -and -not $part.EndsWith(' ') -and $part -ine '.git' -and $part -notmatch '^(?i:con|prn|aux|nul|com[0-9¹²³]|lpt[0-9¹²³])(?:\.|$)') 'An archive path has an unsafe Windows component.'
    }
}

function Get-SigningContainedPath([string] $Root, [string] $Relative) {
    Assert-SigningRelativePath $Relative
    $prefix = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $path = [IO.Path]::GetFullPath((Join-Path $Root $Relative))
    Assert-Signing ($path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) 'An archive path escapes its destination.'
    return $path
}

function Expand-SigningArchive([string] $Archive, [string] $Destination, [string[]] $AllowedRoots, [long] $Limit = 2147483648) {
    Assert-Signing (-not (Test-Path -LiteralPath $Destination)) 'Archive destination must be new.'
    $null = Get-SigningHash $Archive
    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $total = [long]0
        Assert-Signing ($zip.Entries.Count -gt 0 -and $zip.Entries.Count -le 30000) 'Unexpected archive entry count.'
        foreach ($entry in $zip.Entries) {
            $name = $entry.FullName.TrimEnd('/')
            Assert-SigningRelativePath $name
            Assert-Signing ($AllowedRoots -ccontains $name.Split('/')[0]) 'Unexpected archive root.'
            Assert-Signing ($seen.Add($name)) 'Archive has duplicate or aliased paths.'
            $type = ($entry.ExternalAttributes -shr 16) -band 0xf000
            Assert-Signing ($type -in @(0, 0x4000, 0x8000) -and -not ($entry.ExternalAttributes -band 0x400)) 'Archive links and special files are not permitted.'
            $total += $entry.Length
            Assert-Signing ($entry.Length -le 536870912 -and $total -le $Limit) 'Archive exceeds its extraction limits.'
            $null = Get-SigningContainedPath $Destination $name
        }
        [IO.Directory]::CreateDirectory($Destination) | Out-Null
        foreach ($entry in $zip.Entries) {
            $path = Get-SigningContainedPath $Destination $entry.FullName.TrimEnd('/')
            if ($entry.FullName.EndsWith('/')) {
                [IO.Directory]::CreateDirectory($path) | Out-Null
                continue
            }
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path)) | Out-Null
            $entryStream = $entry.Open()
            try {
                $fileStream = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                try {
                    $buffer = [byte[]]::new(65536)
                    $written = [long]0
                    while (($count = $entryStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                        $written += $count
                        Assert-Signing ($written -le $entry.Length) 'Archive entry length changed during extraction.'
                        $fileStream.Write($buffer, 0, $count)
                    }
                    Assert-Signing ($written -eq $entry.Length) 'Archive entry length does not match its metadata.'
                } finally { $fileStream.Dispose() }
            } finally { $entryStream.Dispose() }
        }
    } finally { $zip.Dispose() }
}

function Assert-CandidateAssociation([hashtable] $Request, [hashtable] $Run, [hashtable] $Artifact) {
    Assert-Signing ($Run['id'] -eq $Request['candidate_run_id'] -and $Run['run_attempt'] -eq $Request['candidate_run_attempt']) 'Candidate run or attempt differs from the reviewed request.'
    Assert-Signing ($Run['status'] -ceq 'completed' -and $Run['conclusion'] -ceq 'success') 'Candidate Windows run has not completed successfully.'
    Assert-Signing ($Run['head_sha'] -ceq $Request['candidate_head_sha'] -and $Run['head_branch'] -ceq $Request['candidate_branch'] -and $Run['path'] -ceq $Request['candidate_workflow_path']) 'Candidate commit, branch, or workflow differs from the reviewed request.'
    Assert-Signing ($Run['repository']['full_name'] -ceq $Request['repository'] -and $Run['head_repository']['full_name'] -ceq $Request['repository']) 'Fork or repository mismatch in candidate run.'
    Assert-Signing ($Run['html_url'] -ceq "https://github.com/$($Request['repository'])/actions/runs/$($Request['candidate_run_id'])") 'Unexpected candidate run URL.'
    $associated = $Artifact['workflow_run']
    Assert-Signing ($Artifact['id'] -eq $Request['artifact_id'] -and $Artifact['expired'] -eq $false -and $Artifact['name'] -ceq "NOMROM-windows-x64-candidate-$($Request['candidate_run_id'])") 'Candidate artifact identity is invalid or expired.'
    Assert-Signing ($associated['id'] -eq $Run['id'] -and $associated['head_sha'] -ceq $Run['head_sha'] -and $associated['head_branch'] -ceq $Run['head_branch'] -and $associated['repository_id'] -eq $Run['repository']['id'] -and $associated['head_repository_id'] -eq $Run['head_repository']['id']) 'Artifact is not associated with the exact approved run and repository.'
    Assert-Signing ($Artifact['url'] -ceq "https://api.github.com/repos/$($Request['repository'])/actions/artifacts/$($Request['artifact_id'])") 'Unexpected artifact API URL.'
    Assert-Signing ($Artifact['digest'] -ceq ('sha256:' + $Request['artifact_sha256']) -and $Artifact['size_in_bytes'] -eq $Request['artifact_size_in_bytes']) 'Artifact bytes differ from the reviewed digest or size.'
    $started = [DateTimeOffset]::Parse($Run['run_started_at'])
    $finished = [DateTimeOffset]::Parse($Run['updated_at'])
    $created = [DateTimeOffset]::Parse($Artifact['created_at'])
    Assert-Signing ($created -ge $started -and $created -le $finished) 'Artifact is not from the selected run attempt.'
}

function Assert-TrustedSigningScripts([hashtable] $Request, [string] $AppRoot) {
    foreach ($name in $Request['trusted_signing_scripts'].Keys) {
        Assert-Signing ((Get-SigningHash (Get-SigningContainedPath $AppRoot $name)) -ceq $Request['trusted_signing_scripts'][$name]) 'A trusted signing or verification script changed.'
    }
}

function Assert-OriginalPublicConfiguration([hashtable] $Request, [string] $AppRoot, [hashtable] $BuildInfo) {
    $public = Read-SigningJson (Join-Path $AppRoot 'config/windows-updates-public.json')
    Assert-Signing ($public.Count -eq 3) 'Unexpected public update configuration fields.'
    $publicBytes = [Convert]::FromBase64String($public['NOMROM_UPDATE_PUBLIC_KEY'])
    $digest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($publicBytes)).ToLowerInvariant()
    $expected = $Request['public_update']
    Assert-Signing ($public['NOMROM_UPDATE_FEED_URL'] -ceq $expected['url'] -and $public['NOMROM_UPDATE_KEY_ID'] -ceq $expected['key_id'] -and $digest -ceq $expected['public_key_sha256']) 'Original publisher public configuration changed.'
    $built = $BuildInfo['updateFeed']
    Assert-Signing ($built['configured'] -eq $true -and $built['url'] -ceq $expected['url'] -and $built['keyId'] -ceq $expected['key_id'] -and $built['publicKeySha256'] -ceq $expected['public_key_sha256'] -and $built['algorithm'] -ceq 'rsa-pss-sha256' -and $built['channel'] -ceq 'stable') 'The approved build does not contain the original public update configuration.'
    return $public
}

function Read-SigningState([string] $WorkDirectory, [string] $RequestPath, [string] $Phase) {
    $root = Assert-SigningWorkRoot $WorkDirectory
    $state = Read-SigningJson (Join-Path $root 'state.json')
    Assert-Signing ($state['request_sha256'] -ceq (Get-SigningHash $RequestPath) -and $state['phase'] -ceq $Phase) 'Signing state is not bound to this reviewed request or phase.'
    return $state
}

function Assert-SigningPackageBytes([hashtable] $State) {
    foreach ($package in $State['packages']) {
        Assert-Signing ((Get-SigningHash $package['original_path']) -ceq $package['sha256'] -and (Get-SigningHash $package['staged_path']) -ceq $package['sha256']) 'A candidate package changed after verification.'
        Assert-Signing ((Get-Item -LiteralPath $package['original_path']).Length -eq $package['bytes'] -and (Get-Item -LiteralPath $package['staged_path']).Length -eq $package['bytes']) 'A candidate package size changed after verification.'
    }
}

function Write-SigningSourceArchive([string] $AppRoot, [object[]] $Inventory, [string] $Destination) {
    Assert-Signing (-not (Test-Path -LiteralPath $Destination)) 'Source audit ZIP must be new.'
    # Explicit inventory includes dotfiles on every platform. Never use
    # Compress-Archive, whose hidden-file behavior changes the source set.
    $fileStream = [IO.File]::Open($Destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $zip = [IO.Compression.ZipArchive]::new($fileStream, [IO.Compression.ZipArchiveMode]::Create, $true)
        try {
            foreach ($file in $Inventory) {
                $path = Get-SigningContainedPath $AppRoot $file['path']
                Assert-Signing ((Get-SigningHash $path) -ceq $file['sha256'] -and (Get-Item -LiteralPath $path -Force).Length -eq $file['bytes']) 'Source changed after its audit inventory was recorded.'
                $entry = $zip.CreateEntry('NOMROM-Windows-Source/' + $file['path'], [IO.Compression.CompressionLevel]::Optimal)
                $entry.LastWriteTime = [DateTimeOffset]::new(1980, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
                $output = $entry.Open()
                $inputFile = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
                try { $inputFile.CopyTo($output) } finally { $inputFile.Dispose(); $output.Dispose() }
                Assert-Signing ((Get-SigningHash $path) -ceq $file['sha256']) 'Source changed while its audit ZIP was created.'
            }
        } finally { $zip.Dispose() }
    } finally { $fileStream.Dispose() }
}
