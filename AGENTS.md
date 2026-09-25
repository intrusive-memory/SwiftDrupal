# AGENTS.md

Guidance for AI agents working on SwiftDrupal.

## What this is

A standalone Swift CLI, `drupal`, for running a local Drupal development
environment on Apple's `container` runtime via the `Containerization` Swift
package. It is not a DDEV fork and does not depend on Docker.

## Where the requirements live

Read `docs/requirements/02-v1-mvp-requirements.md` before making scope
decisions — it holds the decided v1.0 feature table (in scope vs. explicitly
out of scope), the config-file shape, the naming/hostname scheme
(`<project-name>.drupal`, project name defaulting to the parent directory's
name), and the CLI's agent-friendliness contract (JSON output on every
command, a machine-readable command manifest, non-interactive by default,
idempotent lifecycle commands, distinct exit codes). Read
`docs/requirements/01-apple-container-capability-survey.md` for the
underlying capability research (what `container`/`Containerization` can and
cannot do) that the v1.0 scope is built on.

`docs/cli-contract.md` is the CLI's external contract (JSON envelope, exit
codes, config schema, commands). Keep it in sync with any change to those;
exit codes and envelope fields are only ever appended, never renumbered.

## Status

The container-independent CLI skeleton is built; containers are not.

- Implemented: config model, loading and validation (`.drupal/config.yaml`),
  project-name derivation, `init`, `config`, `validate`,
  `describe-commands`, the JSON envelope, and exit codes.
- Implemented: `<name>.drupal` resolution (`drupal resolver
  install|uninstall|status|serve`) — a built-in DNS responder answering
  from drupal's own hosts file, routed via `/etc/resolver/drupal`;
  `/etc/hosts` is never touched. `start`/`stop`/`delete` keep the hosts
  file in step. See docs/cli-contract.md, "How `<name>.drupal` resolves".
- Implemented: runtime assets (`Runtime/RuntimeAssets.swift`). `start`
  and `restart` call `ensureRuntimeAssets` first, which fetches the pinned
  Kata kernel once (or reuses the `container` CLI's copy) and returns it with
  the vminit reference in `StartOptions.assets`. `Containerization.version`
  must match the `exact:` pin in Package.swift, and a test enforces this.
- Wired but stubbed: `start`, `stop`, `restart`, `status`/`describe`,
  `delete`, `exec`, `ssh`, `logs`, `import-db`, `export-db`. They go through
  the `ContainerRuntime` protocol, whose only implementation,
  `UnimplementedRuntime`, fails with `not_implemented` (exit 12). The next
  step is a Containerization-backed `ContainerRuntime`.

## Layout

- `Sources/DrupalKit/` — all logic, as a library so tests can reach it.
  - `Core/` — `ExitStatus` (every exit code), `DrupalError`, `Envelope`,
    `CLIEnvironment` (task-local cwd/streams/TTY/runtime, injected in tests).
  - `Config/` — `ProjectConfig`, `ConfigParser` (Yams node tree → model,
    with a path and line for every problem), `ConfigValidator`,
    `ConfigWriter`, `ProjectName`, `ProjectLayout`, `ResolvedProject`.
  - `Resolver/` — `HostsFile`, `DNSResponder` (UDP, `.drupal` zone only),
    `ResolverEnvironment` (paths, LaunchAgent, launchd behind
    `ServiceControl`, injected in tests).
  - `Runtime/` — the `ContainerRuntime` protocol and its value types,
    `UnimplementedRuntime`, `RuntimeAssetStore` (kernel + vminit, behind
    `RuntimeAssetProviding`/`KernelFetching`, injected in tests), and the
    host `PlatformChecking`.
  - `CLI/` — `DrupalCLI` (entry point; owns parse errors), `RootCommand`,
    `DrupalCommand` (shared `run()`: output mode, envelope, exit code),
    `Manifest` (generated from ArgumentParser's dump plus reflection), and
    `Commands/`.
- `Sources/SwiftDrupal/` — the thin `drupal` executable.
- `Tests/DrupalKitTests/` — Swift Testing; `Support.swift` runs the real
  command tree in-process against temp dirs and a `FakeRuntime`.

## Conventions

- Commands implement `execute(_:) async throws(DrupalError) -> CommandOutput`
  and never print themselves. Every failure is a `DrupalError` carrying an
  `ExitStatus`.
- No interactive prompts, ever. Destructive or overwriting actions take a
  flag (`--force`, `--keep-data`) instead of asking.
- Keep default kebab-case option names (no `.customLong`): the manifest
  matches flags to Swift property types by name, and `ManifestTests`
  enforces this.

## Platform

Apple Silicon Mac, macOS 26, Xcode 26. This is `Containerization`'s own
floor, not a target to relax.

## Building

```bash
swift build
swift test
```

Install the real binary with `scripts/install.sh`: release build, ad-hoc
codesign with `scripts/drupal.entitlements` (Virtualization.framework needs
`com.apple.security.virtualization`, and `swift build` strips signatures),
copied to `~/.local/bin/drupal`. It restarts the resolver LaunchAgent if
loaded. Then, once per machine: `drupal resolver install` (plus
`sudo drupal resolver install` if `/etc/resolver/drupal` is missing).

`scripts/run-spike.sh` runs the Containerization runtime spike
(`Sources/ContainerSpike/`, findings in
`docs/spikes/01-containerization-runtime-spike.md`); it is not shipped.
