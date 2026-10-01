[CmdletBinding(DefaultParameterSetName = 'Latest')]
param(
    [Parameter(ParameterSetName = 'Exact', Mandatory = $true)]
    [ValidatePattern('^v?\d+\.\d+\.\d+$')]
    [string]$Version,

    [Parameter(ParameterSetName = 'Latest')]
    [switch]$Latest,

    [switch]$PlanOnly,
    [switch]$Rollback,
    [switch]$ConfirmExternalSmoke,
    [string]$SmokeEvidence
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-CheckedOutput {
    param([string]$FilePath, [string[]]$ArgumentList = @())
    $output = & $FilePath @ArgumentList
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed ($LASTEXITCODE): $FilePath $($ArgumentList -join ' ')"
    }
    return (($output | Out-String).Trim())
}

function Convert-ToSemVer {
    param([string]$Value)
    $normalized = $Value.Trim()
    if ($normalized.StartsWith('v')) { $normalized = $normalized.Substring(1) }
    if ($normalized -notmatch '^(\d+)\.(\d+)\.(\d+)(?:\.\d+)?$') {
        throw "Not a stable semantic version: $Value"
    }
    return [version]::new([int]$Matches[1], [int]$Matches[2], [int]$Matches[3])
}

function Write-Json {
    param([object]$Value, [string]$Path)
    $directory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    $Value | ConvertTo-Json -Depth 12 | Set-Content -Encoding UTF8 -LiteralPath $Path
}

function Get-RuntimeState {
    $app = @(Get-Process -Name 'lnwjud' -ErrorAction SilentlyContinue)
    $tunnel = @(Get-Process -Name 'tunnel-client' -ErrorAction SilentlyContinue)
    return [pscustomobject]@{
        AppRunning = $app.Count -gt 0
        TunnelRunning = $tunnel.Count -gt 0
        AppProcessIds = @($app | ForEach-Object { $_.Id })
        TunnelProcessIds = @($tunnel | ForEach-Object { $_.Id })
    }
}

function Copy-Tree {
    param([string]$Source, [string]$Destination)
    if (-not (Test-Path -LiteralPath $Source -PathType Container)) { return }
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    & robocopy $Source $Destination /MIR /COPY:DAT /DCOPY:DAT /R:2 /W:1 /NFL /NDL /NJH /NJS /NP
    if ($LASTEXITCODE -ge 8) {
        throw "robocopy failed ($LASTEXITCODE): $Source -> $Destination"
    }
}

function Restore-Tree {
    param([string]$Backup, [string]$Destination)
    if (-not (Test-Path -LiteralPath $Backup -PathType Container)) { return }
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    & robocopy $Backup $Destination /MIR /COPY:DAT /DCOPY:DAT /R:2 /W:1 /NFL /NDL /NJH /NJS /NP
    if ($LASTEXITCODE -ge 8) {
        throw "rollback robocopy failed ($LASTEXITCODE): $Backup -> $Destination"
    }
}

function Get-InstalledVersion {
    param([string]$Exe)
    if (-not (Test-Path -LiteralPath $Exe -PathType Leaf)) { return $null }
    $value = (Get-Item -LiteralPath $Exe).VersionInfo.ProductVersion
    if (-not $value) { $value = (Get-Item -LiteralPath $Exe).VersionInfo.FileVersion }
    return $value
}

function Find-LatestCandidate {
    param([string]$CandidatesRoot)
    if (-not (Test-Path -LiteralPath $CandidatesRoot -PathType Container)) {
        throw "No candidate store exists: $CandidatesRoot"
    }
    $items = foreach ($dir in Get-ChildItem -LiteralPath $CandidatesRoot -Directory) {
        if ($dir.Name -notmatch '^v\d+\.\d+\.\d+$') { continue }
        $manifestPath = Join-Path $dir.FullName 'CANDIDATE_MANIFEST.json'
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { continue }
        $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
        if ($manifest.promotionEligible -ne $true) { continue }
        [pscustomobject]@{
            Tag = $dir.Name
            Version = Convert-ToSemVer -Value $dir.Name
            ManifestPath = $manifestPath
            Manifest = $manifest
        }
    }
    $latest = $items | Sort-Object Version -Descending | Select-Object -First 1
    if ($null -eq $latest) { throw 'No promotion-eligible Trader candidate is available.' }
    return $latest
}

function Assert-Candidate {
    param([object]$Manifest, [string]$ManifestPath)
    if ($Manifest.promotionEligible -ne $true) {
        throw "Candidate is not promotion-eligible: $ManifestPath"
    }
    $setup = [string]$Manifest.setupPath
    if (-not (Test-Path -LiteralPath $setup -PathType Leaf)) {
        throw "Candidate setup is missing: $setup"
    }
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $setup).Hash.ToLowerInvariant()
    if ($actual -ne ([string]$Manifest.setupSha256).ToLowerInvariant()) {
        throw "Candidate setup SHA-256 mismatch: expected $($Manifest.setupSha256), got $actual"
    }
}

function Invoke-Rollback {
    param(
        [string]$RollbackPath,
        [string]$InstallRoot,
        [string]$DataRoot,
        [string]$PendingPath
    )
    $runtime = Get-RuntimeState
    if ($runtime.AppRunning -or $runtime.TunnelRunning) {
        throw 'Rollback requires lnwjud and tunnel-client to be stopped.'
    }
    Restore-Tree -Backup (Join-Path $RollbackPath 'install') -Destination $InstallRoot
    Restore-Tree -Backup (Join-Path $RollbackPath 'data') -Destination $DataRoot
    if (Test-Path -LiteralPath $PendingPath) { Remove-Item -LiteralPath $PendingPath -Force }
    $oldExe = Join-Path $InstallRoot 'lnwjud.exe'
    if (Test-Path -LiteralPath $oldExe) { Start-Process -FilePath $oldExe | Out-Null }
    Write-Host 'TRADER_LNWJUD_ROLLBACK=PASS'
    Write-Host "ROLLBACK_PATH=$RollbackPath"
    Write-Host 'NEXT_ACTION=Start the Secure MCP Tunnel manually if it was previously in use.'
}

$repoRoot = Get-CheckedOutput -FilePath 'git' -ArgumentList @('rev-parse', '--show-toplevel')
$gitCommonDir = Get-CheckedOutput -FilePath 'git' -ArgumentList @('rev-parse', '--path-format=absolute', '--git-common-dir')
$commonRoot = Split-Path -Parent $gitCommonDir
$candidatesRoot = Join-Path $commonRoot '.trader-lnwjud\candidates'
$promotionRoot = Join-Path $commonRoot '.trader-lnwjud\promotion'
$pendingPath = Join-Path $promotionRoot 'PENDING.json'
$baselinePath = Join-Path $commonRoot '.trader-lnwjud\baseline\CURRENT.json'
$installRoot = Join-Path $env:LOCALAPPDATA 'Programs\lnwjud'
$installedExe = Join-Path $installRoot 'lnwjud.exe'
$dataRoot = Join-Path $env:APPDATA 'lnwjud'
$dataDb = Join-Path $dataRoot 'lnwjud.sqlite'

if ($Rollback) {
    $rollbackPath = $null
    if (Test-Path -LiteralPath $pendingPath) {
        $pendingRollback = Get-Content -Raw -LiteralPath $pendingPath | ConvertFrom-Json
        if ($pendingRollback.rollbackPath) { $rollbackPath = [string]$pendingRollback.rollbackPath }
    }
    if (-not $rollbackPath -and (Test-Path -LiteralPath $baselinePath)) {
        $baseline = Get-Content -Raw -LiteralPath $baselinePath | ConvertFrom-Json
        if ($baseline.rollbackPath) { $rollbackPath = [string]$baseline.rollbackPath }
    }
    if (-not $rollbackPath) { throw 'No rollback snapshot is registered.' }
    Invoke-Rollback -RollbackPath $rollbackPath -InstallRoot $installRoot -DataRoot $dataRoot -PendingPath $pendingPath
    exit 0
}

$selected = if ($PSCmdlet.ParameterSetName -eq 'Exact') {
    $tag = if ($Version.StartsWith('v')) { $Version } else { "v$Version" }
    $manifestPath = Join-Path (Join-Path $candidatesRoot $tag) 'CANDIDATE_MANIFEST.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Candidate manifest not found for $tag. Build it first with Update-TraderLnwjud.ps1."
    }
    [pscustomobject]@{
        Tag = $tag
        Version = Convert-ToSemVer -Value $tag
        ManifestPath = $manifestPath
        Manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
    }
}
else {
    Find-LatestCandidate -CandidatesRoot $candidatesRoot
}

$targetTag = [string]$selected.Tag
$targetVersionText = $targetTag.Substring(1)
$manifest = $selected.Manifest
Assert-Candidate -Manifest $manifest -ManifestPath $selected.ManifestPath

$runtime = Get-RuntimeState
$currentVersion = Get-InstalledVersion -Exe $installedExe

if ($PlanOnly) {
    Write-Host 'TRADER_LNWJUD_PROMOTION=PLAN_ONLY'
    Write-Host "CURRENT_INSTALLED_VERSION=$currentVersion"
    Write-Host "TARGET_VERSION=$targetTag"
    Write-Host "CANDIDATE_HEAD=$($manifest.candidateHead)"
    Write-Host "APP_RUNNING=$($runtime.AppRunning.ToString().ToUpperInvariant())"
    Write-Host "TUNNEL_RUNNING=$($runtime.TunnelRunning.ToString().ToUpperInvariant())"
    Write-Host 'INSTALL_AUTHORIZED_BY_BUILD_PIPELINE=NO'
    exit 0
}

$pending = if (Test-Path -LiteralPath $pendingPath) {
    Get-Content -Raw -LiteralPath $pendingPath | ConvertFrom-Json
}
else {
    [pscustomobject]@{
        schemaVersion = 1
        targetTag = $targetTag
        targetVersion = $targetVersionText
        candidateManifest = [string]$selected.ManifestPath
        candidateHead = [string]$manifest.candidateHead
        upstreamCommit = [string]$manifest.upstreamCommit
        setupPath = [string]$manifest.setupPath
        setupSha256 = [string]$manifest.setupSha256
        previousVersion = $currentVersion
        appWasRunning = $runtime.AppRunning
        tunnelWasRunning = $runtime.TunnelRunning
        stage = 'awaiting_shutdown'
        createdAtUtc = [DateTime]::UtcNow.ToString('o')
        rollbackPath = $null
    }
}

if ([string]$pending.targetTag -ne $targetTag) {
    throw "Another promotion is pending for $($pending.targetTag). Finish or rollback it before promoting $targetTag."
}

if (-not (Test-Path -LiteralPath $pendingPath)) {
    Write-Json -Value $pending -Path $pendingPath
}

if ($pending.stage -eq 'awaiting_external_smoke') {
    $runtime = Get-RuntimeState
    if (-not $runtime.AppRunning -or ($pending.tunnelWasRunning -eq $true -and -not $runtime.TunnelRunning)) {
        Write-Host 'TRADER_LNWJUD_PROMOTION=AWAITING_RUNTIME_RECONNECT'
        Write-Host "TARGET_VERSION=$targetTag"
        Write-Host 'ACTION=Open lnwjud and start the Secure MCP Tunnel if it was previously in use.'
        exit 0
    }

    $installedVersion = Get-InstalledVersion -Exe $installedExe
    if ((Convert-ToSemVer -Value $installedVersion) -ne (Convert-ToSemVer -Value $targetVersionText)) {
        throw "Installed version changed during external smoke verification: $installedVersion"
    }

    if (-not $ConfirmExternalSmoke) {
        Write-Host 'TRADER_LNWJUD_PROMOTION=AWAITING_EXTERNAL_SMOKE'
        Write-Host "TARGET_VERSION=$targetTag"
        Write-Host 'ACTION=Run the real Klaus/MCP contract and Durable Goal smoke through the reconnected runtime, then rerun with -ConfirmExternalSmoke -SmokeEvidence <evidence>.'
        exit 0
    }
    if ([string]::IsNullOrWhiteSpace($SmokeEvidence)) {
        throw '-ConfirmExternalSmoke requires non-empty -SmokeEvidence.'
    }

    $baseline = [pscustomobject]@{
        schemaVersion = 1
        version = $targetTag
        candidateHead = [string]$manifest.candidateHead
        upstreamCommit = [string]$manifest.upstreamCommit
        setupSha256 = [string]$manifest.setupSha256
        installedExeSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $installedExe).Hash.ToLowerInvariant()
        installedAppAsarSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $installRoot 'resources\app.asar')).Hash.ToLowerInvariant()
        rollbackPath = [string]$pending.rollbackPath
        externalSmokeEvidence = $SmokeEvidence
        promotedAtUtc = [DateTime]::UtcNow.ToString('o')
        updatePolicy = @{
            autoCheck = $true
            checkOnStartup = $true
            intervalMinutes = 30
            autoDownload = $false
        }
    }
    Write-Json -Value $baseline -Path $baselinePath
    $history = Join-Path $promotionRoot ('PROMOTED-' + $targetTag + '-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '.json')
    Write-Json -Value $pending -Path $history
    Remove-Item -LiteralPath $pendingPath -Force

    Write-Host 'TRADER_LNWJUD_PROMOTION=PASS'
    Write-Host "NEW_BASELINE=$targetTag"
    Write-Host "BASELINE_MANIFEST=$baselinePath"
    Write-Host 'AUTO_CHECK=ON'
    Write-Host 'AUTO_DOWNLOAD=OFF'
    exit 0
}

$runtime = Get-RuntimeState
if ($runtime.AppRunning -or $runtime.TunnelRunning) {
    Write-Host 'TRADER_LNWJUD_PROMOTION=AWAITING_SHUTDOWN'
    Write-Host "TARGET_VERSION=$targetTag"
    Write-Host "APP_RUNNING=$($runtime.AppRunning.ToString().ToUpperInvariant())"
    Write-Host "TUNNEL_RUNNING=$($runtime.TunnelRunning.ToString().ToUpperInvariant())"
    Write-Host 'ACTION=Stop the Secure MCP Tunnel and fully exit lnwjud, then rerun this same promotion command.'
    exit 0
}

if (-not $pending.rollbackPath) {
    $rollbackPath = Join-Path $commonRoot ('.trader-lnwjud\rollback\' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-to-' + $targetTag)
    Copy-Tree -Source $installRoot -Destination (Join-Path $rollbackPath 'install')
    Copy-Tree -Source $dataRoot -Destination (Join-Path $rollbackPath 'data')
    $pending.rollbackPath = $rollbackPath
    $pending.stage = 'backup_complete'
    Write-Json -Value $pending -Path $pendingPath
}

try {
    $installer = Start-Process -FilePath ([string]$manifest.setupPath) -ArgumentList @('/S') -Wait -PassThru
    if ($installer.ExitCode -ne 0) {
        throw "Installer exited with code $($installer.ExitCode)"
    }

    $installedVersion = Get-InstalledVersion -Exe $installedExe
    if (-not $installedVersion -or (Convert-ToSemVer -Value $installedVersion) -ne (Convert-ToSemVer -Value $targetVersionText)) {
        throw "Installed version verification failed. Expected $targetVersionText, got $installedVersion"
    }

    $policyScript = Join-Path $PSScriptRoot 'trader-update-policy.mjs'
    & node $policyScript --db $dataDb --interval-minutes 30
    if ($LASTEXITCODE -ne 0) { throw 'Trader update policy persistence failed.' }

}
catch {
    $message = $_.Exception.Message
    Write-Warning "Promotion failed after backup: $message"
    $runtimeAfterFailure = Get-RuntimeState
    if ($runtimeAfterFailure.AppRunning -or $runtimeAfterFailure.TunnelRunning) {
        throw "Promotion failed and automatic rollback cannot proceed while lnwjud/tunnel is running. Stop them, then run Promote-TraderLnwjud.ps1 -Rollback. Cause: $message"
    }
    Restore-Tree -Backup (Join-Path ([string]$pending.rollbackPath) 'install') -Destination $installRoot
    Restore-Tree -Backup (Join-Path ([string]$pending.rollbackPath) 'data') -Destination $dataRoot
    Remove-Item -LiteralPath $pendingPath -Force
    if ($pending.appWasRunning -eq $true -and (Test-Path -LiteralPath $installedExe)) {
        Start-Process -FilePath $installedExe | Out-Null
    }
    throw "Promotion failed and previous runtime/data were restored. Cause: $message"
}

Start-Process -FilePath $installedExe | Out-Null

$pending.stage = 'awaiting_external_smoke'
$pending.installedAtUtc = [DateTime]::UtcNow.ToString('o')
Write-Json -Value $pending -Path $pendingPath

Write-Host 'TRADER_LNWJUD_PROMOTION=LOCAL_INSTALL_VERIFIED'
Write-Host "TARGET_VERSION=$targetTag"
Write-Host 'UPDATE_POLICY=AUTO_CHECK_ON_AUTO_DOWNLOAD_OFF'
if ($pending.tunnelWasRunning -eq $true) {
    Write-Host 'ACTION=Start the Secure MCP Tunnel, run the real Klaus/MCP contract and Durable Goal smoke, then rerun with -ConfirmExternalSmoke -SmokeEvidence <evidence>.'
}
else {
    Write-Host 'ACTION=Run the real MCP contract and Durable Goal smoke, then rerun with -ConfirmExternalSmoke -SmokeEvidence <evidence>.'
}
