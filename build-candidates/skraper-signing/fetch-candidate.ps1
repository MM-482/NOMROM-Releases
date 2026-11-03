#requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $RequestPath,
    [Parameter(Mandatory)] [string] $WorkDirectory
)
. (Join-Path $PSScriptRoot 'signing-common.ps1')
$root = Assert-SigningWorkRoot $WorkDirectory
$review = Join-Path $root 'review'
[IO.Directory]::CreateDirectory($review) | Out-Null
$reportPath = Join-Path $review 'readiness.json'
Write-SigningJson $reportPath @{ status = 'verifying_candidate'; published = $false; liveFeedChanged = $false }
$handler = [Net.Http.HttpClientHandler]::new()
$handler.AllowAutoRedirect = $false
$client = [Net.Http.HttpClient]::new($handler)
$client.Timeout = [TimeSpan]::FromMinutes(8)
$client.DefaultRequestHeaders.UserAgent.ParseAdd('NOMROM-signing-preparation')
$phase = 'validate_request'

function Read-LimitedResponse([Net.Http.HttpResponseMessage] $Response, [long] $Limit) {
    if ($null -ne $Response.Content.Headers.ContentLength) {
        Assert-Signing ($Response.Content.Headers.ContentLength -le $Limit) 'API response exceeds its size limit.'
    }
    $stream = $Response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
    $memory = [IO.MemoryStream]::new()
    try {
        $buffer = [byte[]]::new(65536)
        while (($count = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            Assert-Signing ($memory.Length + $count -le $Limit) 'API response exceeds its size limit.'
            $memory.Write($buffer, 0, $count)
        }
        return ,$memory.ToArray()
    } finally { $memory.Dispose(); $stream.Dispose() }
}

function Get-GitHubJson([string] $Path, [long] $Limit = 8388608) {
    Assert-Signing ($Path.StartsWith('/repos/MM-482/NOMROM-Releases/')) 'Unexpected GitHub API path.'
    $message = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, 'https://api.github.com' + $Path)
    $message.Headers.Accept.ParseAdd('application/vnd.github+json')
    $message.Headers.Add('X-GitHub-Api-Version', '2022-11-28')
    $message.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $env:GITHUB_TOKEN)
    try {
        $response = $client.SendAsync($message, [Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        try {
            Assert-Signing ([int]$response.StatusCode -eq 200) 'GitHub could not return the requested candidate metadata.'
            $bytes = Read-LimitedResponse $response $Limit
            return ($script:SigningUtf8.GetString($bytes) | ConvertFrom-Json -AsHashtable)
        } finally { $response.Dispose() }
    } finally { $message.Dispose() }
}

function Save-CandidateArtifact([hashtable] $Request, [string] $Target) {
    $uri = [Uri]("https://api.github.com/repos/$($Request['repository'])/actions/artifacts/$($Request['artifact_id'])/zip")
    for ($redirect = 0; $redirect -le 5; $redirect++) {
        Assert-Signing ($uri.IsAbsoluteUri -and $uri.Scheme -ceq 'https' -and $uri.Port -eq 443 -and -not $uri.UserInfo -and -not $uri.Fragment -and $uri.HostNameType -eq [UriHostNameType]::Dns -and $uri.Host.Contains('.') -and -not $uri.Host.EndsWith('.local')) 'An artifact redirect is not a public HTTPS download.'
        $message = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, $uri)
        # Authorization is sent to the first fixed GitHub API request only.
        # Never forward the GitHub token to an artifact CDN or redirect target.
        if ($redirect -eq 0) {
            $message.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $env:GITHUB_TOKEN)
            $message.Headers.Add('X-GitHub-Api-Version', '2022-11-28')
            $message.Headers.Accept.ParseAdd('application/vnd.github+json')
        }
        try {
            $response = $client.SendAsync($message, [Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
            try {
                if ([int]$response.StatusCode -in @(301, 302, 303, 307, 308)) {
                    Assert-Signing ($null -ne $response.Headers.Location) 'Artifact redirect lacks a destination.'
                    $uri = [Uri]::new($uri, $response.Headers.Location)
                    continue
                }
                Assert-Signing ([int]$response.StatusCode -eq 200) 'The exact candidate artifact could not be downloaded.'
                if ($null -ne $response.Content.Headers.ContentLength) {
                    Assert-Signing ($response.Content.Headers.ContentLength -eq $Request['artifact_size_in_bytes']) 'Artifact response size differs from the reviewed size.'
                }
                $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
                try {
                    $outputStream = [IO.File]::Open($Target, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                    try {
                        $buffer = [byte[]]::new(65536)
                        $written = [long]0
                        while (($count = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                            $written += $count
                            Assert-Signing ($written -le $Request['artifact_size_in_bytes']) 'Artifact download exceeds the reviewed size.'
                            $outputStream.Write($buffer, 0, $count)
                        }
                        Assert-Signing ($written -eq $Request['artifact_size_in_bytes']) 'Artifact download ended at the wrong size.'
                    } finally { $outputStream.Dispose() }
                } finally { $stream.Dispose() }
                Assert-Signing ((Get-SigningHash $Target) -ceq $Request['artifact_sha256']) 'Artifact download SHA-256 differs from the reviewed digest.'
                return
            } finally { $response.Dispose() }
        } finally { $message.Dispose() }
    }
    throw 'Artifact download exceeded the permitted redirect count.'
}

try {
    $request = Read-SigningRequest $RequestPath
    Assert-Signing (-not [string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) 'Read-only GitHub Actions access is unavailable.'
    $prefix = "/repos/$($request['repository'])"
    $phase = 'verify_run_and_artifact'
    $run = Get-GitHubJson "$prefix/actions/runs/$($request['candidate_run_id'])/attempts/$($request['candidate_run_attempt'])"
    $artifact = Get-GitHubJson "$prefix/actions/artifacts/$($request['artifact_id'])"
    Assert-CandidateAssociation $request $run $artifact
    $jobs = Get-GitHubJson "$prefix/actions/runs/$($request['candidate_run_id'])/attempts/$($request['candidate_run_attempt'])/jobs?per_page=100"
    Assert-Signing ($jobs['total_count'] -eq 1 -and @($jobs['jobs']).Count -eq 1) 'Unexpected candidate job inventory.'
    $job = $jobs['jobs'][0]
    Assert-Signing ($job['status'] -ceq 'completed' -and $job['conclusion'] -ceq 'success' -and $job['run_id'] -eq $request['candidate_run_id']) 'The candidate Windows job did not pass.'
    foreach ($required in @('Verify and prepare source', 'Restore, test, compile and verify Windows release', 'Package and verify installer and portable ZIP', 'Verify native signed-update safeguards with synthetic fixtures', 'Run bounded native Windows smoke harness')) {
        $matchingSteps = @($job['steps'] | Where-Object { $_['name'] -ceq $required })
        Assert-Signing ($matchingSteps.Count -eq 1 -and $matchingSteps[0]['conclusion'] -ceq 'success') 'A required candidate validation step did not pass.'
    }
    Write-SigningJson (Join-Path $root 'candidate-run.json') $run
    Write-SigningJson (Join-Path $root 'candidate-artifact.json') $artifact
    Write-SigningJson (Join-Path $root 'candidate-jobs.json') $jobs
    $phase = 'download_exact_artifact'
    Save-CandidateArtifact $request (Join-Path $root 'candidate-artifact.zip')
    $phase = 'download_exact_source_inputs'
    $inputs = Join-Path $root 'source-inputs'
    [IO.Directory]::CreateDirectory($inputs) | Out-Null
    foreach ($name in $request['source_inputs'].Keys) {
        # Raw decoded blob bytes avoid Git checkout CRLF conversion of the patch.
        $file = Get-GitHubJson "$prefix/contents/$($request['source_input_directory'])/$($name)?ref=$($request['candidate_head_sha'])"
        Assert-Signing ($file['type'] -ceq 'file' -and $file['encoding'] -ceq 'base64' -and $file['size'] -gt 0 -and $file['size'] -le 4194304) 'Unexpected candidate source input.'
        $bytes = [Convert]::FromBase64String($file['content'])
        Assert-Signing ($bytes.Length -eq $file['size']) 'Candidate source input size differs from GitHub metadata.'
        $path = Join-Path $inputs $name
        [IO.File]::WriteAllBytes($path, $bytes)
        Assert-Signing ((Get-SigningHash $path) -ceq $request['source_inputs'][$name]) 'Candidate source input differs from its reviewed hash.'
    }
    Write-SigningJson (Join-Path $root 'state.json') @{
        phase = 'fetched'
        request_sha256 = Get-SigningHash $RequestPath
        candidate_run_id = $request['candidate_run_id']
        candidate_run_attempt = $request['candidate_run_attempt']
        candidate_head_sha = $request['candidate_head_sha']
        artifact_id = $request['artifact_id']
        artifact_sha256 = $request['artifact_sha256']
    }
    Write-SigningJson $reportPath @{
        status = 'candidate_fetched'
        published = $false
        liveFeedChanged = $false
        candidateRunUrl = $run['html_url']
        candidateRunAttempt = $request['candidate_run_attempt']
        candidateHeadSha = $request['candidate_head_sha']
        artifactId = $request['artifact_id']
        artifactSha256 = $request['artifact_sha256']
    }
    Write-Host 'Exact successful candidate run, artifact digest, and raw source inputs verified.'
} catch {
    Write-SigningJson $reportPath @{ status = 'candidate_verification_failed'; phase = $phase; published = $false; liveFeedChanged = $false }
    # Do not print HTTP exception objects: redirected artifact URLs are temporary credentials.
    throw "Candidate verification failed during $phase. No private signing key was available to this step and no feed was created."
} finally {
    $client.Dispose()
    $handler.Dispose()
}
