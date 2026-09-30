# Trader lnwjud Patch Pipeline V1

This fork keeps Trader-specific lnwjud fixes as an explicit Git patch stack and rebuilds them on top of an exact upstream release tag. The official updater may check for and download upstream releases, but an upstream package is not a Trader-approved runtime by itself.

## Authority boundaries

- Upstream source: `engasnm111/lnwjud`.
- Trader fork: `kobv99/lnwjud`.
- Patch source branch: `fix/klaus-mcp-contract-exposure`.
- Patch registry: `scripts/trader-patch-stack.json`.
- Candidate builder: `scripts/update-trader-baseline.ps1`.
- GitHub workflow: `.github/workflows/trader-patched-baseline.yml`.
- The pipeline never stops the local Secure MCP Tunnel and never installs a candidate.
- A pipeline PASS is validation evidence, not installation authorization.

## Patch stack

The V1 stack is replayed in this exact order:

1. `35abe6274b94596b48a4a090d712f96373098c41` — MCP profile/goal contract alignment.
2. `54e9dc92cc7e850f3c5a1fcb1216851bcf362ae5` — Durable Goal schema/discovery streamability correction.
3. `8d4e4769d5e3ca870a738a0670fe6e564a39fe2c` — explicit workspace skill routing and checkpoint schema fidelity.

The original patch baseline is upstream v5.4.3 at `dfda369b2921ccae4fd477c3fd76c84b9a05452f`. New candidates do not rebase the patch branch. They start from the selected upstream tag and cherry-pick the registry commits with `-x` provenance.

## Local one-command candidate build

Run from a clean fork worktree:

```powershell
.\scripts\update-trader-baseline.ps1 -Version v5.7.2
```

The script:

1. verifies the worktree is clean;
2. verifies/adds the canonical `upstream` remote;
3. enables local Git rerere;
4. fetches the patch branch and upstream tags;
5. resolves the exact upstream tag to a commit;
6. creates `trader/patched-vX.Y.Z` without resetting an existing candidate;
7. cherry-picks every registered Trader patch in order;
8. stops and preserves the conflict state if any patch no longer applies cleanly;
9. runs `git diff --check`;
10. installs the frozen pnpm dependency graph;
11. runs the patch-contract regression files from the registry;
12. runs TypeScript typecheck;
13. runs the upstream release gate with Windows packaging skipped;
14. builds the workspace;
15. builds the Windows package;
16. hashes the produced candidate artifacts and writes `PIPELINE_REPORT.json`.

Use `-PushCandidate` only when the candidate should be published to the fork after every gate passes. The default is local-only.

Diagnostic switches `-SkipInstall`, `-SkipReleaseGate`, and `-SkipPackage` exist for investigation only. A candidate built with skipped promotion gates is not a production baseline.

## GitHub Actions flow

After the workflow file is present on the fork's default branch:

1. Open **Actions**.
2. Select **Trader Patched lnwjud Candidate**.
3. Select **Run workflow**.
4. Enter the exact upstream tag, for example `v5.7.2`.
5. Leave **push_candidate** off for an isolated candidate build, or enable it only when a passing `trader/patched-vX.Y.Z` branch is desired.
6. Wait for the single authoritative workflow run to finish.
7. Download the `trader-lnwjud-vX.Y.Z-<run-id>` artifact only after the run is green.

The workflow builds on Windows because the Trader production runtime is currently a Windows lnwjud installation. Cross-platform upstream release claims remain upstream's responsibility; this internal pipeline does not relabel a Windows candidate as a full upstream release.

## Conflict policy

A cherry-pick conflict is a review gate, not an error to bypass.

When a patch conflicts:

- do not install the candidate;
- inspect whether upstream already implements the same contract;
- if upstream fully supersedes the fix, remove or replace that patch in the registry through a reviewed maintenance change;
- if upstream only partially overlaps, resolve the conflict and add/adjust regression evidence;
- never use `git reset --hard`, force-push an established candidate, or silently drop a patch just to make the build green.

Git `rerere` is enabled locally so repeated equivalent conflicts can reuse a previously reviewed resolution.

## Promotion to the installed Trader runtime

The official updater may perform version checks and downloads while the current Tunnel/runtime stays online. Installation is a separate explicit maintenance window.

Required promotion sequence:

```text
UPSTREAM RELEASE DETECTED
        |
        v
TRADER PATCH PIPELINE
        |
        +-- patch replay
        +-- contract regression
        +-- upstream release gate
        +-- Windows build/package
        +-- SHA-256/provenance
        |
        v
PIPELINE PASS
        |
        v
EXPLICIT MAINTENANCE WINDOW
        |
        +-- stop Secure MCP Tunnel
        +-- stop lnwjud runtime/Desktop as required by installer
        +-- install Trader-patched candidate, not the untouched upstream installer
        +-- verify installed artifact/runtime identity
        +-- start lnwjud
        +-- start Secure MCP Tunnel
        +-- refresh/reconnect the ChatGPT/Klaus integration when needed
        +-- run post-install MCP contract and Durable Goal smoke checks
        |
        v
PROMOTE NEW TRADER BASELINE
```

If any post-install smoke check fails, the new build must not be promoted as the Trader baseline. Preserve the prior known-good installer/hash so rollback remains possible.

## Auto-update policy

```text
AUTO CHECK       = allowed
AUTO DOWNLOAD    = allowed
AUTO INSTALL     = not a Trader promotion path
AUTO PROMOTION   = no
```

Stopping the Tunnel is intentionally late in the process. Candidate construction and validation happen first so a failed upstream/patch integration does not interrupt the currently certified runtime.
