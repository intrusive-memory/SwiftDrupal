# Swift/Containerization Drupal tool — v1.0 requirements

Working draft. Supersedes the architecture question left open in
[01-apple-container-capability-survey.md](01-apple-container-capability-survey.md): this
pivots from "add an Apple `container` backend to DDEV" to a **standalone
Swift/Xcode CLI application**, built directly on Apple's `Containerization`
Swift package, whose only job is running a local Drupal development
environment. It is not a DDEV fork or a DDEV backend — it reuses DDEV's
existing container images and config-file philosophy, but the orchestrator
itself is new and Swift-native.

## Why standalone Swift instead of a DDEV backend

A prior pass considered adding Apple `container` as one more runtime DDEV's
Go code could target, the way it targets Docker Desktop, Colima, or Podman
today. That does not fit: DDEV's Go code depends on the Docker Engine API
and the `docker/compose` Go library directly (see the prior draft's survey
of `pkg/dockerutil` and `pkg/ddevapp`), and Apple `container` exposes neither
— there is no Docker socket compatibility and no official compose
implementation to target instead. Bridging that gap from Go means routing
through a third-party shim (Socktainer for the socket, `opossum` or
`Container-Compose` for compose semantics), and both community shims
explicitly do not support custom `networks:` blocks or `container_name` —
exactly what a DDEV-style router pattern needs.

Apple ships the lower layer those shims themselves would have to wrap:
`Containerization`, a public Swift Package Manager library (confirmed from
its readme) that exposes the VM lifecycle directly — OCI image handling,
`ext4` filesystem creation, per-container dedicated IP addresses, and
process spawning through `vminitd`'s gRPC-over-vsock interface. A standalone
Swift app built on that library gets structured, in-process control over
the same primitives Apple's own `container` CLI uses, instead of going
through a CLI, a socket shim, or a compose-file interpreter that was not
built by Apple.

## Architecture decision: own orchestration, not a compose wrapper

**Decision: go our own way.** Do not wrap `container-compose`,
`opossum`, or any other community compose shim.

Reasons:

1. No official `container-compose` exists, and the community substitutes
   are immature by their own admission — they skip the exact features
   (custom networks, `container_name`) this tool needs.
2. Wrapping an external CLI or shim means DDEV-equivalent's reliability
   depends on a project it does not control and that could go stale or be
   abandoned.
3. Building directly on `Containerization` gives typed, structured access
   to VM/container lifecycle from within the same process — better suited
   to an agent-friendly CLI that needs precise, scriptable behavior than
   another layer of CLI-argument or YAML-interpretation indirection.
4. `Containerization`'s per-container dedicated-IP networking feature
   removes the need to reproduce DDEV's shared-bridge-network-plus-alias
   router model for a single-project MVP (see "Networking" below) — a
   simplification only available by working at this level directly.

The cost of this decision: DDEV-equivalent owns the equivalent of a
compose interpreter — reading a project's declared services and desired
state and turning that into `Containerization` API calls — rather than
reusing one. Scope below is deliberately narrow so that surface stays
small for v1.0.

## Platform requirement

Apple Silicon Mac, macOS 26, Xcode 26 — `Containerization`'s own stated
floor, with no fallback for older macOS versions. This is a hard
requirement, not a target to relax later.

## Confirmed pattern: one declarative config file per project

DDEV's `.ddev/config.yaml` is the model to follow. A real example from this
repository's test fixtures
(`cmd/ddev/cmd/testdata/TestUtilityDiagnoseCmd/ProjectWithCustomizations/.ddev/config.yaml`):

```yaml
#ddev-generated
name: test-diagnose-custom
type: php
docroot: web
php_version: "8.2"
webserver_type: nginx-fpm
xdebug_enabled: false
additional_hostnames: []
additional_fqdns: []
database:
  type: mariadb
  version: "10.11"
use_dns_when_possible: true
composer_version: "2"
web_environment: []
nodejs_version: "20"
```

This single file drives image selection, compose generation, and router
configuration in DDEV today. The new tool should follow the same shape: one
YAML file per project, plain enough for a person or an agent to hand-edit,
covering exactly the fields the MVP scope below needs — not the full field
list DDEV has accumulated over years (see "Explicitly out of scope").

## Naming, hostname, and the binary (decided)

1. **Project name defaults to the parent directory's name.** The directory
   holding the Drupal codebase (the project root, where the config file
   lives) names the project — chosen to match how a site's folder is
   typically named after its machine name in a hosting dashboard such as
   Pantheon's, so the local project name and the hosting-side name agree
   without a separate field to keep in sync. Still overridable by an
   explicit `name:` entry in the config file for the rare case where the
   directory name is not the wanted project name.
2. **Local hostname is `<name>.drupal`.** Derived automatically from the
   project name; not a field a person or agent needs to set for the common
   case.
3. **The executable is named `drupal`.** A single binary, `drupal`,
   providing the full command surface (`drupal init`, `drupal start`,
   `drupal logs`, and so on) — no separate daemon binary or wrapper script
   for v1.0.

`.drupal` is not a delegated public TLD or one of the reserved
special-use TLDs (`.test`, `.localhost`, and similar, per RFC 6761), so
nothing resolves it without help, and `Containerization` assigns each
container's IP per run rather than a fixed address DDEV-style Docker
networking would. Two ways to make `<name>.drupal` resolve, in preference
order:

- **A local resolver process (preferred).** The `drupal` binary runs a
  small DNS responder bound to `127.0.0.1` that answers `*.drupal`
  queries with the current web container's dedicated IP, registered with
  macOS once via a `/etc/resolver/drupal` file pointing at it. One-time
  setup needs elevated privileges; every subsequent `start` (even with a
  new container IP) needs none, which matters for an agent driving this
  unattended. This is the same technique tools like Laravel Valet use for
  their own pseudo-TLD.
- **A rewritten `/etc/hosts` entry on every start (fallback).** Simpler to
  build, but needs a privileged write on every `start`, not just once —
  worse for unattended agent use, and the fallback if the resolver
  approach proves impractical.

## v1.0 goal

A working, agent-friendly, Drupal-only local development environment: one
web container (PHP + web server) and one database container, built from
DDEV's existing published images, orchestrated by a Swift CLI running on
`Containerization` instead of Docker.

## Container topology (v1.0)

Reuse DDEV's existing, already-published images unmodified — they are OCI
images and `Containerization` is OCI-compliant, so no image rebuild is
needed for v1.0:

- **web** — `ddev-webserver` (nginx-fpm or apache-fpm + PHP-FPM), selected
  PHP version and web server type chosen by picking the matching published
  tag, not by building a custom image.
- **db** — `ddev-dbserver`, MariaDB only for v1.0, selected version chosen
  the same way.

No router/proxy container in v1.0. `Containerization` assigns each
container its own dedicated IP; the local resolver described above points
the project's one hostname, `<name>.drupal`, straight at the web
container's current IP. This replaces DDEV's
shared-bridge-network-plus-Traefik model for the single-project case; a
shared router is only needed once multiple projects must share ports
80/443 concurrently, which is out of scope for v1.0 (see below).

An MVP config file, reduced to what v1.0 actually reads (project name and
hostname both derived, not written):

```yaml
docroot: web
php_version: "8.3"
webserver_type: nginx-fpm
database:
  type: mariadb
  version: "10.11"
web_environment: []
```

With this file sitting in a directory named, say, `my-pantheon-site`, the
project name is `my-pantheon-site` and the site is reachable at
`my-pantheon-site.drupal`.

## MVP scope

| Area | In scope for v1.0 | Out of scope for v1.0 |
| --- | --- | --- |
| Project lifecycle | `init`/`config` (write the YAML), `start`, `stop`, `restart`, `status`/`describe`, `delete` | `list` across projects, `poweroff`, `clean`, `pause`/idle auto-stop |
| Containers | web (PHP-FPM + nginx-fpm or apache-fpm), db (MariaDB) | router/Traefik, `ddev-ssh-agent`, Mailpit, XHGui, add-on services (Redis, Solr, Elasticsearch, Memcached, Varnish) |
| Config file | Single YAML: name, docroot, `php_version`, `webserver_type`, database type/version (MariaDB only), one hostname, `web_environment` | Full DDEV field set — `WebExtraExposedPorts`/`WebExtraDaemons`, `OmitContainers`, `WorkingDir` overrides, `DdevVersionConstraint`, timezone, etc. |
| Database | Single-engine (MariaDB), one version per project, `import-db`/`export-db` via a plain SQL dump | MySQL/PostgreSQL engines, version migration (`debug migrate-database`), volume-level snapshots/restore, seed-from-snapshot on start |
| File sync | Direct virtiofs bind mount of the project directory | Mutagen-equivalent two-way sync, NFS mode, any performance-mode selection |
| Networking | `<name>.drupal` hostname via a local resolver process, plain HTTP | HTTPS/TLS (mkcert or custom certs), multi-project shared router, additional hostnames beyond the one derived name, `ddev share`/tunneling, `BindAllInterfaces`, extra exposed ports/daemons |
| Dev tools | `exec` (run a command in the web or db container), `ssh`/shell-in, `logs` (combined multi-container stream, TUI and agent-readable modes — see below) | Xdebug, XHGui/XHProf, Blackfire, dedicated `composer`/`drush` subcommands (use `exec` instead) |
| Extensibility | A minimal `post_start` command list (agent-oriented automation hook only) | Full hooks system (`pre_start`/`pre_exec`/etc. with `fail_on_hook_fail`), custom Dockerfile extension (`.ddev/web-build`/`.ddev/db-build`), `webimage_extra_packages`/`dbimage_extra_packages`, custom compose overrides, custom user commands (`.ddev/commands/`) |
| Add-ons/ecosystem | — | `ddev get`/add-on system entirely; any third-party service integration |
| Hosting providers | — | `pull`/`push` and all provider plugins (Pantheon, Platform.sh, Upsun, Acquia, Lagoon) |
| Global/multi-project | Single project at a time is an explicit v1.0 assumption | `config global`, cross-project telemetry, auto-restart-on-reboot, `dotenv`/global env management |
| Project types | Drupal only | WordPress, Laravel, TYPO3, Craft CMS, Magento, and the ~10 other project types DDEV supports |
| Node.js | Basic `nodejs_version` passthrough only if Drupal's front-end tooling needs it | Corepack management, Vite dev-server integration |
| Platform | macOS 26, Apple Silicon | Linux, Windows, Intel Mac, older macOS |

Everything in the right-hand column is a plausible fast-follow, not a
rejected idea — it is marked out of scope specifically so v1.0 stays a
provable "does this architecture work at all" milestone before any of it
is built.

## Logs: combined stream and TUI

`drupal logs` reads both containers' log streams at once (web and db —
`Containerization`'s equivalent of `docker logs`, per container) and
merges them by timestamp into one interleaved stream tagged by source,
rather than requiring separate commands or terminal panes per container.

Two output modes, chosen the same way as the rest of the agent-friendly
contract:

- **Interactive/TTY: a text UI.** A scrolling, colorized-by-source view in
  the terminal — one merged, readable stream instead of interleaved raw
  output from two containers at once.
- **Non-TTY or `--json`: structured lines.** One JSON object per log line
  (`{"timestamp": ..., "service": "web"|"db", "stream": "stdout"|"stderr",
  "message": ...}`), so an agent can `drupal logs --json | grep`/parse
  without reverse-engineering TUI escape sequences or redraw behavior —
  the TUI is for a person watching, the JSON stream is for a program
  reading.

## Agent-friendly CLI requirements

The primary operator of this tool is expected to be an AI coding agent
(Claude Code or similar), with a person supervising — so the CLI's contract
matters as much as its features:

1. **Structured output on every command.** A `--json` flag (or JSON as the
   default when not attached to a TTY) on every subcommand, with a stable,
   documented schema — DDEV's own `root_help_json`/`-j` pattern is the
   precedent to follow.
2. **A machine-readable command manifest.** One command
   (`--manifest`/`describe-commands`, naming open) that dumps every
   subcommand, its flags, and their types and descriptions as JSON, so an
   agent can discover the tool's surface without parsing help text meant
   for people.
3. **Non-interactive by default.** No prompts unless a flag explicitly asks
   for interactive mode; every command must be scriptable with flags alone.
4. **Idempotent lifecycle commands.** Running `start` on an already-started
   project, or `stop` on an already-stopped one, succeeds rather than
   erroring.
5. **Distinct, documented exit codes** for distinct failure classes —
   invalid config, `Containerization`/platform unavailable, container
   failed to start, timeout waiting for health — so an agent can branch on
   the failure without string-matching stderr.
6. **A `config --json`/`validate` introspection command** that prints the
   fully resolved configuration (including any defaults applied), so an
   agent can confirm what will actually happen before running `start`.
7. **An agent-instructions file shipped with the tool itself** — an
   `AGENTS.md` in the new tool's own repository root, following the same
   pattern this repository uses, covering the config schema, the command
   surface, and common workflows (bring up a fresh Drupal site, import a
   database, tail logs) — so an agent operating the tool has the same kind
   of onboarding this repository gives one working on DDEV itself.
8. **Plain, hand-editable YAML config**, matching DDEV's file, not a binary
   or generated-only format, so an agent can read and modify project
   configuration directly with normal file tools.

## Open questions

1. Name for the new tool's repository/project — separate from the
   `drupal` binary name, which is decided; not addressed here.
2. ~~Local resolver vs. `/etc/hosts`~~ — **decided: local resolver.**
   `drupal resolver serve` answers `*.drupal` on 127.0.0.1:15353 from
   drupal's own hosts file (`~/Library/Application Support/drupal/hosts`,
   rewritten by every `start`/`stop`), routed there by a one-time
   `/etc/resolver/drupal`. `/etc/hosts` is never touched. See
   `docs/cli-contract.md`. Still to confirm against the runtime spike:
   that the host can reach container IPs directly.
3. Whether `web_environment`/`nodejs_version` passthrough is needed for a
   first working Drupal site, or can move to the out-of-scope column too —
   revisit once a real Drupal composer project is tried against v1.0.
