#requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $RequestPath,
    [Parameter(Mandatory)] [string] $WorkDirectory
)
. (Join-Path $PSScriptRoot 'signing-common.ps1')
$root = Assert-SigningWorkRoot $WorkDirectory
$request = Read-SigningRequest $RequestPath
$state = Read-SigningState $root $RequestPath 'fetched'
$reportPath = Join-Path $root 'review/readiness.json'
$report = Read-SigningJson $reportPath
$phase = 'verify_inputs'
try {
    $run = Read-SigningJson (Join-Path $root 'candidate-run.json')
    $artifact = Read-SigningJson (Join-Path $root 'candidate-artifact.json')
    Assert-CandidateAssociation $request $run $artifact
    $outerZip = Join-Path $root 'candidate-artifact.zip'
    Assert-Signing ((Get-SigningHash $outerZip) -ceq $request['artifact_sha256']) 'Candidate artifact bytes changed after download.'
    $inputs = Join-Path $root 'source-inputs'
    foreach ($name in $request['source_inputs'].Keys) {
        Assert-Signing ((Get-SigningHash (Join-Path $inputs $name)) -ceq $request['source_inputs'][$name]) 'Reviewed source inputs changed.'
    }
    $manifest = Read-SigningJson (Join-Path $inputs 'candidate-manifest.json')
    Assert-Signing ($manifest['candidate_version'] -ceq $request['candidate_version'] -and $manifest['source_root'] -ceq 'NOMROM-Windows-Source' -and $manifest['base_archive_url'] -ceq $request['base_archive_url'] -and $manifest['base_archive_sha256'] -ceq $request['base_archive_sha256'] -and $manifest['patch_sha256'] -ceq $request['source_inputs']['candidate.patch']) 'The reviewed reconstruction inputs disagree.'
    $phase = 'reconstruct_source'
    $sourceOutput = Join-Path $env:RUNNER_TEMP ('nomrom-app-' + [guid]::NewGuid().ToString('N'))
    $app = & (Join-Path $inputs 'prepare-source.ps1') -Manifest (Join-Path $inputs 'candidate-manifest.json') -Patch (Join-Path $inputs 'candidate.patch') -OutputDirectory $sourceOutput
    Assert-Signing ($app -is [string] -and $app -ceq (Join-Path $sourceOutput 'NOMROM-Windows-Source')) 'Source preparation returned an unexpected directory.'
    Assert-TrustedSigningScripts $request $app

    $phase = 'read_verified_candidate_evidence'
    $extracted = Join-Path $root 'candidate'
    Expand-SigningArchive $outerZip $extracted @('packages', 'verification')
    $verification = Join-Path $extracted 'verification'
    $preparation = Read-SigningJson (Join-Path $verification 'preparation.json')
    Assert-Signing ($preparation['candidateVersion'] -ceq $request['candidate_version'] -and $preparation['baseArchiveUrl'] -ceq $request['base_archive_url'] -and $preparation['baseArchiveSha256'] -ceq $request['base_archive_sha256'] -and $preparation['patchSha256'] -ceq $request['source_inputs']['candidate.patch'] -and $preparation['allBaselineAndResultHashesVerified'] -eq $true -and $preparation['undeclaredSourceChanges'] -eq 0) 'Approved CI preparation does not match this reconstruction.'
    $build = Read-SigningJson (Join-Path $verification 'BUILD-INFO.json')
    Assert-Signing ($build['application'] -ceq 'NOMROM' -and $build['version'] -ceq $request['candidate_version'] -and $build['architecture'] -ceq 'x64' -and $build['entrypoint'] -ceq 'lib/main.dart' -and $build['flutter'] -ceq '3.47.7' -and $build['flutterRevision'] -ceq 'abaf9c523780a608bd46686fd5e53740a07077f8' -and $build['screenScraper']['configured'] -eq $false) 'Approved BUILD-INFO is not the intended production candidate.'
    $public = Assert-OriginalPublicConfiguration $request $app $build
    $smoke = Read-SigningJson (Join-Path $verification 'native-smoke.json')
    Assert-Signing ($smoke['passed'] -eq $true -and $smoke['operatingSystem'] -ceq 'windows') 'Approved native Windows smoke checks did not pass.'
    foreach ($check in @('sqliteFfi', 'secureStorageDummyRoundTrip', 'nativeSelectedVolumeSpace', 'nativeArchiveExtraction', 'productionHttpFullAndResume', 'temporaryDataCleanup')) {
        Assert-Signing ($smoke['checks'][$check]['passed'] -eq $true) 'A required native Windows smoke check is absent or failed.'
    }

    $phase = 'compare_windows_source_fingerprint'
    . (Join-Path $app 'scripts/windows-common.ps1')
    Assert-WindowsHost
    $fingerprint = Get-SourceFingerprint
    # Emit the exact existing helper's input rows before any build/payload files
    # are staged. No rebuild or line-ending substitution can conceal a mismatch.
    $paths = @('pubspec.yaml', 'pubspec.lock', 'LICENSE')
    foreach ($folder in @('lib', 'assets', 'windows', 'patches', 'native', 'config')) {
        $base = Join-Path $app $folder
        if ($folder -eq 'config' -and -not (Test-Path -LiteralPath $base -PathType Container)) { continue }
        $paths += @(Get-ChildItem -LiteralPath $base -Recurse -File | Where-Object {
            $_.FullName -notmatch '[\\/]ephemeral[\\/]' -and $_.FullName -notmatch '[\\/]\.plugin_symlinks[\\/]'
        } | ForEach-Object { $_.FullName.Substring($app.Length + 1).Replace('\', '/') })
    }
    $rows = @($paths | Sort-Object -Unique | ForEach-Object { "$_ $(Get-SigningHash (Join-Path $app $_))" })
    $rowBytes = $script:SigningUtf8.GetBytes(($rows -join [char]10))
    $rowHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($rowBytes)).ToLowerInvariant()
    Assert-Signing ($rowHash -ceq $fingerprint) 'Diagnostic fingerprint rows differ from the existing build helper.'
    $inventory = @(Get-ChildItem -LiteralPath $app -Recurse -File -Force | ForEach-Object {
        @{ path = [IO.Path]::GetRelativePath($app, $_.FullName).Replace('\', '/'); bytes = $_.Length; sha256 = Get-SigningHash $_.FullName }
    } | Sort-Object { $_['path'] })
    $gitAutoCrlf = @(& git -C $app config --show-origin --get core.autocrlf 2>&1 | ForEach-Object { $_.ToString() })
    $gitAutoCrlfExit = $LASTEXITCODE
    Assert-Signing ($gitAutoCrlfExit -in @(0, 1)) 'Could not record Git line-ending configuration.'
    $report['sourceFingerprint'] = @{
        windowsComputed = $fingerprint
        approvedBuild = $build['sourceSha256']
        inputRowEncoding = 'UTF-8; LF separator; no BOM or final newline'
        inputRowCount = $rows.Count
        culture = [Globalization.CultureInfo]::CurrentCulture.Name
        uiCulture = [Globalization.CultureInfo]::CurrentUICulture.Name
        operatingSystem = [Runtime.InteropServices.RuntimeInformation]::OSDescription
        osArchitecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
        powerShellVersion = $PSVersionTable.PSVersion.ToString()
        gitAutoCrlfOriginAndValue = $gitAutoCrlf
        gitAutoCrlfWasSet = ($gitAutoCrlfExit -eq 0)
        inputRows = $rows
        reconstructedFiles = $inventory
    }
    $report['sourcePreparation'] = @{
        candidateVersion = $request['candidate_version']
        baseArchiveUrl = $request['base_archive_url']
        baseArchiveSha256 = $request['base_archive_sha256']
        sourceInputSha256 = $request['source_inputs']
        fingerprintScriptSha256 = $request['trusted_signing_scripts']['scripts/windows-common.ps1']
        reconstructedFileCount = $inventory.Count
        originalRunPreparation = $preparation
        reconstructedPreparation = Read-SigningJson (Join-Path $sourceOutput 'preparation.json')
    }
    $report['auditWorkflow'] = @{
        repository = $env:GITHUB_REPOSITORY
        commit = $env:GITHUB_SHA
        ref = $env:GITHUB_REF
        runId = $env:GITHUB_RUN_ID
        runAttempt = $env:GITHUB_RUN_ATTEMPT
        mode = $request['mode']
    }
    $report['publicUpdate'] = $request['public_update']
    if ($request['mode'] -ceq 'audit') {
        $sourceName = 'NOMROM-' + ($request['candidate_version'] -split '\+')[0] + '-prebuild-source-audit.zip'
        $sourceZip = Join-Path $root ('review/' + $sourceName)
        Write-SigningSourceArchive $app $inventory $sourceZip
        $report['sourceArchive'] = @{
            name = $sourceName
            bytes = (Get-Item -LiteralPath $sourceZip).Length
            sha256 = Get-SigningHash $sourceZip
            sourceRoot = 'NOMROM-Windows-Source'
            fileCount = $inventory.Count
            purpose = 'Exact prebuild Windows reconstruction; audit evidence, not the final source distributable.'
        }
    }
    Write-SigningJson $reportPath $report
    Assert-Signing ($fingerprint -ceq $build['sourceSha256']) 'Windows reconstructed source fingerprint differs from the approved build. Inspect the recorded raw rows; no signing will occur.'
    if ($request['mode'] -ceq 'audit') {
        $report['status'] = 'source_audit_passed'
        $report['privateKeyAccessed'] = $false
        $report['packagesReverified'] = $false
        $report['published'] = $false
        $report['liveFeedChanged'] = $false
        Write-SigningJson $reportPath $report
        Write-Host 'Authoritative Windows source fingerprint matches the exact successful candidate. Audit-only mode: no package staging or signing step is enabled.'
        return
    }

    $phase = 'stage_immutable_packages'
    $version = ($request['candidate_version'] -split '\+')[0]
    $stem = "NOMROM-$version-windows-x64"
    $packageNames = @("$stem-setup.exe", "$stem-portable.zip", "$stem-SHA256.txt")
    $originalDirectory = Join-Path $extracted 'packages'
    $present = @(Get-ChildItem -LiteralPath $originalDirectory -Force)
    Assert-Signing ($present.Count -eq 3 -and @($present | Where-Object { $_.PSIsContainer -or $_.Name -cnotin $packageNames }).Count -eq 0) 'Candidate packages are not the exact installer, portable ZIP and checksum file.'
    $dist = Join-Path $app 'dist/windows'
    Assert-Signing (-not (Test-Path -LiteralPath $dist)) 'Reconstructed source unexpectedly contains a distribution folder.'
    [IO.Directory]::CreateDirectory($dist) | Out-Null
    $packages = @()
    foreach ($name in $packageNames) {
        $original = Join-Path $originalDirectory $name
        $hash = Get-SigningHash $original
        $size = (Get-Item -LiteralPath $original).Length
        Assert-Signing ($size -gt 0 -and $size -le 536870912) 'Candidate package has an invalid size.'
        $target = Join-Path $dist $name
        [IO.File]::Copy($original, $target, $false)
        Assert-Signing ((Get-SigningHash $target) -ceq $hash) 'Candidate package copy changed bytes.'
        (Get-Item -LiteralPath $original).IsReadOnly = $true
        (Get-Item -LiteralPath $target).IsReadOnly = $true
        $packages += @{ name = $name; original_path = $original; staged_path = $target; bytes = $size; sha256 = $hash }
    }
    $portableDirectory = Join-Path $root 'portable'
    Expand-SigningArchive (Join-Path $dist "$stem-portable.zip") $portableDirectory @('NOMROM')
    $payload = Join-Path $portableDirectory 'NOMROM'
    Assert-Signing ((Get-SigningHash (Join-Path $payload 'BUILD-INFO.json')) -ceq (Get-SigningHash (Join-Path $verification 'BUILD-INFO.json'))) 'Portable BUILD-INFO differs from approved CI evidence.'
    $release = Join-Path $app 'build/windows/x64/runner/Release'
    Assert-Signing (-not (Test-Path -LiteralPath $release)) 'Reconstructed source unexpectedly contains a release build.'
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($release)) | Out-Null
    [IO.Directory]::Move($payload, $release)

    $phase = 'existing_native_package_verification'
    # Existing verification treats the EXE/DLL payload as data; nothing is launched.
    & (Join-Path $app 'scripts/verify-windows.ps1') -ArtifactsDirectory $dist
    $state['packages'] = $packages
    Assert-SigningPackageBytes $state
    $notes = Join-Path $PSScriptRoot 'release-notes.txt'
    Assert-Signing ((Get-SigningHash $notes) -ceq $request['release_notes_sha256']) 'Release notes differ from the reviewed text.'
    $state['phase'] = 'verified'
    $state['app_root'] = $app
    $state['source_output'] = $sourceOutput
    $state['source_fingerprint'] = $fingerprint
    $state['build_info_sha256'] = Get-SigningHash (Join-Path $release 'BUILD-INFO.json')
    $state['notes_path'] = $notes
    $state['download_base_url'] = "https://github.com/$($request['repository'])/releases/download/v$version"
    Write-SigningJson (Join-Path $root 'state.json') $state
    $report['status'] = 'verified_unsigned'
    $report['candidateVersion'] = $request['candidate_version']
    $report['packages'] = @($packages | ForEach-Object { @{ name = $_['name']; bytes = $_['bytes']; sha256 = $_['sha256'] } })
    $report['downloadBaseUrl'] = $state['download_base_url']
    $report['privateKeyAccessed'] = $false
    Write-SigningJson $reportPath $report
    Write-Host 'Candidate source, native package verification, and original public updater configuration passed. Packages were not rebuilt.'
} catch {
    $report['status'] = 'candidate_preparation_failed'
    $report['phase'] = $phase
    $report['privateKeyAccessed'] = $false
    $report['published'] = $false
    $report['liveFeedChanged'] = $false
    Write-SigningJson $reportPath $report
    throw
}
