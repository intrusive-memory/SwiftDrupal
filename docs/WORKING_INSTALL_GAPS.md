---
type: docs
updated: 2026-09-13
---

# Gaps Between SwiftDrupal v1.0 and a Working Drupal Install

> **Terminology**: a *mission* is a scope of work; a *sortie* is one agent's atomic task within it. This document came out of OPERATION DROPLET SHIPYARD (iteration 1). See [EXECUTION_PLAN.md](../EXECUTION_PLAN.md) OQ-8.

## Why this document exists

Every sortie in the mission passed its tests (262 unit tests), but **nothing has ever run against a real `Containerization` runtime**. When the supervisor compared what `drupal start` launches with what DDEV v1.24.8 actually gives the same images, it found gaps that will keep a real Drupal site from serving. The user chose to fix them on another Apple-silicon machine where the stack can run live (OQ-6, OQ-8), and not to add speculative sorties here.

**Audience**: the agent (or person) on that machine. Work top to bottom: section order is triage order, and each later layer depends on the earlier ones working.

**Evidence labels:**
- **[DDEV source]**: read from `github.com/ddev/ddev` at tag `v1.24.8` during this mission. Paths are given.
- **[SwiftDrupal source]**: read from this repository at the mission branch head.
- **[Unverified]**: an inference or a TODO in code; confirm it live before acting on it.

**Expected smoke-test outcome today**: `scripts/smoke-test-fkd-drupal8.sh` fails no later than its HTTP check, and quite possibly at `start` (layers 0–1).

---

## Layer 0: Platform (can a VM start at all?)

### G1. vmnet networking from a user LaunchAgent. **Blocking; verify first.**
- **What:** `LiveContainerService` creates `VmnetNetwork()` inside `drupal service run`, a per-user LaunchAgent [SwiftDrupal source: `Sources/SwiftDrupal/Container/LiveContainerService.swift`]. `vmnet.framework` usually requires the restricted `com.apple.vm.networking` entitlement or root. Apple's own `container` tool runs networking in separate helpers that Apple signs. **[Unverified]** whether an ad-hoc-signed binary with only `com.apple.security.virtualization` (`drupal.entitlements`) can create a vmnet network on macOS 26.
- **Symptom:** `start` exits 11 with `cannot initialize Containerization: …`, or containers boot with no IP address, so `start` warns that the service did not activate `<name>.drupal`.
- **Verify:** `drupal service install`, then `drupal start --json`. Read `containers[].ipAddress` and the service's stderr log.
- **Fix options:** (a) run networking through Apple's `container` network helper or its XPC service instead of in-process vmnet; (b) acquire the entitlement; (c) run the service as a root LaunchDaemon. That changes OQ-4, so it needs a user decision.

### G2. Virtualization entitlement with ad-hoc signing under launchd. **Blocking if wrong.**
- **What:** docs sign with `codesign --sign - --entitlements drupal.entitlements` (a local, ad-hoc signature). **[Unverified]** that Virtualization.framework accepts ad-hoc signatures for a launchd-spawned process.
- **Verify:** `codesign -d --entitlements - ~/.local/bin/drupal`, then `start`. A signature or entitlement failure surfaces as exit 11.

### G3. Kernel and `vminit` defaults.
- **What:** kernel at `~/Library/Application Support/com.apple.container/kernels/default.kernel-arm64` (installed by Apple's `container` CLI); initfs `ghcr.io/apple/containerization/vminit:0.45.0`. Both carry `TODO(verify)` [SwiftDrupal source: `LiveContainerService.swift`]. `Package.swift` pins `containerization` `from: "0.1.0"`, and the `vminit` tag must match the resolved package version.
- **Verify:** `ls` the kernel path after `container system start --enable-kernel-install`. A pull failure for `vminit` surfaces at `start`.

### G4. Image pulls: tags, architecture, rate limits.
- **What:** images `docker.io/ddev/ddev-webserver:v1.24.8` and `docker.io/ddev/ddev-dbserver-mariadb-<ver>:v1.24.8`. `releaseTag` carries `TODO(verify)` for linux/arm64 [SwiftDrupal source: `DDEVImageCatalog.swift`]. Pulls are anonymous (no registry auth support), so Docker Hub's anonymous pull limit applies, and the webserver image is large.
- **Symptom:** exit 12 `failed to pull …`.
- **Fix:** confirm the tags exist for arm64. If rate limits bite, add registry credentials support.

---

## Layer 1: Containers become healthy

### G5. Web healthcheck requires Mailpit. **Likely blocking.**
- **What:** `/healthcheck.sh` in ddev-webserver passes only when `/var/www/html` is listable **and** `curl 127.0.0.1/phpstatus` succeeds (fpm types) **and** `curl 127.0.0.1:8025` (Mailpit) succeeds [DDEV source: `containers/ddev-webserver/ddev-webserver-base-scripts/healthcheck.sh`]. `start` uses exactly this probe (`HealthProbe.ddevHealthcheck`) [SwiftDrupal source: `Container/HealthCheck.swift`]. The image installs Mailpit, but **[Unverified]** whether its supervisord config starts Mailpit when the container runs outside DDEV.
- **Symptom:** `start` exits 13 after 120 s even though nginx and PHP are up.
- **Verify:** `drupal exec web -- /healthcheck.sh; echo $?` and `drupal exec web -- supervisorctl status`.
- **Fix:** start Mailpit, or use a SwiftDrupal-specific probe (phpstatus + mount) and treat Mailpit as optional.

### G6. Healthchecks sleep 59 s once healthy.
- **What:** both DDEV healthchecks `sleep 59` if `/tmp/healthy` exists [DDEV source: web `healthcheck.sh`, `containers/ddev-dbserver/files/healthcheck.sh`]. On a repeat `start` against running containers, each probe exec blocks about 59 s. Worst case is about 2 minutes with both containers, which brushes against the default 120 s `--timeout`.
- **Fix:** probe `test -f /tmp/healthy` first, or skip the health wait for containers that were already running (`wasRunning == true`).

### G7. Web start script expects DDEV's per-project image.
- **What:** DDEV never runs the stock images. It builds `<image>-<site>-built` with build args `username`, `uid`, `gid`, and runs web and db as `user: '$DDEV_UID:$DDEV_GID'` [DDEV source: `pkg/ddevapp/app_compose_template.yaml`]. The stock web image has no `USER`, so it runs as root. `start.sh` uses `sudo` and `id -u -n` and chowns `/mnt/ddev-global-cache` and `/var/lib/php` [DDEV source: `ddev-webserver-base-scripts/start.sh`]. SwiftDrupal runs the stock images with their default user and CMD `/start.sh` [SwiftDrupal source: `ContainerSpecBuilders.swift`, `command: nil`].
- **Symptom:** **[Unverified]** probably boots as root, but PHP-FPM, file ownership and home-directory setup differ from DDEV (see G11).
- **Verify:** `drupal exec web -- id`, and `drupal logs web` for start.sh errors.

---

## Layer 2: The web server serves Drupal

### G8. Docroot is ignored; nginx serves the project root. **Blocking.**
- **What:** the image's default site config has `root /var/www/html;` [DDEV source: `ddev-webserver-base-files/etc/nginx/sites-enabled/nginx-site-default.conf`]. `start.sh` never reads `DDEV_DOCROOT`. It copies `/mnt/ddev_config/nginx_full` or `/mnt/ddev_config/apache` over the defaults when they exist, and DDEV generates those files with the real docroot. SwiftDrupal only sets `DDEV_DOCROOT` and mounts no `/mnt/ddev_config` [SwiftDrupal source: `WebContainerSpecBuilder`].
- **Symptom:** with `docroot: web` (the default, and fkd-drupal8's), `http://<name>.drupal/` returns 403/404 instead of Drupal.
- **Fix:** generate an nginx site config (and an apache variant) with `root /var/www/html/<docroot>`, and share it into the web container as `/mnt/ddev_config/nginx_full/nginx-site.conf` (or `apache/`).

### G9. Host access is plain HTTP to the VM IP, with no router.
- **What:** DDEV reaches web through `ddev-router` (Traefik) with `HTTP_EXPOSE`/`HTTPS_EXPOSE` and `VIRTUAL_HOST`. SwiftDrupal points `<name>.drupal` at the web VM's IP on port 80 [SwiftDrupal source: `Service/ServiceHost.swift`]. **[Unverified]** host→VM routing over vmnet, and whether `/etc/resolver/drupal` works for a custom TLD on macOS 26 (the known regression; the fallback writes `/etc/hosts` with an admin prompt).
- **Verify:** `curl -sI http://<web-ip>/`, then `curl -sI http://<name>.drupal/`, then `dscacheutil -q host -a name <name>.drupal`.

### G10. Mail goes nowhere visible.
- **What:** DDEV's `settings.ddev.php` points Drupal's mailer at Mailpit and the router exposes the Mailpit UI. SwiftDrupal exposes neither. Low priority, but see G5.

---

## Layer 3: Drupal reaches its database

### G11. Nothing configures Drupal's database connection. **Blocking.**
- **What:** DDEV writes `sites/default/settings.ddev.php` (plus a guarded include in `settings.php`, unless `disable_settings_management`) containing: `$databases['default']['default']` with host `db`, port 3306, database/user/password `db`, driver `mysql`; `hash_salt`; `state_cache`; `skip_permissions_hardening = TRUE`; `trusted_host_patterns = ['.*']`; `config_sync_directory` fallback; and Mailpit mailer overrides [DDEV source: `pkg/ddevapp/drupal/drupal10/settings.ddev.php`]. SwiftDrupal generates no settings file and injects no DB variables into the web container [SwiftDrupal source: `WebContainerSpecBuilder.build()`; grep for `settings.ddev`, `DB_HOST` finds nothing].
- **Symptom:** Drupal shows a database connection error or the installer. The smoke test fails its HTTP check.
- **Fix:** on each `start`, write `<docroot>/sites/default/settings.drupal.php` (gitignored) with the values above. Add a guarded include to `settings.php` if it's missing, with an opt-out config field that mirrors DDEV's `disable_settings_management`. Editing a user's `settings.php` shows up in their git diff, so confirm that with the user. Check fkd-drupal8's Pantheon `settings.php` include structure first.

### G12. The web VM cannot resolve `db`.
- **What:** in DDEV, `db` is the compose service name on a shared Docker network. In SwiftDrupal the containers are separate VMs, the db hostname is `<name>-db`, and nothing provides name resolution between VMs [SwiftDrupal source: `DatabaseContainerSpecBuilder`]. **[Unverified]** that VMs on the same vmnet network can reach each other by IP at all.
- **Verify:** `drupal status --json` for the db IP, then `drupal exec web -- mysql -h<db-ip> -udb -pdb db -e 'select 1'`.
- **Fix:** write the db container's current IP into the generated settings file on every `start` (the IP changes every run), or add `db` to the web VM's `/etc/hosts` with an exec after start.

### G13. Database credentials: now confirmed from source.
- **What:** `import-db`/`export-db` assume `db`/`db`/`db`. The DDEV dbserver healthcheck uses `mysql -udb -pdb --database=db`, and its entrypoint uses root/root [DDEV source: `containers/ddev-dbserver/files/healthcheck.sh`, `docker-entrypoint.sh`]. The credentials match. What's still unverified is the first-boot initialization of an empty data directory on a virtiofs mount (G15).

---

## Layer 4: Identity, permissions, storage

### G14. No host UID/GID mapping.
- **What:** see G7. DDEV runs both containers as the host user's UID/GID, so files created in the project (`sites/default/files`, `vendor/`, generated settings) belong to the host user. SwiftDrupal runs as the image default (root for web). **[Unverified]** how virtiofs in Containerization maps ownership.
- **Symptom:** files in the project owned by root or unwritable, or Drupal unable to write `sites/default/files`.
- **Verify:** `drupal exec web -- sh -c 'id; touch /var/www/html/.sd-probe'`, then `ls -ln .sd-probe` on the host.
- **Fix options:** set the container process user to the host uid:gid and create a matching passwd entry at start (exec as root); or give the spec a `user` field and pre-create the user in a `post_start`-like root step before `/start.sh`.

### G15. MariaDB data directory on a virtiofs bind mount.
- **What:** DDEV stores MariaDB data in a Docker **volume** (`database`, external), not a bind mount [DDEV source: `app_compose_template.yaml`]. SwiftDrupal shares the host directory `~/Library/Application Support/drupal/projects/<name>/db` into the container as `/var/lib/mysql` [SwiftDrupal source: `DatabaseContainerSpecBuilder`]. **[Unverified]** ownership, fsync semantics and InnoDB behavior on virtiofs, and import speed for the 2.5 GB fixture.
- **Symptom:** the entrypoint fails to initialize the data directory, the db healthcheck never passes, or `import-db` is very slow.
- **Fix option:** use a block-device (ext4 image) mount for the data directory, which Containerization supports, and keep `delete`/`--keep-data` semantics (OQ-5).

### G16. DDEV mounts SwiftDrupal doesn't provide.
- **What** [DDEV source: `app_compose_template.yaml`, `start.sh`, `docker-entrypoint.sh`]:
  - **`/mnt/ddev_config`** carries the nginx/apache site config (G8), PHP `.ini` overrides, MySQL `.cnf`, `web-entrypoint.d` scripts, `.homeadditions` and snapshots.
  - **`/mnt/ddev-global-cache`** carries the mkcert CA, composer/npm/yarn caches, and bash/mysql history. `start.sh` creates it as needed, but nothing persists.
  - **The SSH agent socket** isn't forwarded, so composer or git over SSH to private repos fails inside the container.
- **Fix:** mount a generated `.drupal/` config directory as `/mnt/ddev_config` (required for G8), and a persistent cache directory. SSH agent forwarding is a later enhancement.

---

## Layer 5: Environment parity

### G17. Missing DDEV environment variables.
- **What:** SwiftDrupal sets only `DDEV_PROJECT`, `DDEV_HOSTNAME`, `DDEV_DOCROOT`, `DDEV_PHP_VERSION`, `DDEV_WEBSERVER_TYPE` (web) and `DDEV_PROJECT` (db). DDEV also sets `DDEV_PROJECT_TYPE`, `DDEV_SITENAME`, `DDEV_TLD`, `DDEV_PRIMARY_URL`, `DDEV_APPROOT=/var/www/html`, `DDEV_UID`/`DDEV_GID`/`DDEV_USER`, `DDEV_DATABASE`, `DDEV_FILES_DIR(S)`, `IS_DDEV_PROJECT=true`, `VIRTUAL_HOST`, `TZ`, `START_SCRIPT_TIMEOUT`, and others [DDEV source: `app_compose_template.yaml`].
- **Effects seen in `start.sh`:**
  - `VIRTUAL_HOST` feeds the mkcert certificate names, so an empty value yields a cert for localhost only.
  - `DDEV_PROJECT_TYPE` drives drush symlinks (for Drupal 10/11, use `vendor/bin/drush`).
  - `IS_DDEV_PROJECT` is checked by some Drupal tooling.
- **Fix:** set the parity list in `WebContainerSpecBuilder`/`DatabaseContainerSpecBuilder`, and add `drupal11` as the project type.

---

## Layer 6: Operational gaps in the CLI and service

| ID | Gap | Source |
|----|-----|--------|
| G18 | Config edits to `php_version`, `webserver_type` or `web_environment` don't apply until `delete` + `start`, and `delete` destroys DB data unless `--keep-data` (OQ-5). Iterating on config risks the imported database. | `ProjectLifecycle.start` rebuilds only on image change |
| G19 | `exec`, `ssh` and `logs` have no `--project-root` and no parent-directory search, unlike `start`/`stop`/`status`. There are three different project-root lookups. | Sortie 7a report, `ServiceTarget.swift` |
| G20 | The service connection has no call timeouts, so a hung service blocks the CLI forever. A service crash kills all containers; `KeepAlive` restarts only the service. The plist's `ExitTimeOut` of 60 s can SIGKILL a slow shutdown. | Sortie 8 report |
| G21 | `ssh` has no window-resize support. An abandoned `exec` keeps running inside the service. | Sortie 6a report |
| G22 | A multi-GB `import-db` through the service socket is untested at scale. | Sortie 5 report |
| G23 | `post_start` runs as the image's default user (root), which makes the ownership problem in G14 worse. | Sortie 7a |
| G24 | fkd-drupal8's files backup (~63 GB) is deliberately absent, so images and uploads 404. That's expected; consider `stage_file_proxy`. | Acceptance Fixture section |

## Layer 7: Test-suite debt (doesn't block an install)

| ID | Gap |
|----|-----|
| G25 | `LogMergeCoordinator`'s window-elapsed timer path has no end-to-end test; the test clock never fires. |
| G26 | Real-signal tests share process signals across suites (SIGUSR1/SIGUSR2/SIGWINCH). A re-signal after `cancel()` kills the test runner. |
| G27 | The manifest is built from ArgumentParser's experimental `--experimental-dump-help` format, which isn't stable across releases. |
| G28 | No test exercises `LiveContainerService`. Every container test uses the mock. |

---

## Suggested order of work on the other machine

1. **Layer 0 (G1–G4):** get a container to boot with an IP from `drupal service run`. If G1 fails, stop and decide the networking/privilege model with the user; it changes OQ-4.
2. **Layer 1 (G5–G7):** get `start` to exit 0 with both containers healthy.
3. **Layer 2 (G8, G9):** `curl http://<name>.drupal/` reaches `index.php` in the docroot.
4. **Layer 3 (G11, G12):** Drupal connects to MariaDB; `import-db` the fixture; the page renders.
5. **Layer 4 (G14–G16):** file ownership and data-dir durability are correct.
6. Then Layers 5–7.

After each layer, run `scripts/smoke-test-fkd-drupal8.sh` and note the first failing step. Update this document as gaps close: mark them **Resolved** with the commit, and don't delete them.
