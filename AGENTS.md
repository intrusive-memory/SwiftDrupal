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

## Status

Requirements only — no implementation yet. `Package.swift` scaffolds an
executable target (product name `drupal`) depending on the `Containerization`
library product from `apple/containerization`.

## Process model (host service)

Containerization VMs and the `*.drupal` DNS responder die with the process
that created them, so one long-lived `drupal service run` process, started by
the per-user LaunchAgent `com.intrusive-memory.swiftdrupal.service`, owns both
(EXECUTION_PLAN.md OQ-3/OQ-4). Code lives in `Sources/SwiftDrupal/Service`.

- Every other command uses `ServiceClientContainerService` over the Unix socket
  `~/Library/Application Support/SwiftDrupal/service.sock` (0600;
  `SWIFTDRUPAL_SERVICE_SOCKET` overrides). Framing is a 4-byte big-endian length
  followed by JSON (`ServiceWire.swift`), with one connection per call.
- Never construct `LiveContainerService` or `LocalDNSServer` outside
  `ServiceRunCommand.run()`. Never fall back to in-process execution. An
  unreachable socket is `DrupalError.serviceUnavailable` (exit 14), and the
  remedy is `drupal service install`.
- The service activates a web container's hostname when it starts it. If
  resolver verification fails, the CLI process writes the `/etc/hosts`
  fallback, because a LaunchAgent cannot do privileged writes unattended.
  Use `startContainer(id:)` to get those warnings.
- `scripts/verify-service-manual.sh` is the manual, non-CI check of a real
  install.

## Platform

Apple Silicon Mac, macOS 26, Xcode 26. This is `Containerization`'s own
floor, not a target to relax.

## Building

```bash
swift build
swift test
```
