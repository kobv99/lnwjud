[CmdletBinding(DefaultParameterSetName = 'Latest')]
param(
    [Parameter(ParameterSetName = 'Exact', Mandatory = $true)]
    [ValidatePattern('^v?\d+\.\d+\.\d+$')]
    [string]$Version,

    [Parameter(ParameterSetName = 'Latest')]
    [switch]$Latest,

    [switch]$Force,
    [switch]$PushCandidate,
    [switch]$PlanOnly
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

function Get-CheckedOutput {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $false)][string[]]$ArgumentList = @()
    )
    $output = & $FilePath @ArgumentList
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed ($LASTEXITCODE): $FilePath $($ArgumentList -join ' ')"
    }
    return (($output | Out-String).Trim())
}

function Convert-ToSemVer {
    param([Parameter(Mandatory = $true)][string]$Value)
    $normalized = $Value.Trim()
    if ($normalized.StartsWith('v')) { $normalized = $normalized.Substring(1) }
    if ($normalized -notmatch '^(\d+)\.(\d+)\.(\d+)(?:\.\d+)?$') {
        throw "Not a stable semantic version: $Value"
    }
    return [version]::new([int]$Matches[1], [int]$Matches[2], [int]$Matches[3])
}

function Resolve-LatestStableTag {
    $remote = 'https://github.com/engasnm111/lnwjud.git'
    $lines = & git ls-remote --tags $remote
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to query upstream lnwjud tags.'
    }

    $candidates = foreach ($line in $lines) {
        if ($line -match 'refs/tags/(v(\d+)\.(\d+)\.(\d+))$') {
            [pscustomobject]@{
                Tag = $Matches[1]
                Version = [version]::new([int]$Matches[2], [int]$Matches[3], [int]$Matches[4])
            }
        }
    }

    $latest = $candidates | Sort-Object Version -Descending | Select-Object -First 1
    if ($null -eq $latest) {
        throw 'No stable vX.Y.Z upstream tag was found.'
    }
    return $latest
}

function Get-InstalledLnwjudVersion {
    $exe = Join-Path $env:LOCALAPPDATA 'Programs\lnwjud\lnwjud.exe'
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
        return [pscustomobject]@{
            Installed = $false
            ExePath = $exe
            VersionText = $null
            Version = $null
        }
    }
    $versionText = (Get-Item -LiteralPath $exe).VersionInfo.ProductVersion
    if (-not $versionText) {
        $versionText = (Get-Item -LiteralPath $exe).VersionInfo.FileVersion
    }
    return [pscustomobject]@{
        Installed = $true
        ExePath = $exe
        VersionText = $versionText
        Version = Convert-ToSemVer -Value $versionText
    }
}

$repoRoot = Get-CheckedOutput -FilePath 'git' -ArgumentList @('rev-parse', '--show-toplevel')
Set-Location $repoRoot

$sourceStatus = @(git status --porcelain)
if ($sourceStatus.Count -ne 0) {
    throw 'Management worktree must be clean before running the Trader update flow.'
}

$gitCommonDir = Get-CheckedOutput -FilePath 'git' -ArgumentList @('rev-parse', '--path-format=absolute', '--git-common-dir')
$commonRoot = Split-Path -Parent $gitCommonDir
$pipelineHead = Get-CheckedOutput -FilePath 'git' -ArgumentList @('rev-parse', 'HEAD')

$installed = Get-InstalledLnwjudVersion
$resolved = if ($PSCmdlet.ParameterSetName -eq 'Exact') {
    $tag = if ($Version.StartsWith('v')) { $Version } else { "v$Version" }
    [pscustomobject]@{ Tag = $tag; Version = Convert-ToSemVer -Value $tag }
}
else {
    Resolve-LatestStableTag
}

$targetTag = [string]$resolved.Tag
$targetVersion = [version]$resolved.Version
$updateRequired = -not $installed.Installed -or $targetVersion -gt $installed.Version
$currentVersionText = if ($installed.VersionText) { $installed.VersionText } else { 'NOT_INSTALLED' }

Write-Host "CURRENT_INSTALLED_VERSION=$currentVersionText"
Write-Host "LATEST_OR_SELECTED_UPSTREAM=$targetTag"
Write-Host "UPDATE_REQUIRED=$($updateRequired.ToString().ToUpperInvariant())"

if (-not $updateRequired -and -not $Force) {
    Write-Host 'TRADER_LNWJUD_UPDATE=NO_UPDATE'
    Write-Host 'NEXT_ACTION=Use -Force only when intentionally rebuilding the same or older exact version.'
    exit 0
}

$candidateStore = Join-Path $commonRoot ".trader-lnwjud\candidates\$targetTag"
$manifestPath = Join-Path $candidateStore 'CANDIDATE_MANIFEST.json'

if ($PlanOnly) {
    Write-Host 'TRADER_LNWJUD_UPDATE=PLAN_ONLY'
    Write-Host "PIPELINE_SOURCE_HEAD=$pipelineHead"
    Write-Host "CANDIDATE_STORE=$candidateStore"
    Write-Host "EXISTING_CANDIDATE=$((Test-Path -LiteralPath $manifestPath).ToString().ToUpperInvariant())"
    Write-Host 'INSTALL_AUTHORIZED=NO'
    exit 0
}

if (Test-Path -LiteralPath $manifestPath) {
    throw "A candidate manifest already exists for $targetTag at $manifestPath. Review or promote that candidate instead of overwriting it."
}

$timestamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
$buildWorktree = Join-Path $commonRoot ('.worktrees\TRADER_PATCH_BUILD_' + $targetTag + '_' + $timestamp)
$buildCreated = $false
$buildSucceeded = $false

try {
    Invoke-Checked -FilePath 'git' -ArgumentList @('worktree', 'add', '--detach', $buildWorktree, $pipelineHead)
    $buildCreated = $true

    $builder = Join-Path $buildWorktree 'scripts\update-trader-baseline.ps1'
    if (-not (Test-Path -LiteralPath $builder -PathType Leaf)) {
        throw "Candidate builder is missing from pipeline source HEAD: $builder"
    }

    $arguments = @(
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy', 'Bypass',
        '-File', $builder,
        '-Version', $targetTag
    )
    if ($PushCandidate) { $arguments += '-PushCandidate' }

    & powershell @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Patched candidate builder failed with exit code $LASTEXITCODE. Worktree preserved for review: $buildWorktree"
    }

    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Candidate builder returned success but shared manifest is missing: $manifestPath"
    }

    $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
    if ($manifest.promotionEligible -ne $true) {
        throw "Candidate exists but is not promotion-eligible: $manifestPath"
    }
    $buildSucceeded = $true

    Write-Host 'TRADER_LNWJUD_UPDATE=CANDIDATE_READY'
    Write-Host "TARGET_VERSION=$targetTag"
    Write-Host "CANDIDATE_HEAD=$($manifest.candidateHead)"
    Write-Host "CANDIDATE_MANIFEST=$manifestPath"
    Write-Host "SETUP_SHA256=$($manifest.setupSha256)"
    Write-Host 'INSTALL_AUTHORIZED=NO'
    Write-Host "NEXT_ACTION=.\scripts\Promote-TraderLnwjud.ps1 -Version $targetTag"
}
finally {
    if ($buildCreated -and $buildSucceeded) {
        & git worktree remove $buildWorktree
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Candidate build worktree was preserved and requires manual review/removal: $buildWorktree"
        }
    }
}
