# Trader lnwjud Patch Pipeline V1

This fork keeps Trader-specific lnwjud fixes as an explicit Git patch stack and rebuilds them on top of an exact upstream release tag. The official updater may check for and download upstream releases, but an upstream package is not a Trader-approved runtime by itself.

## Authority boundaries

- Upstream source: `engasnm111/lnwjud`.
- Trader fork: `kobv99/lnwjud`.
- Current adapted patch source branch: `trader/patch-stack-v5.7.2-r3`.
- Patch registry: `scripts/trader-patch-stack.json`.
- Candidate builder: `scripts/update-trader-baseline.ps1`.
- GitHub workflow: `.github/workflows/trader-patched-baseline.yml`.
- The pipeline never stops the local Secure MCP Tunnel and never installs a candidate.
- A pipeline PASS is validation evidence, not installation authorization.
- Any skipped promotion gate produces `PASS_DIAGNOSTIC`, never a promotion-eligible PASS.

## Current patch stack

The current stack was adapted and validated against upstream v5.7.2 at
`88efa21ae4c7301980499cafcc2fb507a3eba760`.

It is replayed in this exact order:

1. `fbbaee22` — adapted R1-A MCP profile/goal contract alignment.
2. `83198b6b` — adapted R1-B Durable Goal schema/discovery streamability correction.
3. `def1131f` — adapted R2 explicit workspace skill routing and checkpoint schema fidelity.
4. `2328e403` — v5.7.2 contract-overlap adaptation preserving upstream Engineering Harness behavior.
5. `d57e7f9c` — v5.7.2 lint/type-contract cleanup for the adapted stack.

The older v5.4.3 R1/R2 commits remain historical provenance. New candidates use the adapted v5.7.2 patch branch so future upstream releases do not have to rediscover already-reviewed v5.7.2 conflict resolutions.

## Local one-command candidate build

Run from a clean fork worktree:

```powershell
.\scripts\update-trader-baseline.ps1 -Version v5.7.2
```

The script:

1. requires a clean worktree;
2. verifies/adds dedicated `trader-upstream` and `trader-fork` remotes;
3. enables local Git `rerere`;
4. fetches the registered patch branch and the exact upstream tag;
5. verifies the selected upstream commit descends from the registered patch baseline;
6. verifies every registered patch belongs to the registered patch branch;
7. creates `trader/patched-vX.Y.Z` without resetting an existing candidate;
8. cherry-picks every registered Trader patch in order with `-x` provenance;
9. fails closed and preserves conflict evidence if any patch no longer applies;
10. runs `git diff --check`;
11. installs the frozen pnpm dependency graph;
12. runs the root patch-contract tests;
13. runs the CLI explicit-workspace skill-routing regression under the CLI package runtime;
14. runs the Desktop explicit-workspace skill-routing regression under the Desktop Vitest configuration;
15. runs TypeScript typecheck;
16. runs the upstream release gate with Windows packaging skipped;
17. builds the workspace;
18. resolves a trusted `cosign >= 3.1.3`; if neither `LNWJUD_COSIGN_PATH` nor PATH provides one, downloads the pinned Windows v3.1.3 binary into `.local-artifacts`, verifies its hard-coded SHA-256, and only then uses it;
19. builds the Windows package;
20. hashes required artifacts and writes `PIPELINE_REPORT.json`.

Use `-PushCandidate` only when the candidate branch should be published after every required gate passes. The default is local-only.

Diagnostic switches `-SkipDependencyInstall`, `-SkipReleaseGate`, and `-SkipPackage` are investigation-only. If any is used, the report state is `PASS_DIAGNOSTIC` and `promotionEligible=false`.

Local packaging does not require a system-wide cosign installation. An explicitly configured `LNWJUD_COSIGN_PATH` or PATH binary is version-checked; otherwise the pipeline bootstraps the exact pinned v3.1.3 Windows binary into the ignored local artifact cache and verifies SHA-256 before execution.

## Release-gate failure policy

The upstream release gate is authoritative evidence and is not silently waived or automatically retried.

During the v5.7.2 adaptation, the full sequential release gate encountered one Windows timing failure in:

`session-resilience-acceptance.test.ts > keeps the desktop lock and production launcher to one owner in either winner order without running tunnel-client`

The same exact test then passed standalone on both the Trader-patched v5.7.2 candidate and a clean upstream v5.7.2 worktree at roughly 11 seconds, while the full release run hit its 15-second limit. This is evidence of a load-sensitive/flaky timing boundary, not evidence that the full failed release run passed.

Therefore:

- the failed full run remains FAILED evidence;
- no timeout is increased merely to hide nondeterminism;
- no automatic rerun converts that failure to PASS;
- future upstream versions are tested normally;
- if a candidate release gate fails, the pipeline writes `REVIEW_REQUIRED` evidence and stops before packaging/promotion.

## GitHub Actions flow

After the workflow is on the fork default branch:

1. Open **Actions**.
2. Select **Trader Patched lnwjud Candidate**.
3. Select **Run workflow**.
4. Enter the exact upstream tag, for example `v5.7.2`.
5. Leave **push_candidate** off for an isolated candidate build, or enable it only when a passing candidate branch should be published.
6. Wait for the single authoritative workflow run to finish.
7. Inspect the always-uploaded pipeline report even when the candidate fails.
8. Download the Windows candidate artifact only after the workflow is green.

The workflow builds on Windows because the Trader production runtime is a Windows lnwjud installation. Cross-platform upstream release claims remain upstream's responsibility.

## Conflict policy

A cherry-pick conflict is a review gate, not an error to bypass.

When a patch conflicts:

- do not install the candidate;
- inspect whether upstream already implements the same contract;
- if upstream fully supersedes the fix, remove or replace that patch through a reviewed patch-stack change;
- if upstream only partially overlaps, resolve the conflict and add/adjust regression evidence;
- never force-reset an established candidate or silently drop a patch merely to make the build green.

Git `rerere` is enabled so equivalent future conflicts can reuse a previously reviewed resolution, but reused resolutions still remain subject to tests.

## Promotion to the installed Trader runtime

The official updater may perform version checks and downloads while the current Tunnel/runtime stays online. Installation is a separate explicit maintenance window.

```text
UPSTREAM RELEASE DETECTED / DOWNLOADED
        |
        v
TRADER PATCH PIPELINE
        |
        +-- exact tag + lineage verification
        +-- patch replay
        +-- Trader contract regression
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
        +-- refresh/reconnect ChatGPT/Klaus when needed
        +-- run post-install MCP contract and Durable Goal smoke checks
        |
        v
PROMOTE NEW TRADER BASELINE
```

If any post-install smoke check fails, the new build is not promoted. Preserve the prior known-good installer/hash for rollback.

## Auto-update policy

```text
AUTO CHECK       = allowed
AUTO DOWNLOAD    = allowed
AUTO INSTALL     = not a Trader promotion path
AUTO PROMOTION   = no
```

Stopping the Tunnel is intentionally late. Candidate construction and validation happen first so a failed upstream/patch integration never interrupts the currently certified runtime.
