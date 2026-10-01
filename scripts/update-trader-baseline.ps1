[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^v?\d+\.\d+\.\d+$')]
    [string]$Version,

    [switch]$SkipDependencyInstall,
    [switch]$SkipReleaseGate,
    [switch]$SkipPackage,
    [switch]$PushCandidate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $false)]
        [string[]]$ArgumentList = @()
    )

    & $FilePath @ArgumentList
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed ($LASTEXITCODE): $FilePath $($ArgumentList -join ' ')"
    }
}

function Get-CheckedOutput {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $false)]
        [string[]]$ArgumentList = @()
    )

    $output = & $FilePath @ArgumentList
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed ($LASTEXITCODE): $FilePath $($ArgumentList -join ' ')"
    }
    return (($output | Out-String).Trim())
}

function Write-PipelineReport {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Report,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $directory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    $Report | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 -Path $Path
}

function Assert-CosignVersion {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $versionText = (& $Path version 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) {
        throw "cosign failed to run: $versionText"
    }
    if ($versionText -notmatch '(?m)(?:^|\s)v(\d+)\.(\d+)\.(\d+)(?:\s|$)') {
        throw "Unable to parse cosign version: $versionText"
    }

    $major = [int]$Matches[1]
    $minor = [int]$Matches[2]
    $patch = [int]$Matches[3]
    if (
        $major -lt 3 -or
        ($major -eq 3 -and $minor -lt 1) -or
        ($major -eq 3 -and $minor -eq 1 -and $patch -lt 3)
    ) {
        throw "Sigstore provenance verification requires cosign >= 3.1.3; got v$major.$minor.$patch."
    }

    return "v$major.$minor.$patch"
}

function Resolve-TraderCosign {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot
    )

    $configured = $env:LNWJUD_COSIGN_PATH
    if ($configured) {
        if (-not (Test-Path -LiteralPath $configured -PathType Leaf)) {
            throw "LNWJUD_COSIGN_PATH does not exist: $configured"
        }
        $resolved = (Resolve-Path -LiteralPath $configured).Path
        $version = Assert-CosignVersion -Path $resolved
        return [pscustomobject]@{
            Path = $resolved
            Source = 'environment'
            Version = $version
            Sha256 = (Get-FileHash -Algorithm SHA256 -Path $resolved).Hash.ToLowerInvariant()
        }
    }

    $pathCommand = Get-Command cosign -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $pathCommand) {
        $resolved = $pathCommand.Source
        $version = Assert-CosignVersion -Path $resolved
        return [pscustomobject]@{
            Path = $resolved
            Source = 'path'
            Version = $version
            Sha256 = (Get-FileHash -Algorithm SHA256 -Path $resolved).Hash.ToLowerInvariant()
        }
    }

    $expectedSha256 = '9fe59be0eca1271873ce019061335eb1ac419b7059202e797828467ddabe33be'
    $toolDir = Join-Path $RepoRoot '.local-artifacts\build-tools\cosign-v3.1.3'
    $target = Join-Path $toolDir 'cosign-windows-amd64.exe'
    New-Item -ItemType Directory -Force -Path $toolDir | Out-Null

    if (Test-Path -LiteralPath $target -PathType Leaf) {
        $existingSha256 = (Get-FileHash -Algorithm SHA256 -Path $target).Hash.ToLowerInvariant()
        if ($existingSha256 -eq $expectedSha256) {
            $version = Assert-CosignVersion -Path $target
            return [pscustomobject]@{
                Path = $target
                Source = 'pinned_cache'
                Version = $version
                Sha256 = $existingSha256
            }
        }
    }

    $download = "$target.download"
    Remove-Item -LiteralPath $download -Force -ErrorAction SilentlyContinue
    $url = 'https://github.com/sigstore/cosign/releases/download/v3.1.3/cosign-windows-amd64.exe'
    $downloaded = $false
    for ($attempt = 1; $attempt -le 4; $attempt++) {
        try {
            Invoke-WebRequest -Uri $url -OutFile $download -UseBasicParsing
            $downloaded = $true
            break
        }
        catch {
            if ($attempt -eq 4) {
                throw
            }
            Start-Sleep -Seconds (2 * $attempt)
        }
    }
    if (-not $downloaded) {
        throw 'Failed to download pinned cosign v3.1.3.'
    }

    $actualSha256 = (Get-FileHash -Algorithm SHA256 -Path $download).Hash.ToLowerInvariant()
    if ($actualSha256 -ne $expectedSha256) {
        Remove-Item -LiteralPath $download -Force -ErrorAction SilentlyContinue
        throw "cosign SHA-256 mismatch: expected $expectedSha256, got $actualSha256"
    }

    Move-Item -LiteralPath $download -Destination $target -Force
    $version = Assert-CosignVersion -Path $target
    return [pscustomobject]@{
        Path = $target
        Source = 'pinned_download'
        Version = $version
        Sha256 = $actualSha256
    }
}

$repoRoot = Get-CheckedOutput -FilePath 'git' -ArgumentList @('rev-parse', '--show-toplevel')
if (-not $repoRoot) {
    throw 'Run this script from inside an lnwjud Git worktree.'
}

Set-Location $repoRoot

$dirty = @(git status --porcelain)
if ($dirty.Count -ne 0) {
    throw 'Worktree must be clean before creating a patched candidate.'
}

$registryPath = Join-Path $PSScriptRoot 'trader-patch-stack.json'
if (-not (Test-Path $registryPath)) {
    throw "Patch registry not found: $registryPath"
}

$registry = Get-Content -Raw -Path $registryPath | ConvertFrom-Json
$diagnosticMode = $SkipDependencyInstall -or $SkipReleaseGate -or $SkipPackage
$versionTag = $Version
if (-not $versionTag.StartsWith('v')) {
    $versionTag = "v$versionTag"
}
$versionNumber = $versionTag.Substring(1)
$candidateBranch = "trader/patched-$versionTag"
$pipelineSourceBranch = ((& git branch --show-current) | Out-String).Trim()
$pipelineSourceHead = Get-CheckedOutput -FilePath 'git' -ArgumentList @('rev-parse', 'HEAD')
$reportRoot = Join-Path $repoRoot ".local-artifacts\trader-patch-pipeline\$versionTag"
$reportPath = Join-Path $reportRoot 'PIPELINE_REPORT.json'

$report = @{
    schemaVersion = 1
    state = 'STARTED'
    versionTag = $versionTag
    pipelineSourceBranch = $pipelineSourceBranch
    pipelineSourceHead = $pipelineSourceHead
    upstreamRepository = [string]$registry.upstreamRepository
    forkRepository = [string]$registry.forkRepository
    patchBranch = [string]$registry.patchBranch
    candidateBranch = $candidateBranch
    startedAtUtc = [DateTime]::UtcNow.ToString('o')
    patches = @()
    checks = @()
    artifacts = @()
}

try {
    $upstreamUrl = 'https://github.com/engasnm111/lnwjud.git'
    $forkUrl = 'https://github.com/kobv99/lnwjud.git'
    $remotes = @(git remote)

    if ($remotes -notcontains 'trader-upstream') {
        Invoke-Checked -FilePath 'git' -ArgumentList @('remote', 'add', 'trader-upstream', $upstreamUrl)
    }
    else {
        $configuredUpstream = Get-CheckedOutput -FilePath 'git' -ArgumentList @('remote', 'get-url', 'trader-upstream')
        if ($configuredUpstream -notmatch 'engasnm111/lnwjud(?:\.git)?$') {
            throw "Existing trader-upstream remote points somewhere else: $configuredUpstream"
        }
    }

    if ($remotes -notcontains 'trader-fork') {
        Invoke-Checked -FilePath 'git' -ArgumentList @('remote', 'add', 'trader-fork', $forkUrl)
    }
    else {
        $configuredFork = Get-CheckedOutput -FilePath 'git' -ArgumentList @('remote', 'get-url', 'trader-fork')
        if ($configuredFork -notmatch 'kobv99/lnwjud(?:\.git)?$') {
            throw "Existing trader-fork remote points somewhere else: $configuredFork"
        }
    }

    Invoke-Checked -FilePath 'git' -ArgumentList @('config', 'rerere.enabled', 'true')
    Invoke-Checked -FilePath 'git' -ArgumentList @('config', 'rerere.autoupdate', 'true')

    $gitUserName = ((& git config user.name 2>$null) | Out-String).Trim()
    if (-not $gitUserName) {
        Invoke-Checked -FilePath 'git' -ArgumentList @('config', 'user.name', 'Trader lnwjud Patch Pipeline')
    }

    $gitUserEmail = ((& git config user.email 2>$null) | Out-String).Trim()
    if (-not $gitUserEmail) {
        Invoke-Checked -FilePath 'git' -ArgumentList @('config', 'user.email', 'trader-lnwjud-pipeline@users.noreply.github.com')
    }

    Invoke-Checked -FilePath 'git' -ArgumentList @('fetch', '--prune', 'trader-fork', [string]$registry.patchBranch)
    $patchBranchRef = "refs/remotes/trader-fork/$([string]$registry.patchBranch)"
    Invoke-Checked -FilePath 'git' -ArgumentList @('rev-parse', '--verify', $patchBranchRef)

    $upstreamTagRef = "refs/trader-upstream-tags/$versionTag"
    $tagFetchRefspec = ('refs/tags/' + $versionTag + ':' + $upstreamTagRef)
    Invoke-Checked -FilePath 'git' -ArgumentList @('fetch', '--prune', 'trader-upstream', $tagFetchRefspec, '--force')

    $upstreamCommit = Get-CheckedOutput -FilePath 'git' -ArgumentList @('rev-parse', "$upstreamTagRef^{commit}")
    if (-not $upstreamCommit) {
        throw "Unable to resolve upstream tag $versionTag to a commit."
    }

    $report.upstreamCommit = $upstreamCommit

    $patchBaselineCommit = [string]$registry.originalBaseline.commit
    Invoke-Checked -FilePath 'git' -ArgumentList @('cat-file', '-e', "$patchBaselineCommit^{commit}")
    & git merge-base --is-ancestor $patchBaselineCommit $upstreamCommit
    if ($LASTEXITCODE -ne 0) {
        throw "Selected upstream $versionTag does not descend from the registered patch baseline $patchBaselineCommit."
    }
    $report.patchBaselineCommit = $patchBaselineCommit

    foreach ($patch in $registry.patches) {
        $registeredPatchSha = [string]$patch.commit
        Invoke-Checked -FilePath 'git' -ArgumentList @('cat-file', '-e', "$registeredPatchSha^{commit}")
        & git merge-base --is-ancestor $registeredPatchSha $patchBranchRef
        if ($LASTEXITCODE -ne 0) {
            throw "Registered patch $registeredPatchSha is not contained in $patchBranchRef."
        }
    }

    & git show-ref --verify --quiet "refs/heads/$candidateBranch"
    $candidateExists = $LASTEXITCODE -eq 0
    if ($candidateExists) {
        throw "Local candidate branch already exists: $candidateBranch. Review/delete it explicitly before retrying; the pipeline will not reset it automatically."
    }

    Invoke-Checked -FilePath 'git' -ArgumentList @('switch', '--detach', $upstreamCommit)
    Invoke-Checked -FilePath 'git' -ArgumentList @('switch', '-c', $candidateBranch)

    $rootPackage = Get-Content -Raw -Path (Join-Path $repoRoot 'package.json') | ConvertFrom-Json
    if ([string]$rootPackage.version -ne $versionNumber) {
        throw "Upstream tag/package version mismatch: tag=$versionTag package=$($rootPackage.version)"
    }
    $report.upstreamPackageVersion = [string]$rootPackage.version

    foreach ($patch in $registry.patches) {
        $sha = [string]$patch.commit
        Invoke-Checked -FilePath 'git' -ArgumentList @('cat-file', '-e', "$sha^{commit}")

        & git cherry-pick -x $sha
        if ($LASTEXITCODE -ne 0) {
            $report.state = 'PATCH_CONFLICT'
            $report.failedPatch = @{
                id = [string]$patch.id
                commit = $sha
                subject = [string]$patch.subject
            }
            $report.gitStatus = @(git status --short)
            $report.nextAction = 'Inspect whether upstream supersedes this patch. Resolve only after review, then continue the cherry-pick. Do not install this candidate.'
            Write-PipelineReport -Report $report -Path $reportPath
            Write-Host "PATCH_CONFLICT=$($patch.id)"
            Write-Host "REPORT=$reportPath"
            exit 20
        }

        $report.patches += @{
            id = [string]$patch.id
            commit = $sha
            subject = [string]$patch.subject
            status = 'APPLIED'
        }
    }

    Invoke-Checked -FilePath 'git' -ArgumentList @('diff', '--check', "$upstreamCommit..HEAD")
    $report.checks += @{
        name = 'git_diff_check'
        status = 'PASS'
        range = "$upstreamCommit..HEAD"
    }

    if (-not $SkipDependencyInstall) {
        Invoke-Checked -FilePath 'corepack' -ArgumentList @('pnpm@10.15.0', 'install', '--frozen-lockfile')
        $report.checks += @{ name = 'pnpm_frozen_install'; status = 'PASS' }
    }

    $contractTests = @($registry.contractTests | ForEach-Object { [string]$_ })
    $vitestArgs = @('pnpm@10.15.0', 'exec', 'vitest', 'run')
    $vitestArgs += $contractTests
    $vitestArgs += @(
        '--exclude=.local-artifacts/**',
        '--exclude=.worktrees/**',
        '--exclude=.superpowers/**',
        '--exclude=.kilo/**'
    )
    Invoke-Checked -FilePath 'corepack' -ArgumentList $vitestArgs
    $report.checks += @{
        name = 'trader_patch_contract_tests'
        status = 'PASS'
        files = $contractTests
    }

    $cliFocused = $registry.focusedChecks.cliWorkspaceSkillRouting
    Invoke-Checked -FilePath 'corepack' -ArgumentList @(
        'pnpm@10.15.0', '--filter', [string]$cliFocused.package, 'exec', 'vitest', 'run',
        [string]$cliFocused.file, '-t', [string]$cliFocused.testName
    )
    $report.checks += @{
        name = 'stdio_workspace_skill_routing'
        status = 'PASS'
        file = [string]$cliFocused.file
        testName = [string]$cliFocused.testName
    }

    $desktopFocused = $registry.focusedChecks.desktopWorkspaceSkillRouting
    Invoke-Checked -FilePath 'corepack' -ArgumentList @(
        'pnpm@10.15.0', '--filter', [string]$desktopFocused.package, 'exec', 'vitest', 'run',
        '--config', [string]$desktopFocused.config,
        [string]$desktopFocused.file, '-t', [string]$desktopFocused.testName
    )
    $report.checks += @{
        name = 'desktop_workspace_skill_routing'
        status = 'PASS'
        file = [string]$desktopFocused.file
        testName = [string]$desktopFocused.testName
    }

    Invoke-Checked -FilePath 'corepack' -ArgumentList @('pnpm@10.15.0', 'typecheck')
    $report.checks += @{ name = 'typecheck'; status = 'PASS' }

    if (-not $SkipReleaseGate) {
        & powershell @(
            '-NoProfile',
            '-NonInteractive',
            '-ExecutionPolicy', 'Bypass',
            '-File', 'scripts/verify-release.ps1',
            '-SkipWindowsPackaging'
        )
        if ($LASTEXITCODE -ne 0) {
            $report.checks += @{
                name = 'upstream_release_gate_without_windows_package'
                status = 'FAILED'
                exitCode = $LASTEXITCODE
                disposition = 'REVIEW_REQUIRED'
            }
            Write-PipelineReport -Report $report -Path $reportPath
            throw "Upstream release gate failed with exit code $LASTEXITCODE. Review the exact failing test/log; the pipeline does not waive or auto-rerun release-gate failures."
        }
        $report.checks += @{
            name = 'upstream_release_gate_without_windows_package'
            status = 'PASS'
        }
    }
    else {
        $report.checks += @{
            name = 'upstream_release_gate_without_windows_package'
            status = 'SKIPPED_DIAGNOSTIC'
        }
    }

    Invoke-Checked -FilePath 'corepack' -ArgumentList @('pnpm@10.15.0', 'build')
    $report.checks += @{ name = 'build'; status = 'PASS' }

    if (-not $SkipPackage) {
        $cosign = Resolve-TraderCosign -RepoRoot $repoRoot
        $env:LNWJUD_COSIGN_PATH = [string]$cosign.Path
        $report.checks += @{
            name = 'cosign_provenance_verifier'
            status = 'PASS'
            source = [string]$cosign.Source
            version = [string]$cosign.Version
            path = [string]$cosign.Path
            sha256 = [string]$cosign.Sha256
        }

        Invoke-Checked -FilePath 'corepack' -ArgumentList @('pnpm@10.15.0', 'package:windows')
        $report.checks += @{ name = 'package_windows'; status = 'PASS' }

        $installerDir = Join-Path $repoRoot 'apps\desktop\dist\installers'
        if (-not (Test-Path $installerDir)) {
            throw "Windows package command completed but installer directory was not found: $installerDir"
        }

        $artifactFiles = @(
            Get-ChildItem -Path $installerDir -File |
                Where-Object {
                    $_.Name -match '^lnwjud-(Setup|Portable)-' -or
                    $_.Name -in @('SHA256SUMS.txt', 'PROVENANCE.json', 'latest.yml', 'portable.yml') -or
                    $_.Name -like '*.blockmap'
                } |
                Sort-Object Name
        )

        $requiredArtifacts = @(
            "lnwjud-Setup-$versionNumber.exe",
            "lnwjud-Portable-$versionNumber.exe",
            'SHA256SUMS.txt',
            'PROVENANCE.json'
        )
        $artifactNames = @($artifactFiles | ForEach-Object { $_.Name })
        foreach ($requiredArtifact in $requiredArtifacts) {
            if ($artifactNames -notcontains $requiredArtifact) {
                throw "Required packaged artifact is missing: $requiredArtifact"
            }
        }

        foreach ($artifact in $artifactFiles) {
            $hash = Get-FileHash -Algorithm SHA256 -Path $artifact.FullName
            $report.artifacts += @{
                name = $artifact.Name
                bytes = $artifact.Length
                sha256 = $hash.Hash.ToLowerInvariant()
            }
        }
    }

    $candidateHead = Get-CheckedOutput -FilePath 'git' -ArgumentList @('rev-parse', 'HEAD')
    $report.candidateHead = $candidateHead
    $report.state = if ($diagnosticMode) { 'PASS_DIAGNOSTIC' } else { 'PASS' }
    $report.completedAtUtc = [DateTime]::UtcNow.ToString('o')
    $report.installAuthorizedByPipeline = $false
    $report.promotionEligible = -not $diagnosticMode
    $report.promotionNote = if ($diagnosticMode) {
        'Diagnostic switches skipped one or more promotion gates. This candidate is not promotion-eligible.'
    }
    else {
        'All candidate gates passed. Installation still requires an explicit maintenance window: stop Tunnel, install this patched candidate, verify installed identity, restart Tunnel, and run post-install MCP/Klaus smoke checks.'
    }

    if ($PushCandidate) {
        Invoke-Checked -FilePath 'git' -ArgumentList @('push', '--set-upstream', 'trader-fork', $candidateBranch)
        $report.candidatePushed = $true
    }
    else {
        $report.candidatePushed = $false
    }

    Write-PipelineReport -Report $report -Path $reportPath

    if ($diagnosticMode) {
        Write-Host 'TRADER_LNWJUD_PATCH_PIPELINE=PASS_DIAGNOSTIC'
    }
    else {
        Write-Host 'TRADER_LNWJUD_PATCH_PIPELINE=PASS'
    }
    Write-Host "UPSTREAM_TAG=$versionTag"
    Write-Host "UPSTREAM_COMMIT=$upstreamCommit"
    Write-Host "CANDIDATE_BRANCH=$candidateBranch"
    Write-Host "CANDIDATE_HEAD=$candidateHead"
    Write-Host "REPORT=$reportPath"
    Write-Host 'INSTALL_AUTHORIZED=NO_EXPLICIT_PROMOTION_REQUIRED'
}
catch {
    $report.state = 'FAILED'
    $report.error = $_.Exception.Message
    $report.completedAtUtc = [DateTime]::UtcNow.ToString('o')
    $report.gitStatus = @(git status --short)
    $report.nextAction = 'Inspect the exact failed command/evidence. Do not install this candidate and do not stop the Tunnel solely because this pipeline failed.'
    Write-PipelineReport -Report $report -Path $reportPath
    Write-Host 'TRADER_LNWJUD_PATCH_PIPELINE=FAILED'
    Write-Host "REPORT=$reportPath"
    throw
}
