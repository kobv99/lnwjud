[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^v?\d+\.\d+\.\d+$')]
    [string]$Version,

    [switch]$SkipInstall,
    [switch]$SkipReleaseGate,
    [switch]$SkipPackage,
    [switch]$PushCandidate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $false)][string[]]$ArgumentList = @()
    )

    & $FilePath @ArgumentList
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed ($LASTEXITCODE): $FilePath $($ArgumentList -join ' ')"
    }
}

function Write-PipelineReport {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Report,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $directory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    $Report | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 -Path $Path
}

$repoRoot = (git rev-parse --show-toplevel).Trim()
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
$versionTag = if ($Version.StartsWith('v')) { $Version } else { "v$Version" }
$versionNumber = $versionTag.Substring(1)
$candidateBranch = "trader/patched-$versionTag"
$pipelineSourceBranch = (git branch --show-current).Trim()
$pipelineSourceHead = (git rev-parse HEAD).Trim()
$reportRoot = Join-Path $repoRoot ".local-artifacts\trader-patch-pipeline\$versionTag"
$reportPath = Join-Path $reportRoot 'PIPELINE_REPORT.json'

$report = @{
    schemaVersion = 1
    state = 'STARTED'
    versionTag = $versionTag
    pipelineSourceBranch = $pipelineSourceBranch
    pipelineSourceHead = $pipelineSourceHead
    upstreamRepository = [string]$registry.upstreamRepository
    patchBranch = [string]$registry.patchBranch
    candidateBranch = $candidateBranch
    startedAtUtc = [DateTime]::UtcNow.ToString('o')
    patches = @()
    checks = @()
    artifacts = @()
}

try {
    $upstreamUrl = 'https://github.com/engasnm111/lnwjud.git'
    $remotes = @(git remote)
    if ($remotes -notcontains 'upstream') {
        Invoke-Checked git @('remote', 'add', 'upstream', $upstreamUrl)
    }
    else {
        $configuredUpstream = (git remote get-url upstream).Trim()
        if ($configuredUpstream -notmatch 'engasnm111/lnwjud(?:\.git)?$') {
            throw "Existing upstream remote points somewhere else: $configuredUpstream"
        }
    }

    Invoke-Checked git @('config', 'rerere.enabled', 'true')
    Invoke-Checked git @('config', 'rerere.autoupdate', 'true')

    Invoke-Checked git @('fetch', '--prune', 'origin', [string]$registry.patchBranch)
    Invoke-Checked git @('fetch', '--prune', '--tags', 'upstream')

    Invoke-Checked git @('rev-parse', '--verify', "refs/tags/$versionTag")
    $upstreamCommit = (git rev-list -n 1 $versionTag).Trim()
    if (-not $upstreamCommit) {
        throw "Unable to resolve upstream tag $versionTag to a commit."
    }

    $report.upstreamCommit = $upstreamCommit

    git show-ref --verify --quiet "refs/heads/$candidateBranch"
    if ($LASTEXITCODE -eq 0) {
        throw "Local candidate branch already exists: $candidateBranch. Delete or rename it after reviewing the prior candidate; the pipeline will not reset it automatically."
    }

    Invoke-Checked git @('switch', '--detach', $upstreamCommit)
    Invoke-Checked git @('switch', '-c', $candidateBranch)

    foreach ($patch in $registry.patches) {
        $sha = [string]$patch.commit
        Invoke-Checked git @('cat-file', '-e', "$sha^{commit}")

        & git cherry-pick -x $sha
        if ($LASTEXITCODE -ne 0) {
            $report.state = 'PATCH_CONFLICT'
            $report.failedPatch = @{
                id = [string]$patch.id
                commit = $sha
                subject = [string]$patch.subject
            }
            $report.gitStatus = @(git status --short)
            $report.nextAction = 'Resolve the cherry-pick conflict manually, run git cherry-pick --continue, then rerun the remaining validation commands. Do not install this candidate.'
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

    Invoke-Checked git @('diff', '--check')
    $report.checks += @{ name = 'git_diff_check'; status = 'PASS' }

    if (-not $SkipInstall) {
        Invoke-Checked corepack @('pnpm@10.15.0', 'install', '--frozen-lockfile')
        $report.checks += @{ name = 'pnpm_frozen_install'; status = 'PASS' }
    }

    $contractTests = @($registry.contractTests | ForEach-Object { [string]$_ })
    $vitestArgs = @('pnpm@10.15.0', 'exec', 'vitest', 'run') + $contractTests + @(
        '--exclude=.local-artifacts/**',
        '--exclude=.worktrees/**',
        '--exclude=.superpowers/**',
        '--exclude=.kilo/**'
    )
    Invoke-Checked corepack $vitestArgs
    $report.checks += @{ name = 'trader_patch_contract_tests'; status = 'PASS'; files = $contractTests }

    Invoke-Checked corepack @('pnpm@10.15.0', 'typecheck')
    $report.checks += @{ name = 'typecheck'; status = 'PASS' }

    if (-not $SkipReleaseGate) {
        Invoke-Checked powershell @(
            '-NoProfile',
            '-NonInteractive',
            '-ExecutionPolicy', 'Bypass',
            '-File', 'scripts/verify-release.ps1',
            '-SkipWindowsPackaging'
        )
        $report.checks += @{ name = 'upstream_release_gate_without_windows_package'; status = 'PASS' }
    }

    Invoke-Checked corepack @('pnpm@10.15.0', 'build')
    $report.checks += @{ name = 'build'; status = 'PASS' }

    if (-not $SkipPackage) {
        Invoke-Checked corepack @('pnpm@10.15.0', 'package:windows')
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

        foreach ($artifact in $artifactFiles) {
            $hash = Get-FileHash -Algorithm SHA256 -Path $artifact.FullName
            $report.artifacts += @{
                name = $artifact.Name
                bytes = $artifact.Length
                sha256 = $hash.Hash.ToLowerInvariant()
            }
        }
    }

    $candidateHead = (git rev-parse HEAD).Trim()
    $report.candidateHead = $candidateHead
    $report.state = 'PASS'
    $report.completedAtUtc = [DateTime]::UtcNow.ToString('o')
    $report.installAuthorizedByPipeline = $false
    $report.promotionNote = 'PASS means candidate construction and validation succeeded. Installation still requires an explicit maintenance window: stop Tunnel, install this patched candidate, verify installed hash, restart Tunnel, and run post-install MCP/Klaus smoke checks.'

    if ($PushCandidate) {
        Invoke-Checked git @('push', '--set-upstream', 'origin', $candidateBranch)
        $report.candidatePushed = $true
    }
    else {
        $report.candidatePushed = $false
    }

    Write-PipelineReport -Report $report -Path $reportPath

    Write-Host "TRADER_LNWJUD_PATCH_PIPELINE=PASS"
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
