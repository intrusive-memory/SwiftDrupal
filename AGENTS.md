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

## Platform

Apple Silicon Mac, macOS 26, Xcode 26. This is `Containerization`'s own
floor, not a target to relax.

## Building

```bash
swift build
swift test
```
