#requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $RequestPath,
    [Parameter(Mandatory)] [string] $WorkDirectory
)
. (Join-Path $PSScriptRoot 'signing-common.ps1')
$root = Assert-SigningWorkRoot $WorkDirectory
$request = Read-SigningRequest $RequestPath
Assert-Signing ($request['mode'] -ceq 'sign') 'Audit mode cannot open the publisher signing key.'
$state = Read-SigningState $root $RequestPath 'verified'
$reportPath = Join-Path $root 'review/readiness.json'
$report = Read-SigningJson $reportPath
$feedPath = Join-Path $root 'review/windows-stable.json'
$failure = 'signing_failed'
$feedWasAbsent = $false
$secretConfigured = $false
$signerInvoked = $false
try {
    Assert-Signing (-not (Test-Path -LiteralPath $feedPath)) 'Refusing to replace an existing prepared feed.'
    $feedWasAbsent = $true
    $secretConfigured = -not [string]::IsNullOrWhiteSpace($env:NOMROM_UPDATE_PRIVATE_KEY_XML)
    if (-not $secretConfigured) {
        $failure = 'unconfigured'
        throw 'The existing publisher signing secret is unavailable.'
    }

    # Only this step receives the existing secret. No transcript, environment
    # dump, replacement key, private-key file, export, or release API is used.
    $app = [IO.Path]::GetFullPath($state['app_root'])
    $sourceOutput = [IO.Path]::GetFullPath($state['source_output'])
    $runner = [IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd([IO.Path]::DirectorySeparatorChar)
    Assert-Signing ([IO.Path]::GetDirectoryName($sourceOutput).Equals($runner, [StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($sourceOutput) -cmatch '^nomrom-app-[a-f0-9]{32}$' -and $app -ceq (Join-Path $sourceOutput 'NOMROM-Windows-Source')) 'Unexpected reconstructed source location.'
    Assert-TrustedSigningScripts $request $app
    Assert-SigningPackageBytes $state
    Assert-Signing ((Get-SigningHash (Join-Path $root 'candidate-artifact.zip')) -ceq $request['artifact_sha256']) 'Pinned candidate artifact changed.'
    $buildPath = Join-Path $app 'build/windows/x64/runner/Release/BUILD-INFO.json'
    Assert-Signing ((Get-SigningHash $buildPath) -ceq $state['build_info_sha256']) 'Approved build metadata changed.'
    $build = Read-SigningJson $buildPath
    $public = Assert-OriginalPublicConfiguration $request $app $build
    Assert-Signing ((Get-SigningHash $state['notes_path']) -ceq $request['release_notes_sha256']) 'Reviewed release notes changed.'
    . (Join-Path $app 'scripts/windows-common.ps1')
    Assert-WindowsHost
    Assert-Signing ((Get-SourceFingerprint) -ceq $state['source_fingerprint'] -and $state['source_fingerprint'] -ceq $build['sourceSha256']) 'Approved source fingerprint changed.'
    $version = ($request['candidate_version'] -split '\+')[0]
    $expectedBase = "https://github.com/$($request['repository'])/releases/download/v$version"
    Assert-Signing ($state['download_base_url'] -ceq $expectedBase) 'Version-specific package URLs changed.'

    $signerInvoked = $true
    & (Join-Path $app 'scripts/new-windows-update-feed.ps1') -FromEnvironment -KeyId $public['NOMROM_UPDATE_KEY_ID'] -DownloadBaseUrl $expectedBase -NotesFile $state['notes_path'] -ArtifactsDirectory (Join-Path $app 'dist/windows') -OutputFile $feedPath
    Assert-SigningPackageBytes $state
    Assert-Signing ((Get-SigningHash (Join-Path $root 'candidate-artifact.zip')) -ceq $request['artifact_sha256']) 'The original candidate artifact changed while preparing the feed.'

    # Independently verify the public signature and every authorized package.
    # The verifier imports only the original compiled public key.
    $envelope = Read-SigningJson $feedPath 131072
    Assert-Signing ($envelope['algorithm'] -ceq 'rsa-pss-sha256' -and $envelope['keyId'] -ceq $public['NOMROM_UPDATE_KEY_ID']) 'Prepared feed uses an unexpected signature identity.'
    $payloadBytes = [Convert]::FromBase64String($envelope['payload'])
    $signature = [Convert]::FromBase64String($envelope['signature'])
    Assert-Signing ($payloadBytes.Length -gt 0 -and $payloadBytes.Length -le 65536) 'Prepared feed payload has an invalid size.'
    $blob = [Convert]::FromBase64String($public['NOMROM_UPDATE_PUBLIC_KEY'])
    Assert-Signing ($blob.Length -ge 24 -and [BitConverter]::ToUInt32($blob, 0) -eq 0x31415352) 'The original public key is not a Windows RSA public blob.'
    $bits = [BitConverter]::ToUInt32($blob, 4)
    $exponentLength = [BitConverter]::ToUInt32($blob, 8)
    $modulusLength = [BitConverter]::ToUInt32($blob, 12)
    Assert-Signing ($bits -ge 3072 -and $bits -le 8192 -and $exponentLength -ge 1 -and $exponentLength -le 8 -and $modulusLength * 8 -eq $bits -and $blob.Length -eq 24 + $exponentLength + $modulusLength -and [BitConverter]::ToUInt32($blob, 16) -eq 0 -and [BitConverter]::ToUInt32($blob, 20) -eq 0 -and $signature.Length -eq $modulusLength) 'The original public key or feed signature has an invalid shape.'
    $parameters = [Security.Cryptography.RSAParameters]::new()
    $parameters.Exponent = [byte[]]$blob[24..(23 + $exponentLength)]
    $parameters.Modulus = [byte[]]$blob[(24 + $exponentLength)..($blob.Length - 1)]
    $verifier = [Security.Cryptography.RSA]::Create()
    try {
        $verifier.ImportParameters($parameters)
        Assert-Signing ($verifier.VerifyData($payloadBytes, $signature, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pss)) 'Prepared feed failed verification with the original public key.'
    } finally { $verifier.Dispose() }
    $payload = $script:SigningUtf8.GetString($payloadBytes) | ConvertFrom-Json -AsHashtable
    Assert-Signing ($payload['schemaVersion'] -eq 1 -and $payload['appId'] -ceq 'com.markmateo.nomrom.Windows' -and $payload['platform'] -ceq 'windows' -and $payload['architecture'] -ceq 'x64' -and $payload['channel'] -ceq 'stable' -and $payload['version'] -ceq $version -and $payload['build'] -eq [int](($request['candidate_version'] -split '\+')[1])) 'Prepared feed identifies a different application or version.'
    $published = [DateTimeOffset]::Parse($payload['publishedAt'])
    $expires = [DateTimeOffset]::Parse($payload['expiresAt'])
    Assert-Signing ($published -le [DateTimeOffset]::UtcNow.AddMinutes(1) -and $expires -gt [DateTimeOffset]::UtcNow -and $expires -gt $published -and ($expires - $published).TotalDays -le 366) 'Prepared feed has invalid validity dates.'
    Assert-Signing ($payload['notes'] -ceq [IO.File]::ReadAllText($state['notes_path'])) 'Prepared release notes differ from the reviewed text.'
    foreach ($kind in @('installer', 'portable')) {
        $suffix = if ($kind -ceq 'installer') { 'setup.exe' } else { 'portable.zip' }
        $name = "NOMROM-$version-windows-x64-$suffix"
        $expected = @($state['packages'] | Where-Object { $_['name'] -ceq $name })
        Assert-Signing ($expected.Count -eq 1) 'Verified package inventory is incomplete.'
        $item = $payload['artifacts'][$kind]
        Assert-Signing ($item['fileName'] -ceq $name -and $item['url'] -ceq ($expectedBase + '/' + $name) -and $item['size'] -eq $expected[0]['bytes'] -and $item['sha256'] -ceq $expected[0]['sha256']) 'Prepared feed changed a verified package identity, URL, size, or hash.'
    }
    $report['status'] = 'signed_not_published'
    $report['publisherSecretConfigured'] = $true
    $report['privateKeyAccessed'] = $true
    $report['privateKeyAccessAttempted'] = $true
    $report['publicSignatureVerified'] = $true
    $report['packagesUnchanged'] = $true
    $report['published'] = $false
    $report['liveFeedChanged'] = $false
    $report['signingWorkflowCommit'] = $env:GITHUB_SHA
    $report['feed'] = @{
        name = 'windows-stable.json'
        sha256 = Get-SigningHash $feedPath
        bytes = (Get-Item -LiteralPath $feedPath).Length
        keyId = $public['NOMROM_UPDATE_KEY_ID']
        publicKeySha256 = $request['public_update']['public_key_sha256']
        expiresAt = $expires.ToString('o')
    }
    $report['remainingPublication'] = 'Review the exact prepared feed and original candidate packages, then separately publish the four assets on stable release v' + $version + ' and select it as Latest. This workflow cannot publish them.'
    Write-SigningJson $reportPath $report
    $state['phase'] = 'signed'
    Write-SigningJson (Join-Path $root 'state.json') $state
    Write-Host 'Signed feed prepared and publicly verified. The candidate packages are unchanged. No release or live update feed was published.'
} catch {
    # Only the owned, newly generated feed may be removed on failure.
    if ($feedWasAbsent -and (Test-Path -LiteralPath $feedPath -PathType Leaf)) { Remove-Item -LiteralPath $feedPath -Force }
    $report['status'] = $failure
    $report['publisherSecretConfigured'] = $secretConfigured
    $report['privateKeyAccessAttempted'] = $signerInvoked
    $report['privateKeyAccessed'] = if ($signerInvoked) { $null } else { $false }
    $report['published'] = $false
    $report['liveFeedChanged'] = $false
    Write-SigningJson $reportPath $report
    if ($failure -ceq 'unconfigured') {
        throw 'Signing is unconfigured: the existing NOMROM_UPDATE_PRIVATE_KEY_XML repository secret is unavailable. No replacement key was generated and no feed was created.'
    }
    # Never echo the original exception, environment, XML, or key material.
    throw 'Signed-feed preparation failed verification. No feed was retained and nothing was published. Review the preceding public preparation checks.'
} finally {
    [Environment]::SetEnvironmentVariable('NOMROM_UPDATE_PRIVATE_KEY_XML', $null, [EnvironmentVariableTarget]::Process)
}
