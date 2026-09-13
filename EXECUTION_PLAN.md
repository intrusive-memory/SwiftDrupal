---
type: execution-plan
feature_name: OPERATION DROPLET SHIPYARD
starting_point_commit: 1faa8fc6bbd6d73f04b0fd1f9a36edbf633e9ead
mission_branch: mission/droplet-shipyard/01
iteration: 1
---

# EXECUTION_PLAN.md — SwiftDrupal

## Terminology

> **Mission** — A definable, testable scope of work. Defines scope, acceptance criteria, and dependency structure.

> **Sortie** — An atomic, testable unit of work executed by a single autonomous AI agent in one dispatch. One aircraft, one mission, one return.

> **Work Unit** — A grouping of sorties (package, component, phase).

## Source

Requirements: [`docs/requirements/02-v1-mvp-requirements.md`](docs/requirements/02-v1-mvp-requirements.md)
(decided v1.0 MVP scope), with background context from
[`docs/requirements/01-apple-container-capability-survey.md`](docs/requirements/01-apple-container-capability-survey.md)
(superseded survey — architecture rationale only, not itself a source of
tasked requirements).

## Acceptance Fixture — Real-World Starting Point

Sortie 7b's end-to-end smoke test proves the `drupal` binary can host a real Drupal site, not a synthetic one. The concrete starting point:

- **Code**: `~/Projects/caffrey/fkd-drupal8` (GitHub `Find-Know-Do/fkd-drupal8`, Pantheon-hosted). Synced to `origin/master` at commit `08889dccd5` (2026-09-11). Docroot: `web/`.
- **Database**: `dbbackup/fkd-drupal8_live_2026-09-11T17-57-07_UTC_database.sql.gz` (2.5GB) inside that same repo — the latest manual Live-environment backup, pulled via `terminus backup:get fkd-drupal8.live --element=db` on 2026-09-11. `dbbackup/` is gitignored (repo convention), so this file is local-only.
- **Files**: **deferred**. The latest Live files backup is ~63.4GB (`fkd-drupal8_live_2026-09-11T05-00-00_UTC_files.tar.gz`) — too large to pull as part of this mission's iteration. Sortie 7b's smoke test runs `init` → `import-db` → `start` → `status` → `stop` → `delete` against the code + db only; the production files corpus (`web/sites/default/files`) is not present, so file-dependent rendering (images, uploaded media) is out of scope for this smoke test's assertions. A follow-up mission can add a files-backup pull (full or partial) once the CLI's `import-db`/`start` path is proven.

## Work Units

| Work Unit | Directory | Sorties | Layer | Dependencies |
|-----------|-----------|---------|-------|-------------|
| Core CLI Scaffolding & Config Model | `Sources/SwiftDrupal/CLI`, `Sources/SwiftDrupal/Config` | 1 | 0 | none |
| Container Orchestration Core | `Sources/SwiftDrupal/Container` | 1 | 1 | Core CLI Scaffolding & Config Model |
| Networking / Hostname Resolution | `Sources/SwiftDrupal/Networking` | 1 | 1 | Core CLI Scaffolding & Config Model |
| Host Service (launchd) | `Sources/SwiftDrupal/Service` | 1 (8) | 2 | Container Orchestration Core, Networking / Hostname Resolution |
| Lifecycle Commands | `Sources/SwiftDrupal/CLI/Commands` (lifecycle) | 1 | 3 | Host Service (launchd) |
| Database Import/Export | `Sources/SwiftDrupal/CLI/Commands` (database) | 1 | 3 | Host Service (launchd) |
| Dev Tools (exec/ssh/logs) | `Sources/SwiftDrupal/CLI/Commands` (dev tools), `Sources/SwiftDrupal/Logging` | 2 (6a, 6b) | 3 | Host Service (launchd) |
| Agent-Friendly Contract, Manifest & Docs | `Sources/SwiftDrupal` (cross-cutting), `AGENTS.md` | 2 (7a, 7b) | 4 | Lifecycle Commands, Database Import/Export, Dev Tools (exec/ssh/logs) |

> **Process model (OQ-3, OQ-4):** a single long-lived `drupal service run` process, managed by a per-user launchd LaunchAgent, owns both the container VMs and the `*.drupal` DNS responder. Every other `drupal` subcommand is a short-lived client that talks to it. Sorties 2 and 3 were built before this decision and produced in-process components; Sortie 8 hosts them in the service. No later sortie may construct `LiveContainerService` or `LocalDNSServer` in a short-lived CLI process.

---

### Sortie 1: Core CLI Scaffolding & Config Model

**Priority**: 29.2 — Highest priority. Blocks all 8 remaining sorties transitively (dependency depth 8), establishes the config model, output-format resolver, and exit-code contract every later sortie imports.

**Entry criteria**:
- [ ] First sortie — no prerequisites.

**Tasks**:
1. Add the `swift-argument-parser` package dependency in `Package.swift` and wire a root `Drupal` command (`@main`, `ParsableCommand`) as the subcommand-registration entry point, replacing the current placeholder `SwiftDrupal.swift`.
2. Define a `ProjectConfig` `Codable` struct in `Sources/SwiftDrupal/Config` matching the MVP schema: `name: String?`, `docroot: String`, `php_version: String`, `webserver_type: String`, `database: DatabaseConfig { type: String, version: String }`, `web_environment: [String]`. `nodejs_version` is explicitly excluded from v1.0 scope (see Decision Log).
3. Implement YAML encode/decode for `ProjectConfig` (a YAML library dependency, e.g. `Yams`, added to `Package.swift`), including a round-trip loader that reads the project's config file from disk.
4. Implement project-name derivation (parent directory name by default, overridden by an explicit `name:` field in the config) and hostname derivation (`<name>.drupal`) as pure functions in `Sources/SwiftDrupal/Config`.
5. Define a shared output-format resolver (`--json` flag OR non-TTY auto-detection) exposed as a reusable component every subcommand added in later sorties can call into.
6. Define an `ExitCode` enum enumerating the distinct failure classes named in the requirements (invalid config, `Containerization`/platform unavailable, container failed to start, timeout waiting for health) and wire it into `ArgumentParser`'s exit-code path.
7. Write unit tests in `Tests/SwiftDrupalTests` covering: `ProjectConfig` YAML round-trip, project-name/hostname derivation (default and override cases), and `ExitCode` mapping.

**Exit criteria**:
- [ ] XcodeBuildMCP `swift_package_build` succeeds with the new `swift-argument-parser` and YAML dependencies resolved.
- [ ] XcodeBuildMCP `swift_package_test` passes, including the new config round-trip, name/hostname derivation, exit-code, and output-format-resolver tests (`--json` flag and non-TTY auto-detection both exercised).
- [ ] `Sources/SwiftDrupal/Config/ProjectConfig.swift` (or equivalent path) exists and defines the full MVP schema field set.
- [ ] Running the built `drupal` binary with no arguments exits via the new `ArgumentParser` root command (not the old placeholder `print` statement).

---

### Sortie 2: Container Orchestration Core

> **Amended after completion (OQ-4):** the `LiveContainerService` built here is hosted by the launchd-managed service process (Sortie 8), not the CLI process — Containerization VMs are owned by the process that starts them and die with it.

**Priority**: 24.2 — Second-highest. Blocks 6 downstream sorties (dependency depth 6) and establishes the `ContainerService` protocol reused by Sorties 4, 5, 6a, and 6b; carries elevated risk from unfamiliar `Containerization` framework APIs.

**Entry criteria**:
- [ ] Sortie 1 exit criteria met (`ProjectConfig` model and output-format/exit-code infrastructure available to import).

**Tasks**:
1. Define a `ContainerService` protocol in `Sources/SwiftDrupal/Container` wrapping the `Containerization` APIs needed for: pull image, create container, start, stop, delete, inspect/status.
2. Implement a web-container spec builder that selects the `ddev-webserver` image tag from `php_version` + `webserver_type`, and configures a virtiofs bind mount of the project directory to the configured `docroot`.
3. Implement a db-container spec builder that selects the `ddev-dbserver` image tag from `database.version` (MariaDB only for v1.0), with a persistent mount for the database data directory.
4. Implement health-check/wait-until-ready logic that polls a started container until its service responds, raising the `timeout waiting for health` exit code (from Sortie 1) on expiry.
5. Implement `web_environment` passthrough: inject the configured environment variable list into the web container's spec.
6. Write tests using a mockable `ContainerService` covering: image-tag selection logic for both web and db containers, and bind-mount path construction.

**Exit criteria**:
- [ ] XcodeBuildMCP `swift_package_build` succeeds.
- [ ] XcodeBuildMCP `swift_package_test` passes, including tests for image-tag selection, bind-mount-path construction, health-check polling/timeout logic, and environment-variable (`web_environment`) injection, all against a mock `ContainerService`.
- [ ] `ContainerService` protocol and both web/db spec builders exist in `Sources/SwiftDrupal/Container` and are covered by tests, without requiring a live `Containerization` runtime to execute the test suite.

---

### Sortie 3: Networking / Hostname Resolution

> **Amended after completion (OQ-3, OQ-4):** the `LocalDNSServer` responder built here runs inside the launchd-managed service process (Sortie 8), Laravel Valet–style, so it outlives any single `drupal` command. Wiring the web container's IP into the responder moves to Sortie 8.

**Priority**: 13.2 — Blocks 3 downstream sorties (Sortie 4 and, transitively, 7a/7b); elevated risk from privileged `/etc/resolver` writes and the known macOS 26 custom-TLD regression, offset by a narrower reuse footprint (`HostnameStrategy` consumed only by Sortie 4).

**Entry criteria**:
- [ ] Sortie 1 exit criteria met (`ProjectConfig`/hostname-derivation function available to import).

**Tasks**:
1. Implement a minimal local DNS responder bound to `127.0.0.1` on a non-privileged port (e.g. `1053`, matching Apple's own `container system dns create` precedent — see Decision Log) in `Sources/SwiftDrupal/Networking` that answers `*.drupal` A-record queries with a configurable current IP.
2. Implement an `/etc/resolver/drupal` file writer performing the one-time, privileged registration step, using the `resolver(5)` `port` directive so it points at the responder's non-privileged port instead of requiring the `drupal` process to bind port 53.
3. Implement the IP-registration/update flow: on each `start`, read the web container's freshly assigned IP via the `Containerization` API (the same data `container inspect` exposes) and update the responder's current-IP record.
4. Implement the fallback `/etc/hosts` rewrite strategy (write/remove a `<name>.drupal` line mapping to the current IP) behind a shared `HostnameStrategy` protocol, so the resolver-based and hosts-file-based approaches are interchangeable implementations of the same interface. Local-resolver is the default (see Decision Log).
5. Guard against the known macOS 26 `/etc/resolver` custom-TLD regression (see Decision Log): after registering the resolver, verify it actually answers a `*.drupal` query, and if it does not, fall back to the `/etc/hosts` strategy automatically with a clear warning in the command's output.
6. Write unit tests for the responder's query-answering logic and for `/etc/hosts` line insertion/removal, exercised against a temporary file — never the real `/etc/hosts`.

**Exit criteria**:
- [ ] XcodeBuildMCP `swift_package_build` succeeds.
- [ ] XcodeBuildMCP `swift_package_test` passes, including responder query-answering tests and hosts-file insertion/removal tests run against a temp file.
- [ ] Both `HostnameStrategy` implementations exist behind the shared protocol, local-resolver is wired as the default, and the verify-then-fall-back-to-hosts path (task 5) is implemented and covered by a test that simulates resolver-verification failure and asserts the fallback strategy answers the query instead.

---

### Sortie 8: Host Service (launchd-managed `drupal` process)

**Priority**: Highest remaining — directly blocks Sorties 4, 5, and 6a and transitively 6b, 7a, and 7b (every unfinished sortie). Highest remaining risk: IPC design, launchd lifecycle, and the first time the live `Containerization` path must run outside a mock.

**Entry criteria**:
- [ ] Sortie 2 exit criteria met (`ContainerService` protocol and `LiveContainerService` available).
- [ ] Sortie 3 exit criteria met (`LocalDNSServer`, `HostnameResolutionCoordinator`, `ResolverFileRegistrar` available).

**Tasks**:
1. Add a `drupal service run` subcommand (hidden from default help) that is the long-lived host process: it owns the single `LiveContainerService` instance and the `LocalDNSServer`, and runs until signalled. On SIGTERM it stops containers gracefully, then stops the responder, then exits 0. Same `drupal` binary — no separate daemon executable (see OQ-4).
2. Define the service IPC in `Sources/SwiftDrupal/Service`: a Unix domain socket at `~/Library/Application Support/SwiftDrupal/service.sock` (mode 0600), with length-prefixed JSON request/response messages covering every `ContainerService` operation plus hostname activate/deactivate, and a streaming message mode for exec I/O and log streams.
3. Implement `ServiceClientContainerService`, a client-side `ContainerService` conformance that forwards every call over the socket. Sorties 4, 5, 6a, and 6b consume the existing `ContainerService` protocol through this client and never construct `LiveContainerService` directly.
4. Move hostname ownership into the service: when the service starts the web container, it reads the container's IP and updates the responder record itself (closes Sortie 3's "Container IP not yet wired" note). The `/etc/hosts` fallback still needs a privileged write on each start, which a user-level LaunchAgent cannot perform unattended. So when resolver verification fails, the service reports that to the client, and the CLI process performs the privileged `/etc/hosts` write and emits the warning.
5. Implement `drupal service install`: writes a per-user LaunchAgent plist to `~/Library/LaunchAgents/` (`RunAtLoad` + `KeepAlive`, `ProgramArguments` = absolute path of the installed `drupal` binary + `service run`), loads it with `launchctl bootstrap gui/<uid>`, and performs the one-time privileged `/etc/resolver/drupal` registration via `ResolverFileRegistrar`. Implement `drupal service uninstall` (reverses both) and `drupal service status` (plist installed / agent loaded / socket reachable, JSON output).
6. Service-unreachable contract: any command that needs the service and cannot reach the socket fails fast with a new dedicated `ExitCode` case (`serviceUnavailable`) and a JSON error naming `drupal service install` as the remedy. Never fall back to in-process containers or DNS — that would reintroduce the die-on-exit defect.
7. Write tests: IPC framing round-trip for every request type; streaming message ordering; client↔server conformance using a mock `ContainerService` behind a real socket in a temp directory; LaunchAgent plist generation (golden file); SIGTERM shutdown ordering (containers stopped before responder); `serviceUnavailable` exit code when no socket exists. No test touches the real `~/Library/LaunchAgents`, `launchctl`, or `/etc/resolver`.

**Exit criteria**:
- [ ] XcodeBuildMCP `swift_package_build` succeeds.
- [ ] XcodeBuildMCP `swift_package_test` passes, including the IPC round-trip, streaming-order, socket conformance, plist golden-file, shutdown-ordering, and `serviceUnavailable` tests listed in Task 7.
- [ ] `service run`, `service install`, `service uninstall`, and `service status` exist as registered subcommands.
- [ ] `grep` confirms `LiveContainerService(` and `LocalDNSServer(` are constructed only in the `service run` code path.
- [ ] A documented manual verification script exists (not CI-gated): after `drupal service install`, `launchctl print gui/$UID/<label>` shows the agent running and `dig @127.0.0.1 -p 1053 probe.drupal` gets an answer.

---

### Sortie 4: Lifecycle Commands

**Priority**: 9.3 — Blocks Sorties 7a/7b (dependency depth 2); highest complexity of the Layer 2 sorties (7 subcommands across the largest file surface) but composes already-built pieces rather than establishing new patterns.

**Entry criteria**:
- [ ] Sortie 8 exit criteria met (`ServiceClientContainerService`, service-owned hostname activation, and `serviceUnavailable` exit code available).

**Tasks**:
1. Implement `drupal init`/`drupal config` command: writes the MVP YAML config file into the project directory with defaults applied, and supports `--json` output of the written config.
2. Implement `drupal start`: idempotent — pulls images if needed, creates/starts web+db containers through the host service (`ServiceClientContainerService`), which also activates hostname resolution; performs the CLI-side `/etc/hosts` fallback write only if the service reports resolver verification failed; waits for health; returns JSON status. Returns promptly — the containers keep running in the service after `start` exits.
3. Implement `drupal stop`: idempotent — stops containers gracefully; succeeds (does not error) if already stopped.
4. Implement `drupal restart`: composes `stop` followed by `start`.
5. Implement `drupal status`/`drupal describe`: reports container states, resolved hostname, and effective config, in JSON.
6. Implement `drupal delete`: stops and removes containers (and their volumes), leaving project source files untouched.
7. Implement `drupal config --json` / `drupal validate`: prints the fully resolved configuration, including any defaults applied, without starting anything.

**Exit criteria**:
- [ ] XcodeBuildMCP `swift_package_build` succeeds.
- [ ] XcodeBuildMCP `swift_package_test` passes, including a test that `start` on an already-started project and `stop` on an already-stopped project both exit 0 (idempotency).
- [ ] Each of `init`, `start`, `stop`, `restart`, `status`, `delete`, `config --json`/`validate` exists as a registered subcommand and emits JSON output when `--json` is passed or stdout is not a TTY.

---

### Sortie 5: Database Import/Export

**Priority**: 8.7 — Blocks Sorties 7a/7b (dependency depth 2); smallest task/file footprint of the Layer 2 sorties, self-contained streaming logic with no shared-pattern reuse by others.

**Entry criteria**:
- [ ] Sortie 8 exit criteria met (`ServiceClientContainerService` available to exec into the service-owned db container).

**Tasks**:
1. Implement `drupal import-db <file>`: streams a plain SQL dump into the db container via the container's SQL client.
2. Implement `drupal export-db [<file>]`: runs the container's dump utility and streams output to a local file or stdout when no path is given.
3. Add JSON status/result output for both commands (bytes processed, exit status).
4. Write tests covering command argument parsing and dump-piping logic against a fake/mock container-exec channel (no live database required).

**Exit criteria**:
- [ ] XcodeBuildMCP `swift_package_build` succeeds.
- [ ] XcodeBuildMCP `swift_package_test` passes, including the mocked import/export piping tests.
- [ ] `import-db` and `export-db` exist as registered subcommands with JSON result output.

---

### Sortie 6a: Dev Tools — Exec / SSH Commands

**Priority**: 11.7 — Blocks Sortie 6b directly and Sorties 7a/7b transitively (dependency depth 3, the highest of the three Layer 2 work units); small, focused scope (2 subcommands).

**Entry criteria**:
- [ ] Sortie 8 exit criteria met (`ServiceClientContainerService` streaming exec available). Interactive `ssh` TTY passthrough runs over the service socket's streaming mode, not a direct in-process container handle.

**Tasks**:
1. Implement `drupal exec <service> -- <command>`: runs a command inside the web or db container, streaming stdout/stderr back with correct exit-code passthrough.
2. Implement `drupal ssh` (or equivalent shell-in command): opens an interactive shell session in the web container, or a specified service.
3. Write tests for `exec`/`ssh` covering TTY passthrough, exit-code propagation, and stream handling, against a mock `ContainerService` exec channel.

**Exit criteria**:
- [ ] XcodeBuildMCP `swift_package_build` succeeds.
- [ ] XcodeBuildMCP `swift_package_test` passes, including `ExecCommandTests` and `SSHCommandTests` covering TTY passthrough, exit codes, and stream handling.
- [ ] `exec` and `ssh` exist as registered subcommands.

---

### Sortie 6b: Dev Tools — Logs (interleaving, TUI & JSON modes)

**Priority**: 9.0 — Blocks Sorties 7a/7b (dependency depth 2); moderate complexity from the timestamp-merge algorithm plus two distinct output modes (TUI, JSON).

**Entry criteria**:
- [ ] Sortie 6a exit criteria met (dev-tools work unit sequencing; log streaming reuses the same service-socket streaming access wired up there; log streams are read from the service, which owns the containers).

**Tasks**:
1. Implement combined `drupal logs`: reads both containers' log streams and merges them by timestamp into one interleaved, source-tagged stream.
2. Implement the interactive/TTY TUI mode for `drupal logs`: a scrolling, colorized-by-source view.
3. Implement the non-TTY/`--json` mode for `drupal logs`: one JSON object per log line (`timestamp`, `service`, `stream`, `message`).
4. Write tests for the log-merging/interleaving logic (given two fake timestamped streams, assert output order and source tagging) and for the JSON-line schema's serialization.

**Exit criteria**:
- [ ] XcodeBuildMCP `swift_package_build` succeeds.
- [ ] XcodeBuildMCP `swift_package_test` passes, including the log-interleaving-order test and the JSON-line schema test.
- [ ] `logs` (with both TUI and JSON modes) exists as a registered subcommand.

---

### Sortie 7a: Agent-Friendly Contract — Manifest & Wiring Audit

**Priority**: 5.8 — Last layer; depends on every other work unit completing (Sorties 4, 5, 6a, 6b), so it can only run once everything it audits and introspects exists. Blocks only Sortie 7b.

**Entry criteria**:
- [ ] Sortie 4 exit criteria met.
- [ ] Sortie 5 exit criteria met.
- [ ] Sortie 6a exit criteria met.
- [ ] Sortie 6b exit criteria met.

**Tasks**:
1. Implement `--manifest`/`describe-commands`: introspects every registered `ArgumentParser` subcommand and flag, emitting name, flags, types, and descriptions as JSON. Commit a schema document at `docs/schema/manifest.json` describing the emitted shape.
2. Audit every subcommand implemented in Sorties 4, 5, 6a, 6b to confirm `--json`/non-TTY JSON output and the documented `ExitCode` cases (from Sortie 1) are actually wired through; add any missing wiring found.
3. Implement the minimal `post_start` extensibility point: a `post_start: [String]` config field listing shell commands run inside the web container after `start` succeeds.

**Exit criteria**:
- [ ] XcodeBuildMCP `swift_package_build` succeeds.
- [ ] XcodeBuildMCP `swift_package_test` passes, including the manifest-emission test.
- [ ] `--manifest`/`describe-commands` exists, lists every subcommand from Sorties 1, 2, 4, 5, 6a, 6b, and its output validates against `docs/schema/manifest.json`.
- [ ] `post_start` config field exists and is executed inside the web container after a successful `start`.

---

### Sortie 7b: Agent-Friendly Contract — Docs & End-to-End Smoke Test

**Priority**: 1.7 — Lowest priority; last sortie in the mission, blocks nothing, purely documentation and a validation smoke test over already-completed functionality.

**Entry criteria**:
- [ ] Sortie 7a exit criteria met (manifest and wiring-audit fixes available to document/exercise).
- [ ] The real-world acceptance fixture (see `## Acceptance Fixture — Real-World Starting Point`) is available: `~/Projects/caffrey/fkd-drupal8` synced to `origin/master`, with `dbbackup/fkd-drupal8_live_2026-09-11T17-57-07_UTC_database.sql.gz` present in that repo.

**Tasks**:
1. Expand the repository's root `AGENTS.md` with titled sections: "Config Schema" (with a full YAML example), "Command Reference" (every subcommand with its flags and `--json` behavior), and "Common Workflows" (at least two worked examples each for: bring up a fresh Drupal site, import a database, tail logs).
2. Write an end-to-end smoke test exercising `init` → `import-db dbbackup/fkd-drupal8_live_2026-09-11T17-57-07_UTC_database.sql.gz` → `start` → `status` → `stop` → `delete` against the real `~/Projects/caffrey/fkd-drupal8` starting point (not a synthetic fresh Drupal site) — this is the mission's concrete proof that the `drupal` binary can host a real Drupal 11 site end to end. Assert the JSON output shape at each step. Document as a repeatable manual test script if a live `Containerization` runtime is required to execute it automatically.

**Exit criteria**:
- [ ] XcodeBuildMCP `swift_package_build` succeeds.
- [ ] `AGENTS.md` contains the "Config Schema", "Command Reference", and "Common Workflows" sections, each meeting the content requirements in Task 1.
- [ ] The end-to-end smoke test (automated or documented manual script) exists on disk, names its steps explicitly (`init`, `import-db`, `start`, `status`, `stop`, `delete`), and targets the `~/Projects/caffrey/fkd-drupal8` fixture rather than a synthetic project.

---

## Parallelism Structure

**Critical Path**: Sortie 1 → Sortie 2 → Sortie 8 → Sortie 6a → Sortie 6b → Sortie 7a → Sortie 7b (length: 7 sorties)

**Parallel Execution Groups**:
- **Group 1** (Layer 0 — sequential prerequisite, no parallelism possible):
  - Core CLI Scaffolding & Config Model: Sortie 1 (Agent 1)
- **Group 2** (Layer 1 — can run in parallel, both depend only on Sortie 1):
  - Container Orchestration Core: Sortie 2 (Agent 1)
  - Networking / Hostname Resolution: Sortie 3 (Agent 2)
- **Group 3** (Layer 2 — sequential, depends on Sorties 2 and 3; added by OQ-4):
  - Host Service (launchd): Sortie 8 (Agent 1)
- **Group 4** (Layer 3 — can run in parallel, all depend on Sortie 8):
  - Lifecycle Commands: Sortie 4 (Agent 1)
  - Database Import/Export: Sortie 5 (Agent 2)
  - Dev Tools (exec/ssh/logs): Sortie 6a → Sortie 6b, sequential within this work unit (Agent 3)
- **Group 5** (Layer 4 — sequential, depends on all of Group 4):
  - Agent-Friendly Contract, Manifest & Docs: Sortie 7a → Sortie 7b (Agent 1)

**Agent Constraints**:
- Maximum concurrent work units in any single layer: 3 (Group 4) — within the 4-sub-agent cap.
- Every sortie in this plan carries an XcodeBuildMCP `swift_package_build` exit criterion — never raw `swift build`/`swift test` — (this is a from-scratch Swift package with no pre-existing build-verified baseline), so there is no sortie that is purely research/docs work with zero build step. Under the current Workflow-based dispatch engine (`skill.md` § Orchestration Engine, `commands/execution.md` §2), each work unit's sortie chain is dispatched as its own `agent()` call and performs its own build/test verification as part of satisfying its exit criteria — there is no separate, permanently non-building "sub-agent" role distinct from a "supervising agent" the way the classic Task-dispatch model described. The supervisor itself never writes production code or runs builds on a sortie's behalf; it only dispatches and verifies.

**Missed Opportunities**:
- Sorties 6a (Exec/SSH) and 6b (Logs) touch disjoint files (`CLI/Commands/exec.swift`+`ssh.swift` vs. `Logging/*.swift`+`CLI/Commands/logs.swift`) and have no data dependency on each other — both only require Sortie 2's `ContainerService`. They are kept sequential here per the compound-sortie convention (`commands/execution.md` §2b: lettered sorties are ordered sub-sorties of one work unit), which shortens the critical path calculation but is a real, avoidable serialization. Splitting Dev Tools into two independent work units (dropping the 6a→6b ordering dependency) would shorten the critical path from 7 to 6 sorties and raise Layer 3's peak concurrency from 3 to 4 work units — still within the cap. Flagged rather than applied, since it changes work-unit boundaries rather than just sortie content; apply on user request via a follow-up `refine-parallelism` pass if desired.

## Open Questions

_No blocking open questions identified during breakdown._

## Decision Log

<!-- Historical record of blocking open questions resolved during Pass 1 (refine-blockers). Not itself a source of new blockers. -->

### Resolved OQ-1: Hostname-resolution strategy for v1.0 default
> **Superseded in part by OQ-3 and OQ-4:** OQ-1 chose the strategy but not which process hosts the responder. It is hosted by the launchd-managed service process.

**Affected**: Sortie 3, Sortie 4
**Decision**: Local-resolver is the default `HostnameStrategy` for v1.0. Both strategies (local-resolver, `/etc/hosts` rewrite) are still implemented behind a shared protocol; Sortie 3 additionally verifies the resolver actually answers `*.drupal` after registration and falls back to `/etc/hosts` automatically if it does not.
**Basis**: Research spike (dispatched during Pass 1) found Apple's own `container` CLI ships this identical pattern (`container system dns create <domain>`, `/etc/resolver` + a localhost-bound DNS responder on a non-privileged port such as 1053/2053, avoiding root-owned port 53 for the running process — resolver(5) supports a `port` directive for exactly this). `container inspect`-equivalent `Containerization` API calls expose a container's current IP right after `start`, so IP registration on `start` is straightforward.
**Caveat carried into Sortie 3**: A reported macOS 26 regression can break `/etc/resolver` for custom TLDs — this is why Sortie 3 task 5 (verify-then-fallback) exists instead of trusting the resolver unconditionally. `mDNSResponder` caching may also require a `killall -HUP mDNSResponder` after resolver file changes; confirm hands-on during Sortie 3 implementation.
**Sources**: [apple/container networking.md](https://github.com/apple/container/blob/main/docs/networking.md), [apple/container#1302](https://github.com/apple/container/issues/1302), [resolver(5) man page](https://www.manpagez.com/man/5/resolver/), [How Laravel Valet Works Exactly](https://deliciousbrains.com/how-laravel-valet-works-exactly/).

### Resolved OQ-2: `web_environment` / `nodejs_version` scope for v1.0
**Affected**: Sortie 1, Sortie 2
**Decision**: `web_environment` stays in v1.0 scope (Sortie 1 config schema, Sortie 2 env injection). `nodejs_version` is excluded from v1.0 entirely.
**Basis**: `web_environment` already appears in the MVP config file example and the MVP scope table's in-scope column. `nodejs_version` is only conditionally in scope per the requirements doc ("if Drupal's front-end tooling needs it") and no real Drupal composer project has been tried yet to confirm that need — deferred as a fast-follow.

### Resolved OQ-3: Lifetime of the DNS responder
**Affected**: Sortie 3 (amended), Sortie 4, Sortie 8
**Decided**: 2026-09-13, user decision (escalated by the supervisor after Sortie 3)
**Problem**: Sortie 3 built the `*.drupal` DNS responder inside the `drupal` process, so it dies when `drupal start` exits and the local-resolver default cannot work as OQ-1 was written.
**Decision**: Use the Laravel Valet method: a long-lived resolver process registered once via `/etc/resolver/drupal`, which keeps answering between commands. OQ-4 decides which process that is.

### Resolved OQ-4: Owner of the container VMs and the DNS responder
**Affected**: Sorties 2 and 3 (amended), Sortie 8 (new), Sorties 4, 5, 6a, 6b, 7a, 7b
**Decided**: 2026-09-13, user decision
**Problem**: Sortie 2 found `Containerization` containers are VMs owned by the process that starts them, so they die when `drupal start` exits — the same lifetime defect OQ-3 describes for DNS.
**Decision**: One launchd-managed `drupal` process owns **both** the container VMs and the DNS responder. It is the same `drupal` binary running `drupal service run` under a per-user LaunchAgent (`RunAtLoad`, `KeepAlive`). Every other subcommand is a short-lived client that talks to it over a Unix domain socket. This amends the requirements doc's "no separate daemon binary" line: there is still one binary, but v1.0 now has a long-lived service mode.
**Consequences carried into Sortie 8 and later**:
- CLI commands never construct `LiveContainerService` or `LocalDNSServer`. They go through `ServiceClientContainerService`. With no reachable service, they fail with `serviceUnavailable` and never fall back to in-process execution.
- A crash of the service process kills the running containers (the VMs are its children). `KeepAlive` restarts the service, not the containers. `status` must report them as stopped, and `start` recreates them; database data survives on its persistent mount.
- The `/etc/hosts` fallback needs a privileged write on every start, which a user LaunchAgent can't do unattended, so that write stays in the CLI process.
- The `drupal` binary launchd runs must carry the virtualization entitlement, and the plist records its absolute path. Moving or reinstalling the binary requires re-running `drupal service install`.
- Implementation defaults chosen by the supervisor, not the user, and overridable: socket at `~/Library/Application Support/SwiftDrupal/service.sock`, length-prefixed JSON framing, per-user LaunchAgent rather than a root LaunchDaemon.

## Summary

| Metric | Value |
|--------|-------|
| Work units | 8 |
| Total sorties | 10 |
| Open questions | 0 (4 resolved in Decision Log) |
| Dependency structure | layers |
