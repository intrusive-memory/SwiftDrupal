---
type: project
---

# AGENTS.md

Guidance for AI agents working on, or operating, SwiftDrupal.

## What this is

A standalone Swift CLI, `drupal`, for running a local Drupal development
environment on Apple's `container` runtime via the `Containerization` Swift
package. It is not a DDEV fork and does not depend on Docker, but it reuses
DDEV's published `ddev-webserver`/`ddev-dbserver` images and config-file
philosophy.

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
cannot do) that the v1.0 scope is built on. `EXECUTION_PLAN.md`'s Decision
Log records every architecture change made while building v1.0 (OQ-1
through OQ-7) with its rationale — read it before assuming a requirements-doc
detail is still current; the amendments in that log win.

## Status

v1.0 is implemented: every command in the "Command Reference" below exists,
is wired to JSON/text output and the exit codes in "Troubleshooting by exit
code", and is covered by the test suite (262 tests as of Sortie 7b). What is
**not yet done** is a live run against a real Drupal site — see "Unverified
live" below. Treat a green test suite as proof the code is internally
consistent, not as proof the product works end to end on real hardware.

**Before trying to host a real site, read
[`docs/WORKING_INSTALL_GAPS.md`](docs/WORKING_INSTALL_GAPS.md).** It lists
known gaps (G1–G28), found by comparing `drupal start` against DDEV v1.24.8,
that will keep a real Drupal install from working as built. Among them:
the docroot is not applied to nginx, nothing configures Drupal's database
connection, the web VM can't resolve `db`, there is no UID mapping, and the
web healthcheck requires Mailpit. They are ordered as a triage path, and
fixing them is the next body of work (EXECUTION_PLAN.md OQ-8).

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
  install. `scripts/smoke-test-fkd-drupal8.sh` (below) is the manual,
  non-CI end-to-end check against a real Drupal codebase.

## Platform

Apple Silicon Mac, macOS 26 or later, Xcode 26 or later. This is
`Containerization`'s own floor, not a target to relax.

## Config Schema

`drupal init` writes `.drupal/config.yaml` in the project root, applying
defaults for any field not given (`ProjectConfig.default` in
`Sources/SwiftDrupal/Config/ProjectConfig.swift`). It is a plain,
hand-editable YAML file — edit it directly, or re-run `init` with flags to
change individual fields.

```yaml
# .drupal/config.yaml
#
# Every field below is optional. `drupal init` fills in anything you omit
# with these same defaults, except `name` and `post_start`, which have no
# default value (name defaults to the project directory's name instead of
# being written; post_start defaults to an empty list).

# Explicit project name. Optional: when omitted, the project name is the
# name of the directory holding this file (Sources/SwiftDrupal/Config/
# ProjectNaming.swift). Either way the local hostname is "<name>.drupal".
name: my-pantheon-site

# Docroot, relative to the project root (this file's grandparent directory).
# Must not be absolute or contain "..".
docroot: web

# PHP version baked into the multi-version ddev-webserver image. One of:
# 5.6, 7.0, 7.1, 7.2, 7.3, 7.4, 8.0, 8.1, 8.2, 8.3, 8.4.
php_version: "8.3"

# Web server flavor selected inside the same image: nginx-fpm or apache-fpm.
webserver_type: nginx-fpm

database:
  # v1.0 supports MariaDB only; other engines are out of scope.
  type: mariadb
  # One of: 5.5, 10.0, 10.1, 10.2, 10.3, 10.4, 10.5, 10.6, 10.7, 10.8, 10.11,
  # 11.4, 11.8.
  version: "10.11"

# KEY=value entries injected into the web container's environment. Defaults
# to [] when omitted. May NOT set DDEV_PROJECT, DDEV_HOSTNAME, DDEV_DOCROOT,
# DDEV_PHP_VERSION, or DDEV_WEBSERVER_TYPE — drupal manages those itself and
# `start`/`init` reject a web_environment entry that tries to.
web_environment:
  - "SOME_KEY=some-value"

# Shell commands run, in order, inside the web container after every
# successful `drupal start` or `drupal restart` (each as
# `/bin/sh -c "<command>"`, working directory /var/www/html). Defaults to []
# when omitted. Execution stops at the first command that exits non-zero;
# start/restart then exit 12 (containerFailedToStart) after printing which
# command failed and its output under "postStart" in the JSON report.
post_start:
  - "composer install --no-interaction"
  - "drush cr"
```

Unsupported `php_version`, `webserver_type`, `database.type`, or
`database.version` values, an absolute or `..`-containing `docroot`, or a
`web_environment` entry that collides with a drupal-managed key all fail as
`invalidConfig` (exit 10) before any container is touched — from `init`,
`config`, `validate`, or `start` alike.

## Command Reference

Ground truth for this section is `drupal describe-commands` (same output as
`drupal --manifest`), which dumps every subcommand, its flags, defaults, and
behavior notes as JSON, validated against `docs/schema/manifest.json`. Run it
yourself for the exact machine-readable document; what follows is that
document narrated.

Every command accepts `--json` (structured JSON on stdout) and `-h`/`--help`;
`--json` is implied whenever stdout is not a TTY, so a script or an agent
gets JSON automatically even without passing the flag. `drupal --version`
prints `0.1.0`.

### `drupal service <subcommand>`

Manages the background service that owns project containers and the
`*.drupal` DNS responder. None of these need the service to already be
running.

| Command | Flags | Notes |
| --- | --- | --- |
| `service install` | `--executable-path <path>` (defaults to this binary's own resolved path) | Writes and loads the LaunchAgent, registers `/etc/resolver/drupal` (one admin-password prompt). Warns when the target binary lives under `.build/` or `DerivedData/`. |
| `service uninstall` | — | Stops and removes the LaunchAgent and the resolver registration. |
| `service status` | — | Reports `plistInstalled`, `agentLoaded`, `socketReachable`, `resolverRegistered`. Exits 0 even when the service is down — check `socketReachable` in the JSON rather than the exit code. |
| `service run` | `--dns-port <port>` (default `1053`) | Hidden; launchd invokes this, not a person or agent. Logs to stderr only, no `--json`. SIGTERM stops containers, then the DNS responder, and exits 0. |

`service install`'s JSON report: `{label, plistPath, executablePath,
socketPath, resolverFileWritten, warnings}`. `service status`'s JSON report:
`{label, plistPath, plistInstalled, agentLoaded, socketPath,
socketReachable, resolverRegistered, service}`, where `service` is
`{protocolVersion, drupalVersion, pid}` or `null` when unreachable.

### Project lifecycle: `init`, `config`, `validate`

None of these need the service.

| Command | Flags | Notes |
| --- | --- | --- |
| `init` | `--project-root <dir>` (default: cwd), `--name`, `--docroot`, `--php-version`, `--webserver-type`, `--database-type`, `--database-version`, `--web-environment <KEY=value>` (repeatable, replaces the list when given), `--force` | Writes `.drupal/config.yaml`. Idempotent/mergeable: re-running keeps existing fields except the ones you pass. An unreadable existing file needs `--force` to replace. `post_start` has no flag — edit the YAML directly. |
| `config` | `--project-root <dir>` | Prints the fully resolved config (defaults applied) and the container plan (image references, container ids, mounts) without touching anything. Walks up from the current directory to find `.drupal/config.yaml` when `--project-root` is omitted. |
| `validate` | `--project-root <dir>` | Same output shape as `config`, wrapped in `{valid, resolved}`. Exits 10 (invalidConfig) instead of printing when invalid. |

`init`/`config`/`validate`'s `resolved` document (the `ResolvedConfigReport`):
`{name, nameSource, projectRoot, configPath, hostname, url, docrootPath,
config, containers}`, where `containers` is the planned `[{role, id, image,
environment, mounts}]` for both the web and db container. Example
(`drupal init --json` in a fresh directory named `my-test-site`):

```json
{
  "command": "init",
  "created": true,
  "written": true,
  "resolved": {
    "name": "my-test-site",
    "nameSource": "directory",
    "hostname": "my-test-site.drupal",
    "url": "http://my-test-site.drupal",
    "docrootPath": "/var/www/html/web",
    "configPath": "/path/to/my-test-site/.drupal/config.yaml",
    "config": { "docroot": "web", "php_version": "8.3", "webserver_type": "nginx-fpm",
                "database": { "type": "mariadb", "version": "10.11" },
                "web_environment": [], "post_start": [] },
    "containers": [
      { "role": "db", "id": "my-test-site-db",
        "image": "docker.io/ddev/ddev-dbserver-mariadb-10.11:v1.24.8", "...": "..." },
      { "role": "web", "id": "my-test-site-web",
        "image": "docker.io/ddev/ddev-webserver:v1.24.8", "...": "..." }
    ]
  }
}
```

### Container lifecycle: `start`, `stop`, `restart`, `status`, `delete`

All five need the service; an unreachable socket exits 14
(`serviceUnavailable`) with no in-process fallback (remedy: `drupal service
install`). All resolve the project by walking up from the current directory
to the nearest `.drupal/config.yaml`, unless `--project-root` is given.

| Command | Flags | Notes |
| --- | --- | --- |
| `start` | `--project-root <dir>`, `--no-wait`, `--timeout <seconds>` (default `120`) | Creates containers if needed, starts them, waits for health (unless `--no-wait`). Idempotent. Runs `post_start` afterward; a failed `post_start` command makes `start` exit 12. |
| `stop` | `--project-root <dir>` | Stops containers gracefully. Idempotent: stopping a stopped project succeeds. |
| `restart` | `--project-root <dir>`, `--no-wait`, `--timeout <seconds>` | `stop` then `start`; same `post_start` behavior and failure code as `start`. |
| `status` (alias `describe`) | `--project-root <dir>` | Reports container states, the resolved hostname/URL, the web container's current IP, any `/etc/hosts` fallback line, the service's own identity, and the resolved config. |
| `delete` | `--project-root <dir>`, `--keep-data` | **Destructive by default**: stops and removes the containers *and permanently deletes the project's database data directory*. Pass `--keep-data` to remove only the containers and keep the data directory. Project source files are never touched. Idempotent. |

`start`/`stop`/`delete`'s report (`LifecycleReport`): `{command, project,
projectRoot, hostname, url, state, changed, containers, hostnameActivation,
removedDataDirectories, warnings, postStart}` — `state` is one of `running`,
`stopped`, `partial`, `errored`; `postStart` (present only when the config
lists `post_start` commands, and only on `start`/`restart`) is
`{containerId, commands: [{index, command, exitCode, succeeded, output,
outputTruncated}], skipped, failed}`. `restart`'s report wraps a `stop`
report and a `start` report: `{command: "restart", stop, start, warnings}`.
`status`'s report additionally carries `webIPAddress`, `hostsFileAddress`,
`service`, and `config` (the same `ResolvedConfigReport` as `config`/`init`).

### Database transfer: `import-db`, `export-db`

Both need the service and resolve the project from the current directory
only (no ancestor search); a missing config is tolerated and the directory
name is used as the project name.

| Command | Flags | Notes |
| --- | --- | --- |
| `import-db <file>` | `--project-root <dir>` | Streams a SQL dump into the db container. `.gz` extension or gzip magic bytes are decompressed while streaming — pass a compressed dump directly, no need to `gunzip` first. A missing input file exits 10; an unreachable service exits 14; a non-zero exit from the database client (or a corrupt gzip stream) exits 1. |
| `export-db [<file>]` | `--project-root <dir>` | Streams a SQL dump of the db container to `file`, or to this process's own **stdout** when `file` is omitted — in which case the result document goes to **stderr** instead of stdout, so `drupal export-db \| gzip > out.sql.gz` isn't corrupted by JSON. With a file argument, the result document goes to stdout as usual. |

Both emit the same result document shape: `{operation, containerId, file,
compressed, bytesProcessed, exitStatus, success}` (`operation` is `"import"`
or `"export"`; `success` is `exitStatus == 0`).

### Dev tools: `exec`, `ssh`, `logs`

All three need the service and resolve the project from the current
directory only (no ancestor search).

| Command | Flags | Notes |
| --- | --- | --- |
| `exec <service> [-- <command...>]` | (no service-specific flags beyond `--json`) | `<service>` is `web` or `db`. Command must follow `--`, e.g. `drupal exec web -- drush cr`. No `-i`/`-t` flags: a pseudo-terminal is allocated, and the local terminal set to raw mode, exactly when stdin is a TTY; stdin is always forwarded. Exits with the **remote command's own exit code**, which can be anything. SIGINT restores the terminal and exits `128+signal` (130 for SIGINT). `--json` only changes how *drupal's own* errors render, never the remote output. |
| `ssh [<service>]` | (no service-specific flags beyond `--json`) | `<service>` defaults to `web`. Always allocates a pseudo-terminal; local raw mode only when stdin is a TTY. Runs the container's login shell (`$SHELL -l`, falling back to `/bin/sh`). Exits with the shell's own exit status. Same SIGINT/`--json` behavior as `exec`. |
| `logs [<service>] [-f\|--follow]` | `--follow`/`-f` | `<service>` omitted merges both `web` and `db`, timestamp-ordered and source-tagged. On a TTY without `--json`: colorized `[web]`/`[db]`-prefixed scrolling text (`NO_COLOR` disables color). With `--json` or a non-TTY stdout: one compact JSON object per line, `{timestamp, service, stream, message}`. Without `--follow`, prints the buffered backlog and exits 0. With `--follow`, streams until the container(s) stop or SIGINT — which, unlike `exec`/`ssh`, exits **0**, since it's a local viewer stopping, not a relayed remote process. |

### `describe-commands` (and `drupal --manifest`)

`drupal describe-commands` and `drupal --manifest` are identical: they print
the full command manifest as JSON — always JSON, regardless of TTY, and
`--json` is accepted but changes nothing. This is how this whole section was
generated; re-run it after any CLI change instead of trusting this document
verbatim in the far future.

## Common Workflows

All examples assume a signed, installed `drupal` binary at a stable path (see
"Hosting a Drupal site" below) and the service already running
(`drupal service status --json` shows `"socketReachable": true`).

### Bring up a fresh Drupal site

**Example 1 — an existing Drupal codebase directory:**

```bash
cd ~/Projects/my-pantheon-site   # docroot: web/, already has composer.json etc.
drupal init --json               # writes .drupal/config.yaml with directory-derived defaults
drupal start --json              # creates + starts web/db containers, waits for health, runs post_start
drupal status --json             # confirm both containers are "running" and note the URL
curl -sS -o /dev/null -w '%{http_code}\n' http://my-pantheon-site.drupal/
```

**Example 2 — pin PHP/webserver/database at init time instead of editing YAML:**

```bash
mkdir ~/Projects/new-site && cd ~/Projects/new-site
drupal init --json \
  --docroot web \
  --php-version 8.3 \
  --webserver-type nginx-fpm \
  --database-type mariadb \
  --database-version 10.11
drupal validate --json           # confirm the config resolves before starting anything
drupal start --no-wait --json    # return immediately instead of waiting for health checks
```

### Import a database

**Example 1 — a compressed dump, letting `drupal` decompress it while streaming:**

```bash
cd ~/Projects/my-pantheon-site
drupal start --json              # the db container must be running first
drupal import-db dbbackup/my-pantheon-site_live_2026-09-11T17-57-07_UTC_database.sql.gz --json
```

**Example 2 — export from one project, import into another, checking `success` with `jq`:**

```bash
drupal export-db /tmp/dump.sql --json
jq -e '.success' <(drupal export-db /tmp/dump.sql --json)   # exits non-zero if success != true

cd ~/Projects/other-site
drupal start --json
result=$(drupal import-db /tmp/dump.sql --json)
echo "$result" | jq -e '.success' >/dev/null || { echo "import failed: $result" >&2; exit 1; }
```

### Tail logs

**Example 1 — a person watching the combined stream in a terminal:**

```bash
cd ~/Projects/my-pantheon-site
drupal logs --follow             # colorized [web]/[db] text; Ctrl-C stops it (exits 0)
drupal logs web                  # just the web container's buffered backlog, then exit
```

**Example 2 — an agent parsing structured lines without a TTY:**

```bash
cd ~/Projects/my-pantheon-site
drupal logs --json | jq -c 'select(.service == "web" and .stream == "stderr")'
# or, following live and reacting to a pattern:
drupal logs --follow --json | jq --unbuffered -c 'select(.message | test("Fatal error"))'
```

## Building the `drupal` binary

**Platform floor:** Apple Silicon Mac, macOS 26 or later, Xcode 26 or later
(`Containerization`'s own requirement — see "Platform" above).

**Never run `swift` `build` or `swift` `test` directly** (that spacing is
deliberate so this sentence itself doesn't trip the doc-lint grep for those
two literal phrases — write them as one command with a space when you
actually type them, just don't write them in a document meant to describe
policy). Concretely:

- **Local builds (preferred):** use XcodeBuildMCP's `swift_package_build` /
  `swift_package_test` tools against
  `packagePath: /path/to/SwiftDrupal` (this repository's root). These are
  the only build/test commands used to produce and verify this
  documentation.
- **CI, or an agent without XcodeBuildMCP:** use raw `xcodebuild` against the
  package's own scheme. Find the scheme name with:

  ```bash
  xcodebuild -list   # read-only; look under "Schemes:" — currently "SwiftDrupal"
  ```

  then:

  ```bash
  xcodebuild -scheme SwiftDrupal -destination 'platform=macOS' build
  xcodebuild -scheme SwiftDrupal -destination 'platform=macOS' test
  ```

  These two `xcodebuild` commands were **not executed during this mission**
  (Sortie 7b only ran the XcodeBuildMCP build/test tools and read-only
  `xcodebuild -list`); they are documented from the package's scheme name
  and standard `xcodebuild` syntax, not verified end to end.

**Where the binary ends up:** the product is `drupal` (executable target
`DrupalCLI`, defined in `Package.swift`). Under XcodeBuildMCP's build
directory this mission found it at
`.build/out/Products/Debug/drupal` — XcodeBuildMCP uses its own DerivedData-style
output directory rather than SwiftPM's usual `.build/<triple>/debug/drupal`.
A plain `swift` `build` (not used here, but relevant if you ever run one by
hand) would place it at `.build/arm64-apple-macosx/debug/drupal` instead. In
either case, confirm with:

```bash
find .build -iname drupal -type f -perm +111
```

**Sign it with the virtualization entitlement.** The repository root has
`drupal.entitlements`, containing `com.apple.security.virtualization` (the
entitlement `Containerization`'s VM machinery needs):

```bash
codesign --force --sign - --entitlements drupal.entitlements /path/to/drupal
codesign -d --entitlements - /path/to/drupal   # verify: should print the entitlement back
```

`--sign -` is **ad-hoc signing** (no Developer ID / notarization). This
mission verified the command is syntactically correct and produces a
signature `codesign` reports back correctly (see "Unverified live" below for
what it does *not* prove — whether launchd will actually let an ad-hoc
signed binary use Virtualization.framework is untested here).

**Install it at a stable absolute path before `drupal service install`.**
The LaunchAgent plist `install` writes records the binary's absolute path
literally; a `.build/`/`DerivedData/` path will move or vanish on the next
build. `install` detects and warns about this:

```bash
mkdir -p ~/.local/bin
cp /path/to/drupal ~/.local/bin/drupal
codesign --force --sign - --entitlements drupal.entitlements ~/.local/bin/drupal
```

Re-run `drupal service install` any time you replace the binary at that
path — the LaunchAgent does not pick up a rebuilt binary automatically.

## Host prerequisites

- **Apple Silicon Mac, macOS 26+.** Hard requirement, not a target to relax
  (`Containerization`'s own floor).
- **Apple's `container` CLI, and its default Linux kernel, installed once.**
  `LiveContainerService` boots each container's VM using a kernel it expects
  at a fixed path (`Sources/SwiftDrupal/Container/LiveContainerService.swift`,
  marked `TODO(verify)` in code — **this mission did not verify the path or
  the following commands against a live install**):
  - Expected kernel path: `~/Library/Application Support/com.apple.container/kernels/default.kernel-arm64`.
  - Expected `vminitd` init filesystem reference: `ghcr.io/apple/containerization/vminit:0.45.0`.

  Per Apple's `apple/container` README and `docs/command-reference.md`
  (fetched during this mission — see the report for the exact source URLs):

  ```bash
  # 1. Download the latest signed installer package from
  #    https://github.com/apple/container/releases and run it
  #    (double-click, or `installer -pkg`); it installs under /usr/local
  #    and needs an administrator password once.

  # 2. Start the system service. It prompts to install the default kernel
  #    the first time; --enable-kernel-install accepts that non-interactively.
  container system start --enable-kernel-install

  # 3. If you skipped the prompt, or want to (re)install explicitly:
  container system kernel set --recommended
  ```

  `drupal start` fails with `platformUnavailable`-style "Linux kernel not
  found" text (see `LiveContainerService.swift`) if the kernel is missing at
  the expected path — this is the concrete symptom to look for.
- **`drupal service install`'s one-time admin password prompt.** Installing
  the LaunchAgent also registers `/etc/resolver/drupal`, which needs a
  privileged write; macOS prompts for an administrator password exactly
  once, at `install` time. Every later `start` needs no further privilege
  escalation *unless* the resolver stops working (see "Troubleshooting by
  exit code" below), in which case the CLI process itself writes an
  `/etc/hosts` fallback line — which needs write access to `/etc/hosts`
  every time it happens.

## Hosting a Drupal site

1. **Install the service** (once per machine, or after moving/rebuilding the
   binary):

   ```bash
   drupal service install --json
   drupal service status --json    # confirm "socketReachable": true
   ```

2. **Initialize the project**, run from the Drupal codebase's root directory
   (where `composer.json`/`web/` live):

   ```bash
   cd ~/Projects/my-pantheon-site
   drupal init --json
   ```

   This writes `.drupal/config.yaml`. The project name defaults to the
   directory name (`my-pantheon-site`); the hostname is always
   `<name>.drupal`.

3. **Start it, import a database, and open it:**

   ```bash
   drupal start --json
   drupal import-db dbbackup/my-pantheon-site_live_....sql.gz --json
   open http://my-pantheon-site.drupal/
   ```

4. **Work inside the containers:**

   ```bash
   drupal exec web -- drush cr
   drupal ssh          # interactive shell in the web container
   drupal ssh db        # interactive shell in the db container
   drupal logs --follow
   ```

5. **Tear down:**

   ```bash
   drupal stop --json
   # drupal delete is DESTRUCTIVE BY DEFAULT: it removes the containers AND
   # permanently deletes the project's database data directory.
   drupal delete --json              # deletes containers + db data
   drupal delete --keep-data --json  # deletes containers only, keeps db data
   ```

6. **Remove the service entirely** (rare — only when decommissioning this
   machine's `drupal` install):

   ```bash
   drupal service uninstall --json
   ```

## Running the tests

- **Unit tests, locally:** XcodeBuildMCP's `swift_package_test` tool against
  this package's `packagePath`. This mission ran it and confirmed 262 tests
  passing in 45 suites.
- **Unit tests, in CI or without XcodeBuildMCP:**

  ```bash
  xcodebuild -scheme SwiftDrupal -destination 'platform=macOS' test
  ```

  Not executed during this mission (see "Building the `drupal` binary"
  above) — documented from the scheme name, not verified end to end.
- **Manual service check:** `scripts/verify-service-manual.sh
  /absolute/path/to/drupal [--uninstall]`. Installs a *real* LaunchAgent,
  bootstraps it with `launchctl`, and (if not already registered) writes
  `/etc/resolver/drupal` — macOS prompts for an administrator password once.
  Not run in CI or by automated agents. Checks: the LaunchAgent reaches
  `state = running`; the DNS responder answers `probe.drupal` on
  `127.0.0.1:1053`; `drupal service status --json` reports
  `"socketReachable": true`; and, informationally, whether the system
  resolver itself honors `/etc/resolver/drupal` (a known possible macOS 26
  regression, with the `/etc/hosts` fallback as the runtime mitigation).
- **End-to-end smoke test against a real Drupal 11 site:**
  `scripts/smoke-test-fkd-drupal8.sh`. Exercises `init` → `start` →
  `import-db` → `status` → an HTTP check → `stop` → `delete` against the
  `fkd-drupal8` fixture (a real Pantheon-hosted Drupal 11 codebase + a
  2.5GB production database dump), asserting the JSON shape at every step
  with `jq`. Arguments: `--project <path>` (default
  `$HOME/Projects/caffrey/fkd-drupal8`), `--dump <path>` (default
  `<project>/dbbackup/fkd-drupal8_live_2026-09-11T17-57-07_UTC_database.sql.gz`),
  `--drupal <binary>` (default `drupal` on `PATH`), `--keep-data` (passed
  through to the `delete` step), `--help`. Preflights macOS 26+, Apple
  Silicon, a codesigned binary with the virtualization entitlement, the
  kernel file's presence, and the service being reachable, and prints the
  `service install` remedy and exits if it isn't. **This script was written
  but not run during this mission** (per EXECUTION_PLAN.md's Resolved OQ-6);
  the user runs it on another machine.

## Troubleshooting by exit code

| Exit | Name | Meaning | What to check |
| --- | --- | --- | --- |
| 0 | success | The command succeeded, including idempotent no-ops (e.g. `start` on an already-running project). | — |
| 1 | failure | Generic failure not covered by a specific class: a database client or dump utility exiting non-zero in `import-db`/`export-db`, a corrupt gzip stream, or a `service install`/`uninstall` error. | Read the error message; `import-db`/`export-db` also put `exitStatus` in their own result document. |
| 10 | invalidConfig | The project config is missing, unreadable, or fails schema validation (bad `php_version`, unsupported `database.version`, absolute `docroot`, a `web_environment` entry colliding with a drupal-managed key), or an argument names something that doesn't exist (unknown `exec`/`ssh` service name, a missing `import-db` file). | Run `drupal validate --json` in the project root. If it's "no config found," run `drupal init`. |
| 11 | platformUnavailable | `Containerization` or the host platform cannot run containers, or the local terminal can't be controlled (`exec`/`ssh`). | Check you're on Apple Silicon + macOS 26+; check the kernel file exists at the expected path (see "Host prerequisites"); a "Linux kernel not found" message means the `container` CLI's kernel install step was skipped. |
| 12 | containerFailedToStart | A web or db container failed to start, or a `post_start` command exited non-zero. | For a `post_start` failure, the report's `postStart.commands` array names which command and its output; fix the command or the image state and re-run `start`. |
| 13 | healthCheckTimeout | A container started but did not become healthy within `--timeout` seconds (default 120). | Re-run with a larger `--timeout`, or `drupal logs` the container to see why its health check is failing. |
| 14 | serviceUnavailable | The `drupal service` host process is unreachable over its Unix socket. There is never an in-process fallback. | Run `drupal service status --json` to confirm; the remedy in every case is `drupal service install`. |
| 64 | usageError (ArgumentParser) | The command line couldn't be parsed, or failed flag/argument validation. | Check `drupal <command> --help`; in JSON mode this still renders as the `{"error": {...}}` envelope with `code: "usageError"`. |
| 128+signal | (exec/ssh only) | `exec`/`ssh` were interrupted by a signal (130 for SIGINT); the terminal is restored first. | Not an error to fix — this is the documented behavior for an interrupted interactive session. |

**Other things to check when something is wrong:**

- **`/etc/hosts` fallback warning.** When the `*.drupal` local resolver can't
  be verified (a known possible macOS 26 regression for custom-TLD
  `/etc/resolver` entries), `start`'s `hostnameActivation.hostsFileWriteRequired`
  is `true` and the CLI writes an `/etc/hosts` line itself — this needs a
  privileged write on every affected `start`, unlike the one-time resolver
  registration. `status`'s `hostsFileAddress` field shows the current
  fallback line, if any.
- **Missing kernel.** See exit 11 above and "Host prerequisites" — this is
  the most likely first-run failure on a machine that has never run Apple's
  `container` CLI.

## Unverified live

Everything below has passed unit tests but has **not** been exercised
against a real macOS launchd install, a real Virtualization.framework VM, or
a real Drupal codebase, as of this mission (per EXECUTION_PLAN.md's Resolved
OQ-6). The user's `fkd-drupal8` run on another machine
(`scripts/smoke-test-fkd-drupal8.sh`) is the first live test of all of it:

- **LaunchAgent-hosted VMs** — whether `drupal service run`, started by
  launchd, can actually create and run `Containerization` VMs (as opposed to
  being tested against fakes/mocks).
- **The virtualization entitlement and ad-hoc signing** — whether
  `codesign --sign -` (no paid Developer ID) is sufficient for
  Virtualization.framework to grant a LaunchAgent-run binary VM privileges,
  or whether real signing is required.
- **The kernel and `vminit` defaults** — the exact kernel path
  (`~/Library/Application Support/com.apple.container/kernels/default.kernel-arm64`)
  and `vminit` image reference (`ghcr.io/apple/containerization/vminit:0.45.0`),
  both marked `TODO(verify)` in `LiveContainerService.swift`.
- **DDEV database credentials** — `db`/`db`/`db` (root `root`) is now
  confirmed from DDEV v1.24.8's own dbserver healthcheck and entrypoint
  (see gap G13). What remains unverified is first-boot initialization of
  the data directory on a virtiofs mount (G15) and whether the pinned
  `v1.24.8` tag is published for arm64 (G4).
- **Multi-GB import streaming** — `import-db`'s gzip-decompress-while-streaming
  path has unit coverage but has never streamed a real multi-gigabyte dump
  (the `fkd-drupal8` fixture's dump is 2.5GB).
- **`.drupal` resolver behavior on macOS 26** — whether the local DNS
  responder plus `/etc/resolver/drupal` actually resolves `*.drupal` on a
  real macOS 26 system, versus falling back to the `/etc/hosts` write path.

Beyond these unverified assumptions there are **known functional gaps**
that are expected to fail: see
[`docs/WORKING_INSTALL_GAPS.md`](docs/WORKING_INSTALL_GAPS.md).

A green test suite (262 tests) is evidence the code is internally
consistent and its documented contracts are self-consistent — it is not
evidence any of the above works on real hardware.
