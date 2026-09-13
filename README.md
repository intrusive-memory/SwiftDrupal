---
type: project
---

# SwiftDrupal

[![Swift Package](https://img.shields.io/badge/Package.swift-6.3-orange.svg)](Package.swift)
[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)

A standalone Swift CLI (`drupal`) for running a local Drupal development
environment on Apple's [`container`](https://github.com/apple/container)
runtime, built directly on Apple's
[Containerization](https://github.com/apple/containerization) Swift package
rather than on Docker or a compose-file shim.

## Status

v1.0 is implemented: `init`/`start`/`stop`/`restart`/`status`/`delete`,
`import-db`/`export-db`, `exec`/`ssh`, `logs`, the `drupal service` host
process, and the `describe-commands` machine-readable manifest all exist and
are covered by the test suite. A live end-to-end run against a real Drupal
site is still pending — see
[`AGENTS.md`'s "Unverified live" section](AGENTS.md#unverified-live) for
exactly what that means and why. **A real Drupal site is not expected to
work yet:** [`docs/WORKING_INSTALL_GAPS.md`](docs/WORKING_INSTALL_GAPS.md)
lists the known gaps, including the docroot, the database connection and
UID mapping, in the order to fix them. See [`docs/requirements/`](docs/requirements/)
for the full v1.0 scope:

- [`01-apple-container-capability-survey.md`](docs/requirements/01-apple-container-capability-survey.md) —
  what Apple's `container` tool and `Containerization` framework actually
  support today, and their limits.
- [`02-v1-mvp-requirements.md`](docs/requirements/02-v1-mvp-requirements.md) —
  the decided v1.0 scope: architecture, config-file shape, naming/hostname
  scheme, MVP feature table, and the agent-friendly CLI contract.

## Requirements

Apple Silicon Mac, macOS 26+, Xcode 26+ — `Containerization`'s own floor, no
fallback for older macOS versions.

## Quick start

Full detail (flags, JSON shapes, troubleshooting) lives in
[`AGENTS.md`](AGENTS.md); this is the short version.

```bash
# 1. Build (locally: XcodeBuildMCP's swift_package_build tool; see AGENTS.md
#    "Building the drupal binary" for the CI/no-XcodeBuildMCP equivalent).
#    Then install it at a stable path:
mkdir -p ~/.local/bin
cp .build/out/Products/Debug/drupal ~/.local/bin/drupal   # path varies by build tool

# 2. Sign it with the virtualization entitlement.
codesign --force --sign - --entitlements drupal.entitlements ~/.local/bin/drupal

# 3. Install and start the background service (one-time; prompts for an
#    admin password to register the *.drupal resolver).
drupal service install --json

# 4. Host a Drupal site.
cd ~/Projects/my-drupal-site
drupal init --json
drupal start --json
drupal import-db path/to/dump.sql.gz --json
open http://my-drupal-site.drupal/
```

See [`AGENTS.md`](AGENTS.md) for the full "Config Schema", "Command
Reference", "Common Workflows", "Host prerequisites", "Hosting a Drupal
site", "Running the tests", and "Troubleshooting by exit code" sections.
