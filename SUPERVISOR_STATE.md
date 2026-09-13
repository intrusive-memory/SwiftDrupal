---
type: supervisor-state
feature_name: OPERATION DROPLET SHIPYARD
---

# SUPERVISOR_STATE.md — OPERATION DROPLET SHIPYARD

## Terminology

> **Mission** — A definable, testable scope of work. Defines scope, acceptance criteria, and dependency structure.

> **Sortie** — An atomic, testable unit of work executed by a single autonomous AI agent in one dispatch.

## Mission Metadata
- Operation: OPERATION DROPLET SHIPYARD
- Starting point commit: 1faa8fc6bbd6d73f04b0fd1f9a36edbf633e9ead
- Mission branch: mission/droplet-shipyard/01
- Iteration: 1
- max_retries: 3
- Pre-build clean: run
- Clean ran at: 2026-09-13T18:30:43Z
- Dependency graph: untouched (no floor bumps, no Package.resolved deletion, no SPM cache clear)

## Plan Summary
- Work units: 8
- Total sorties: 10
- Dependency structure: layers
- Dispatch mode: dynamic

## Work Units
| Name | Directory | Sorties | Dependencies |
|------|-----------|---------|-------------|
| Core CLI Scaffolding & Config Model | Sources/SwiftDrupal/CLI, Config | 1 | none |
| Container Orchestration Core | Sources/SwiftDrupal/Container | 1 | Core CLI |
| Networking / Hostname Resolution | Sources/SwiftDrupal/Networking | 1 | Core CLI |
| Host Service (launchd) | Sources/SwiftDrupal/Service | 1 (8) | Container, Networking |
| Lifecycle Commands | Sources/SwiftDrupal/CLI/Commands | 1 | Host Service |
| Database Import/Export | Sources/SwiftDrupal/CLI/Commands | 1 | Host Service |
| Dev Tools (exec/ssh/logs) | CLI/Commands, Logging | 2 (6a, 6b) | Host Service |
| Agent-Friendly Contract, Manifest & Docs | cross-cutting, AGENTS.md | 2 (7a, 7b) | Lifecycle, Database, Dev Tools |

## Work Unit State

### Core CLI Scaffolding & Config Model
- Work unit state: COMPLETED
- Current sortie: 1 of 1
- Sortie state: COMPLETED
- Sortie type: code
- Model: opus
- Complexity score: 21
- Attempt: 1 of 3
- Last verified: commit 7cdfaf9; supervisor re-ran swift_package_test SUCCEEDED (20 tests, 4 suites)
- Notes: Split into library target SwiftDrupal + executable DrupalCLI. Config at .drupal/config.yaml. ExitCode 10-13; name clash with ArgumentParser.ExitCode (qualify when both imported).

### Container Orchestration Core
- Work unit state: COMPLETED
- Current sortie: 2 of 1
- Sortie state: COMPLETED
- Sortie type: code
- Model: opus
- Complexity score: 21
- Attempt: 1 of 3
- Isolation: git worktree
- Last verified: commit 66d5487 merged as c89f9b3; supervisor re-ran swift_package_test SUCCEEDED (86 tests, 15 suites, combined with Sortie 3)
- Notes: Live Containerization path compiles against 0.45.0 but never run. ddev-webserver selected via DDEV_PHP_VERSION/DDEV_WEBSERVER_TYPE env (single image), releaseTag v1.24.8 unverified. DB data on virtiofs share (ownership/perf risk). Architecture gap (containers are VMs that die when `start` exits) RESOLVED by OQ-4: the launchd-managed service hosts LiveContainerService — Sortie 8.

### Networking / Hostname Resolution
- Work unit state: COMPLETED
- Current sortie: 3 of 1
- Sortie state: COMPLETED
- Sortie type: code
- Model: opus
- Complexity score: 14
- Attempt: 1 of 3
- Isolation: git worktree
- Last verified: commit 018e53f fast-forwarded onto mission branch; supervisor re-ran swift_package_test SUCCEEDED (44 tests, 8 suites)
- Notes: Container IP not yet wired (Sortie 4 must pass ContainerService IP to coordinator.activate). New HostnameError enum not mapped to DrupalError exit codes. Design gap (in-process DNS responder dies when `start` exits) RESOLVED by OQ-3/OQ-4: the responder runs in the launchd-managed service, and IP wiring moves to Sortie 8.

### Host Service (launchd)
- Work unit state: COMPLETED
- Current sortie: 8 of 1
- Sortie state: COMPLETED
- Sortie type: code
- Model: opus
- Complexity score: 28
- Attempt: 1 of 3
- Isolation: none (main working tree, sole active sortie)
- Last verified: commit 0e4fba2; supervisor re-ran swift_package_test SUCCEEDED (120 tests, 22 suites); grep criterion confirmed (constructors only in ServiceCommand.swift run path)
- Notes: Label com.intrusive-memory.swiftdrupal.service. Socket ~/Library/Application Support/SwiftDrupal/service.sock (env SWIFTDRUPAL_SERVICE_SOCKET), 4-byte BE length + JSON. ExitCode serviceUnavailable = 14. ContainerService protocol unchanged; client adds startContainer(id:) -> ServiceStartOutcome, activateHostname/deactivateHostname/ping. Unresolved: live Containerization inside a LaunchAgent + virtualization entitlement never exercised; no IPC call timeouts; no TTY resize frame; LiveContainerService.exec ignores cancellation; `probe.drupal` reserved. AGENTS.md still says swift build/test (stale).

### Lifecycle Commands
- Work unit state: COMPLETED
- Current sortie: 4 of 1
- Sortie state: COMPLETED
- Sortie type: code
- Model: opus
- Complexity score: 16
- Attempt: 1 of 3
- Isolation: git worktree
- Last verified: commits d72ca39, 87ddb7e merged as d29f407; supervisor re-ran swift_package_test SUCCEEDED (147 tests, 28 suites); no in-process LiveContainerService/LocalDNSServer construction outside the service
- Notes: `init` writes config; `config` only prints. `delete` removes db data dir by default (`--keep-data` opts out) — user confirmed this default (OQ-5). `start` rebuilds only on image change (php/env edits need delete+start). `stop`/`delete` always call deactivateHostname → GUI admin prompt if a hosts-fallback line exists. `status` exits 14 when service down. Shared types LifecycleEnvironment/LifecycleProjectOptions/LifecycleServiceClient; 7a should unify with 5/6a equivalents.

### Database Import/Export
- Work unit state: COMPLETED
- Current sortie: 5 of 1
- Sortie state: COMPLETED
- Sortie type: code
- Model: sonnet
- Complexity score: 9
- Attempt: 1 of 3
- Isolation: git worktree
- Last verified: commit 70f9bab merged as e9e4ba9 (Drupal.swift subcommand-list conflict resolved by supervisor); swift_package_test SUCCEEDED (163 tests, 34 suites)
- Notes: Added CZlib system-library target (OS libz, no new package dep) for streaming gzip. Credentials assumed DDEV default db/db/db — db spec builder sets none; unverified against live ddev-dbserver. `export-db` with no file writes status JSON to stderr (stdout carries SQL) — 7a audit must allow this. Corrupt gzip has no dedicated exit code. 2.5GB streaming unexercised live.

### Dev Tools (exec/ssh/logs)
- Work unit state: COMPLETED
- Current sortie: 6b of 2
- Sortie state: COMPLETED
- Sortie type: code
- Model: sonnet
- Complexity score: 12
- Attempt: 2 of 3
- 6b last verified: commits 69c14e5 + 522209a; supervisor swift_package_test SUCCEEDED twice (221 tests, 39 suites) plus filtered LogMerger/LogReorderBuffer run
- 6b notes: LogMergeCoordinator.failed now flushes buffer (drainAll) before finishing. Default reorder window 250ms. `logs -f` exits 0 on SIGINT by design (not 128+signal). TEST GAP for test-cleanup/brief: TestLogMergeClock.sleep never resolves, so the window-elapsed timer path through LogMergeCoordinator has no end-to-end test (only synchronous LogReorderBufferTests). LogsCommand live wiring is not exercised at command level (same as exec/ssh).
- Isolation: none (main working tree, sole active sortie)
- 6a last verified: commit 46da9ab merged as 262380d (Drupal.swift conflict resolved by supervisor); swift_package_test SUCCEEDED twice back-to-back (193 tests, 36 suites) to check signal-test flakiness
- 6a notes: No TTY resize (ExecRequest has no resize hook). exec/ssh always forward stdin; TTY auto-detected from isatty(stdin); ssh always requests a pty. Real-signal tests: SIGUSR2 is used by ServiceTests, SIGUSR1/SIGWINCH by SSHCommandTests; a re-signal after guard cancel() kills the test runner (caused a 30-minute hang during 6a). ServiceTarget.swift maps service name to container id.

### Agent-Friendly Contract, Manifest & Docs
- Work unit state: COMPLETED
- Current sortie: 7b of 2
- Sortie state: COMPLETED
- Sortie type: code
- Model: sonnet
- Complexity score: 10
- Attempt: 1 of 3
- Isolation: none (main working tree, sole active sortie)
- 7b last verified: commit 275a331; supervisor grep for stale build text clean; bash -n clean; script executable; entitlements plist has com.apple.security.virtualization; AGENTS.md sections present. Built binary path under XcodeBuildMCP is .build/out/Products/Debug/drupal
- 7a last verified: commit 7fe72bb; supervisor swift_package_test SUCCEEDED twice (262 tests, 45 suites); docs/schema/manifest.json valid JSON; no doc/plan/Package.swift changes
- 7a notes: `drupal --manifest` == `drupal describe-commands`. The manifest is built from ArgumentParser's experimental dump-help (format not guaranteed stable across releases). JSON error envelope on stderr; usage error = 64. import/export client failure → 1. Truncated .gz now fails. post_start runs /bin/sh -c in <name>-web, cwd /var/www/html; stops at first failure → exit 12. DEFERRED for brief: three different project-root lookups (LifecycleProject.load with parent search, ServiceTarget with cwd only, DatabaseTransfer with cwd or --project-root and tolerant of missing config), so exec/ssh/logs have no --project-root.

## Active Agents
| Work Unit | Sortie | Sortie State | Attempt | Model | Complexity Score | Task ID | Output File | Dispatched At |
|-----------|--------|-------------|---------|-------|-----------------|---------|-------------|---------------|

## Decisions Log
| Timestamp | Work Unit | Sortie | Decision | Rationale |
|-----------|-----------|--------|----------|-----------|
| 2026-09-13T18:30:43Z | — | — | Starting point 1faa8fc; branch mission/droplet-shipyard/01 | Mission initialization |
| 2026-09-13T18:30:43Z | — | — | Pre-build clean: removed DerivedData/SwiftDrupal-*, swift_package_clean SUCCEEDED | No Makefile present; used XcodeBuildMCP clean |
| 2026-09-13T18:30:43Z | — | — | Carried uncommitted EXECUTION_PLAN.md edit (swift build → XcodeBuildMCP criteria) onto mission branch | Plan edit predates start; committed with frontmatter |
| 2026-09-13T18:30:43Z | Core CLI | 1 | Model: opus | Score 21 (≈25 turns, 6-10 files, foundation for all 8 sorties, depth 8); force-opus override (foundation + depth ≥5) |
| 2026-09-13T18:30:43Z | — | — | Layer 1+ parallel sorties will use git worktree isolation, merged back by supervisor | Parallel agents in one working tree race on .build lock, Package.swift, and git commits |
| 2026-09-13T18:36:30Z | Core CLI | 1 | COMPLETED | Agent report + commit 7cdfaf9 + supervisor-run swift_package_test SUCCEEDED |
| 2026-09-13T18:36:30Z | — | — | Gate: Container Orchestration Core and Networking unlocked (RUNNING) | Sole dependency Core CLI COMPLETED |
| 2026-09-13T18:37:00Z | Container | 2 | Model: opus | Score 21 (≈25 turns, 6-10 files, unfamiliar Containerization APIs, depth 6); force-opus (foundation + depth ≥5) |
| 2026-09-13T18:37:00Z | Networking | 3 | Model: opus | Score 14 (≈25 turns, 3-5 files, DNS wire format + privileged system I/O, depth 3) |
| 2026-09-13T18:46:30Z | Networking | 3 | COMPLETED | Agent report + commit 018e53f (ff-merge) + supervisor swift_package_test SUCCEEDED, 44 tests |
| 2026-09-13T18:46:30Z | — | — | Worktree isolation defect: Sortie 3 worktree was created from da79dec, not branch HEAD; agent reset to 3716465 | Future worktree dispatches must instruct agents to verify/reset base commit before starting |
| 2026-09-13T18:46:30Z | Networking | 3 | Escalated design gap to user: DNS responder lives in the `drupal` process and dies after `start` exits, so local-resolver default cannot work as specified | Blocks Sortie 4 dispatch until user picks: long-lived responder vs hosts-file default |
| 2026-09-13T19:05:30Z | Container | 2 | COMPLETED | Agent report + merge c89f9b3 + supervisor swift_package_test SUCCEEDED, 86 tests |
| 2026-09-13T19:05:30Z | — | — | Sortie 2 worktree also based on da79dec; agent fast-forwarded to 3716465 | Confirms worktree base defect is systematic |
| 2026-09-13T19:05:30Z | Networking | 3 | User decision: DNS follows the Laravel Valet method (long-lived resolver registered via /etc/resolver) | User answer to DNS design escalation |
| 2026-09-13T19:05:30Z | — | — | HOLD Layer 2 dispatch (Sorties 4, 5, 6a) | Sortie 2 found containers die with the `drupal` process; host-process architecture decision needed before lifecycle/exec/logs sorties are built on ContainerService |
| 2026-09-13 | — | — | User decision: one launchd-managed `drupal` process (`drupal service run`, per-user LaunchAgent) owns BOTH the container VMs and the DNS responder | Resolves the Sortie 2 and Sortie 3 lifetime gaps; recorded in EXECUTION_PLAN.md as OQ-3 and OQ-4 |
| 2026-09-13 | — | — | Plan amended: new work unit Host Service (launchd), Sortie 8, at Layer 2; Sorties 4, 5, and 6a now depend on Sortie 8 and move to Layer 3; 7a and 7b move to Layer 4 | Decisions recorded in the plan, not only in state, so later plan reads don't reopen them. HOLD on 4/5/6a is replaced by their Sortie 8 dependency |
| 2026-09-13 | — | — | Recurring-question root cause: the DNS decision was logged only in SUPERVISOR_STATE.md, not in the EXECUTION_PLAN.md Decision Log | From now on, every user architecture decision goes into the plan's Decision Log as a Resolved OQ in the same step it is logged here |
| 2026-09-13T20:38:39Z | — | — | RESUME: state reconciled with git (HEAD a47cbdb; Sorties 1, 2, 3 merged) | Host Service unlocked: Container and Networking COMPLETED |
| 2026-09-13T20:38:39Z | Host Service | 8 | Model: opus | Score 28 (turns 36-50 = 8, 6-10 files = +4, mixed machine/manual criteria = 2, establishes the IPC pattern for 4/5/6a/6b = 5, 6 dependents = 5, launchd/IPC/new tech = 4); force-opus (foundation + depth ≥5) |
| 2026-09-13T20:38:39Z | Host Service | 8 | Isolation: main working tree, no worktree | Sole active sortie, so no parallel-agent race; avoids the systematic worktree base-commit defect seen on Sorties 2 and 3 |
| 2026-09-13T20:38:39Z | Host Service | 8 | Atomicity risk flagged: 7 tasks spanning IPC, streaming, launchd install, and hostname ownership | Accepting single dispatch; a PARTIAL result gets a continuation rather than a re-plan |
| 2026-09-13T20:54:23Z | Host Service | 8 | COMPLETED | Agent report + commit 0e4fba2 + supervisor swift_package_test SUCCEEDED, 120 tests / 22 suites; grep exit criterion confirmed; manual script present (not run, by design) |
| 2026-09-13T20:54:23Z | — | — | Gate: Lifecycle, Database, Dev Tools unlocked (RUNNING) | Sole dependency Host Service COMPLETED |
| 2026-09-13T20:54:23Z | Lifecycle | 4 | Model: opus | Score 16 (turns 36-50 = 8, 6-10 files = +4, 2 dependents = 2, system calls = 2) |
| 2026-09-13T20:54:23Z | Database | 5 | Model: sonnet | Score 9 (turns 10-20 = 3, 3-5 files = +2, 2 dependents = 2, file I/O = 2) |
| 2026-09-13T20:54:23Z | Dev Tools | 6a | Model: sonnet | Score 12 (turns 21-35 = 5, 3-5 files = +2, 3 dependents = 2, streaming TTY over IPC = 3) |
| 2026-09-13T20:54:23Z | — | — | Layer 3 parallel dispatch uses git worktrees; each prompt pins the base commit and orders a reset if the worktree is based elsewhere | Known worktree base-commit defect (Sorties 2, 3). All three sorties register subcommands in CLI/Drupal.swift, so trivial merge conflicts are expected and resolved by the supervisor |
| 2026-09-13T21:07:38Z | Lifecycle | 4 | COMPLETED | Agent report + merge d29f407 + supervisor swift_package_test SUCCEEDED, 147 tests / 28 suites |
| 2026-09-13T21:07:38Z | — | — | Worktree base defect recurred on Sortie 4 (da79dec); agent reset to 03992db per prompt | Base-pin instruction works; keep it in every worktree dispatch |
| 2026-09-13T21:07:38Z | Lifecycle | 4 | Flag to user: `drupal delete` removes database data by default | Plan said "and their volumes"; an agent-driven destructive default is risky — user may want opt-in |
| 2026-09-13T21:09:34Z | Database | 5 | COMPLETED | Agent report + merge e9e4ba9 + supervisor swift_package_test SUCCEEDED, 163 tests / 34 suites |
| 2026-09-13T21:09:34Z | Database | 5 | Merge conflict in CLI/Drupal.swift subcommand list resolved by supervisor (union of Sortie 4 + 5 entries) | Expected parallel-registration conflict; no logic change |
| 2026-09-13T21:51:25Z | Lifecycle | 4 | User decision: `drupal delete` keeps deleting database data by default; `--keep-data` opts out. No code change | Recorded in EXECUTION_PLAN.md as OQ-5; 7a/7b must document it, not change it |
| 2026-09-13T22:15:06Z | Dev Tools | 6a | COMPLETED | Agent report + merge 262380d + supervisor swift_package_test SUCCEEDED twice, 193 tests / 36 suites |
| 2026-09-13T22:15:06Z | — | — | Worktree base defect hit all three Layer 3 worktrees (da79dec); every agent reset per prompt | Systematic; keep the base-pin step |
| 2026-09-13T22:15:06Z | Dev Tools | 6b | Model: sonnet | Score 12 (turns 21-35 = 5, 3-5 files = +2, 2 dependents = 2, timestamp-merge algorithm = 3) |
| 2026-09-13T22:15:06Z | Dev Tools | 6b | Isolation: main working tree | Sole active sortie |
| 2026-09-13T22:18:06Z | Agent Contract | 7b | User decision: hold the live fkd-drupal8 smoke test; the user runs it on another machine. 7b writes a portable script only, not executed; fixture entry criterion removed | Recorded in EXECUTION_PLAN.md as OQ-6. Mission can complete with zero live Containerization runs; the brief must flag this |
| 2026-09-13T22:20:14Z | Agent Contract | 7b | User decision: 7b commits AGENTS.md/CLAUDE.md (new)/README.md updates covering build + entitlement signing, host prerequisites (Apple container kernel), hosting a site, and running tests, so an agent on another machine can use the binary | Recorded as OQ-7 and folded into Sortie 7b Task 1b + exit criteria; deferred to last phase at user request so docs include 6b/7a |
| 2026-09-13T22:27:17Z | Dev Tools | 6b | Attempt 1 → BACKOFF: supervisor swift_package_test FAILED (217/218). LogMergerTests.aFailingSourceFailsTheMergedStream got [] instead of ["before the failure"]; passed on filtered rerun | Real bug, not only a flaky test: LogMergeCoordinator.failed() finishes without flushing the reorder buffer, so lines held for the other source are dropped when a stream errors. Scheduling-dependent, so intermittent. Agent's 218-pass report was a lucky run |
| 2026-09-13T22:27:17Z | Dev Tools | 6b | Attempt 2 dispatched (sonnet, main working tree) with the root cause and fix spelled out | Narrow fix; not 2+ failures, so no force-opus |
| 2026-09-13T22:47:36Z | Dev Tools | 6b | COMPLETED (attempt 2) | Agent fixed the merger flush bug plus a second test-clock race; supervisor verified 3 green runs (full x2, filtered x1) |
| 2026-09-13T22:47:36Z | — | — | Gate: Agent-Friendly Contract unlocked (RUNNING) | Lifecycle, Database, Dev Tools all COMPLETED |
| 2026-09-13T22:47:36Z | Agent Contract | 7a | Model: opus | Score 17 (turns 36-50 = 8, 6-10 files = +4, open-ended wiring audit = 3, system/exec = 2) |
| 2026-09-13T23:04:16Z | Agent Contract | 7a | COMPLETED | Agent report + commit 7fe72bb + supervisor swift_package_test SUCCEEDED twice, 262 tests / 45 suites |
| 2026-09-13T23:04:16Z | Agent Contract | 7b | Model: sonnet | Score 10 (turns 21-35 = 5, 3-5 files = +2, mixed criteria = 2, low risk = 1). Accuracy is guarded by requiring the docs' command reference to be generated from `drupal describe-commands` output |
| 2026-09-13T23:16:11Z | Agent Contract | 7b | COMPLETED | Agent report + commit 275a331 + supervisor checks of the exit criteria |
| 2026-09-13T23:16:11Z | — | — | All 8 work units COMPLETED. Post-mission flow (completion → test-cleanup → brief → clean) is ON HOLD | Supervisor found a plan gap while answering the user's "what does start launch" question: nothing wires Drupal to the database (no settings include, DB host or credentials in the web container; db hostname `<name>-db` with inter-VM resolution unverified) and there is no host-UID mapping for the stock DDEV images. Waiting for the user to choose between (a) a new database-wiring sortie and (b) documenting these as known gaps |
| 2026-09-13T23:23:05Z | — | — | User decision (OQ-8): no db-wiring sortie. Gaps captured in docs/WORKING_INSTALL_GAPS.md (G1–G28) from a supervisor comparison against DDEV v1.24.8 source; linked from AGENTS/README/CLAUDE | User fixes them live on another machine |
| 2026-09-13T23:23:05Z | — | — | User instruction: commit everything, push the mission branch, open a PR into development via /create-pull-request | Post-mission flow (test-cleanup, brief, clean) not run: the user redirected to the PR |
