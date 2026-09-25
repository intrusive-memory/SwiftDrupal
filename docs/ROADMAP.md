# SwiftDrupal roadmap

The remaining work to a v1.0 that serves a real Drupal site, in dependency
order. **This is the plan of record**: read it before starting work, and
update it in the same PR that changes the status of an item.

- Scope (what v1.0 is and isn't): [`requirements/02-v1-mvp-requirements.md`](requirements/02-v1-mvp-requirements.md)
- Runtime findings every phase below relies on: [`spikes/01-containerization-runtime-spike.md`](spikes/01-containerization-runtime-spike.md)
- Agent-facing CLI contract: [`cli-contract.md`](cli-contract.md)
- Known gaps recorded by the pre-rewrite implementation (still largely
  applicable; referenced below as G1–G16): `git show
  archive/droplet-shipyard:docs/WORKING_INSTALL_GAPS.md`

Status markers: ✅ done · 🚧 in progress (owner in parentheses) · ⬜ not
started · ❓ blocked on a decision.

## Where things stand (2026-09-25)

| Area | Status |
| --- | --- |
| Config model, validation, `init`/`config`/`validate`/`describe-commands`, JSON envelope, exit codes | ✅ |
| `<name>.drupal` resolution (`drupal resolver …`, `/etc/resolver/drupal`, responder on 127.0.0.1:15353) | ✅ (single macOS account at a time; see Phase 5) |
| Runtime spike: DDEV images run unmodified on Containerization 0.45.0 | ✅ |
| Kernel fetch/verify on first `start` (`ensureRuntimeAssets`, exit 15) | ✅ |
| CI (`swift build`/`swift test`), `make release`, release workflow, `scripts/install.sh` | ✅ |
| Anything that actually runs a container from `drupal` | ⬜ `start` still exits 12 `not_implemented` after fetching the kernel |

Critical path to a first working site: **Phase 1 → Phase 2 → Phase 3**.
Phase 4 can start once Phase 2's socket exists.

## Phase 1 — Containerization runtime (in-process)

Turn the spike into `ContainerizationRuntime`, a real implementation of the
runtime protocol. Keep Containerization types out of the protocol (pre-1.0,
breaking minor releases).

- ✅ Kernel assets: fetch, checksum, cache (`RuntimeAssets.swift`).
- ⬜ vminit `ghcr.io/apple/containerization/vminit:0.45.0`, version-locked to the package pin.
- ⬜ Image pull for **linux/arm64 only** (`pull(reference:platform:)`; `get(pull: true)` fetches every platform).
- ⬜ Rootfs cache: unpack once per image digest, `clonefile(2)` a **fresh copy for every start** (reusing a dirty rootfs hangs ddev-webserver's nginx/php-fpm).
- ⬜ Always write `/etc/hosts` in each container: its own hostname, plus `db → <db IP>` in web (without it, boot stalled 5+ min).
- ⬜ Container specs: web gets `DDEV_PHP_VERSION`, `DDEV_WEBSERVER_TYPE`, `DDEV_PROJECT`, `DDEV_PROJECT_TYPE=drupal`, `VIRTUAL_HOST`, `TZ`, `web_environment`; db runs as the host `uid:gid` (mysqld refuses root).
- ⬜ Health: run the image's `/healthcheck.sh` via exec (Containerization ignores `HEALTHCHECK`); "started" and "ready" are separate states. Watch for G5 (web check also needs Mailpit up — see decision D3) and G6 (checks `sleep 59` once healthy; test `/tmp/healthy` first).
- ⬜ Logs: line-split, host-timestamped, per service; persisted so `logs` can replay.
- ⬜ Exec against an exited container reports "container exited", not vmexec's "No such process".
- ⬜ Absorb and delete the `container-spike` target.

## Phase 2 — Per-project supervisor

VMs, the vmnet network, exec channels and log streams live only as long as
the process that created them, so `drupal start` must leave a process
behind.

- ⬜ Hidden subcommand (same `drupal` binary) that `start` spawns detached, one per project; it owns the `ContainerizationRuntime`.
- ⬜ `SupervisorClient`: the same runtime protocol as JSON over a per-project Unix socket; every other command talks to it. Command code does not change; `FakeRuntime` still covers unit tests.
- ⬜ Lifecycle: idempotent `start` (reuse a live supervisor), `stop` tears containers down and the supervisor exits, stale-socket and crash recovery, `delete`.
- ⬜ ❓ **Per-project pinned subnet** (decision D2): derive from the project name (web `.2`, db `.3`), fall back on collision. Removes macOS's ~10 s stale-DNS window after an IP change.
- ⬜ Register/unregister the hostname from the supervisor (the hosts-file calls already exist in `start`/`stop`/`delete`).

## Phase 3 — Serve a real Drupal site

- ⬜ **Docroot (G8)**: generate DDEV's nginx site config (and the apache-fpm variant) with `root /var/www/html/<docroot>`, mounted at `/mnt/ddev_config/nginx_full` (or `apache/`). Without it `docroot: web` returns 403/404.
- ⬜ ❓ **Drupal DB settings (G11, decision D1)**: generated `sites/default/settings.drupal.php` (`$databases` host `db`, `db/db/db`, `hash_salt`, `trusted_host_patterns`, `skip_permissions_hardening`, `config_sync_directory`) plus a guarded include in `settings.php`, with an opt-out like DDEV's `disable_settings_management`.
- ⬜ **MariaDB persistence (G15)**: block (ext4) volume for `/var/lib/mysql`, not virtiofs; `delete` removes it, `delete --keep-data` keeps it.
- ⬜ Persistent composer/npm cache mount (`/mnt/ddev-global-cache`).
- ⬜ ❓ Mailpit (G5/G10, decision D3).

## Phase 4 — Developer commands on the real runtime

- ⬜ `exec`: buffered (JSON mode) and streaming; TTY for `ssh`.
- ⬜ `logs`: merged by timestamp, `--follow`, `--tail`; text view (colorized; full TUI later) and JSON lines.
- ⬜ `import-db` / `export-db` streamed through exec.
- ⬜ `post_start` against real containers (command-layer logic already exists and is tested).
- ⬜ ❓ `list` of running projects (decision D4).

## Phase 5 — Hardening and UX

- ⬜ Progress output for the first image pull (~439 MB) and kernel download.
- ⬜ `status` shows readiness/health; every failure maps to its documented exit code.
- ⬜ Disk hygiene: rootfs files are 8 GiB sparse; image/rootfs cache pruning.
- ⬜ Several projects running at once (separate subnets; cross-project reachability untested).
- ⬜ **Multiple macOS accounts on one Mac.** `/etc/resolver/drupal` is machine-wide, so only one account's responder can own 127.0.0.1:15353; a second account's LaunchAgent fails to bind (and KeepAlive retries it). Fix options: a shared, group-writable hosts file (e.g. under `/Users/Shared/drupal/`) served by whichever responder is running, or a root LaunchDaemon responder. Until then, run the resolver from one account at a time (see "Working on this machine").

## Phase 6 — Verification

- ⬜ Local end-to-end script: fresh `drupal/recommended-project` → `drupal start` → site install → HTTP 200 at `http://<name>.drupal/` → `export-db`/`import-db` round trip → `stop`/`delete`. GitHub's macOS runners can't run these VMs, so this runs locally, not in CI.
- ⬜ virtiofs performance under `composer install` and a Drupal bootstrap.

## Phase 7 — Release

- ⬜ Homebrew tap formula consuming the tarball `release.yml` already builds.
- ⬜ Signing story for downloaded binaries: ad-hoc signing works for local builds; a downloaded binary may hit Gatekeeper/quarantine (Developer ID + notarization, or rely on Homebrew).
- ⬜ End-user `AGENTS.md` shipped with the tool (requirements, agent-friendly item 7); README; versioning.

## Open decisions

| # | Question | Recommendation |
| --- | --- | --- |
| D1 | May `drupal` add an include line to the project's `settings.php`? (It shows in the user's git diff; DDEV does this with an opt-out.) | Yes, with an opt-out config field. |
| D2 | Pin a per-project subnet so IPs are stable across starts? | Yes. |
| D3 | Mailpit: ensure it runs, or drop it from the health check? | Drop from the health check for v1.0; Mailpit UI is out of scope. |
| D4 | Add `list` (running projects) to v1.0? | Yes, once the supervisor exists; it's cheap. |
| D5 | Keep `web_environment` / `nodejs_version` in v1.0 (requirements OQ #3)? | Keep `web_environment` (already implemented); revisit `nodejs_version` after Phase 6. |

## Working on this machine

Two macOS accounts (`personal`, `stovak`) share this checkout at
`/Users/Shared/SwiftDrupal`.

- **Permissions:** the tree carries an inheritable ACL granting group
  `staff` read/write, so files either account creates stay writable by the
  other regardless of umask, and `core.sharedRepository=group` is set. If a
  file ever shows as not writable, re-apply from the repo root:
  `chmod -R +a 'group:staff allow list,add_file,search,add_subdirectory,delete_child,delete,readattr,writeattr,readextattr,writeextattr,readsecurity,read,write,append,execute,file_inherit,directory_inherit' .`
- **Git ownership check:** git refuses a repository owned by another user.
  Each account other than the owner runs once:
  `git config --global --add safe.directory /Users/Shared/SwiftDrupal`
- **Builds:** don't run two builds in the same `.build` at once. A second
  concurrent session uses its own scratch path:
  `swift build --scratch-path .build-<name>`.
- **Installed binary and resolver are per account:** each account runs
  `scripts/install.sh` (installs to its own `~/.local/bin/drupal`). Only one
  account at a time should run `drupal resolver install` (Phase 5).
- **Branches:** work on `development` or a feature branch off it; `main`
  changes only via PRs from `development`.
