# SwiftDrupal

A standalone Swift CLI (`drupal`) for running a local Drupal development
environment on Apple's [`container`](https://github.com/apple/container)
runtime, built directly on Apple's
[Containerization](https://github.com/apple/containerization) Swift package
rather than on Docker or a compose-file shim.

Early: the config commands (`init`, `config`, `validate`,
`describe-commands`) work; container commands are wired but not yet
implemented. The CLI contract is in [`docs/cli-contract.md`](docs/cli-contract.md). See
[`docs/requirements/`](docs/requirements/) for the full scope:

- [`01-apple-container-capability-survey.md`](docs/requirements/01-apple-container-capability-survey.md) —
  what Apple's `container` tool and `Containerization` framework actually
  support today, and their limits.
- [`02-v1-mvp-requirements.md`](docs/requirements/02-v1-mvp-requirements.md) —
  the decided v1.0 scope: architecture, config-file shape, naming/hostname
  scheme, MVP feature table, and the agent-friendly CLI contract.

## Requirements

Apple Silicon Mac, macOS 26, Xcode 26 — `Containerization`'s own floor, no
fallback for older macOS versions.

## Building

```bash
swift build
```
