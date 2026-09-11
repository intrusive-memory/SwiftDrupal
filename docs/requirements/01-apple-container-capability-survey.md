# Apple `container` runtime backend — draft requirements

Working draft. Not an accepted design; tracks what a DDEV backend built on
Apple's [`container`](https://github.com/apple/container) tool and its
compose-compatible layer would need, and whether the underlying tool is far
enough along to justify starting.

**Superseded direction:** this survey's findings fed a decision to build a
standalone Swift application instead of a DDEV backend — see
[02-v1-mvp-requirements.md](02-v1-mvp-requirements.md)
for the resulting v1.0 requirements. The capability/limitation research below
still stands; only the "add it to DDEV" framing changed.

## Goal

Run DDEV projects (Drupal, and other supported stacks) on macOS using
Apple's `container` runtime instead of Docker Desktop/Docker Engine, taking
advantage of its per-container lightweight-VM model on Apple Silicon.

## Current DDEV coupling to Docker

DDEV has no real runtime-abstraction layer today. What looks like
multi-provider support (Colima, OrbStack, Rancher Desktop, Lima, Docker
Desktop) is string-matching on `docker info` output in
`pkg/dockerutil/providers.go` to toggle a handful of behavioral flags — every
one of those backends speaks the Docker Engine API. Podman is the only
non-Docker-Desktop backend DDEV genuinely supports, and only because it is
Docker-API-compatible.

Concrete dependencies:

1. `github.com/moby/moby/client` (Engine API) and
   `github.com/docker/compose/v5` are vendored Go libraries, not CLI
   shell-outs. Compose files are Go-templated
   (`pkg/ddevapp/app_compose_template.yaml` and siblings) and loaded straight
   into `api.Compose` via `pkg/dockerutil/docker_compose.go`.
2. `ddev-router` (Traefik) resolves backend services by literal container
   hostname over Docker's embedded per-network DNS, with hostnames added and
   removed from a shared `ddev_default` bridge network as live network
   aliases (`pkg/dockerutil/containers.go`, `pkg/ddevapp/traefik.go`).
3. Container discovery is label-based (`com.ddev.site-name`, and similar),
   queried through `ContainerList` label filters
   (`pkg/dockerutil/labels.go`).
4. Builds go through a pinned, version-checked `docker-buildx` CLI plugin
   (`pkg/dockerutil/docker_buildx.go`).
5. Mutagen sync is invoked as an external binary
   (`pkg/ddevapp/mutagen.go`), but its own transport
   (`docker:/<container>/path`) shells out to the `docker` CLI internally —
   a second, independent Docker-CLI dependency alongside the Go SDK.
6. `host.docker.internal` is a Docker-Desktop-specific hostname with
   OS-specific resolution logic (`pkg/dockerutil/host_docker_internal.go`)
   and no defined equivalent elsewhere.

The integration surface is concentrated in `pkg/dockerutil/*`, the compose
templates and `compose_yaml.go` in `pkg/ddevapp/`, `mutagen.go`, and
`router.go`/`traefik.go` — but Docker API types flow into `pkg/ddevapp`
directly, so this is not a small plugin point.

## Apple `container`: capabilities and limits (as observed September 2026)

1. **Architecture**: one lightweight Linux micro-VM per container via
   Apple's Containerization framework, not a shared kernel — a different
   model from Docker Desktop's single shared VM.
2. **Platform**: Apple Silicon only, no Intel Mac support. Full networking
   function needs macOS 26 (Tahoe); on macOS 15 containers on a custom
   network cannot reach each other.
3. **No Docker Engine API and no `docker.sock`.** A socket-compatibility
   request was closed upstream as "not planned." A third-party shim,
   Socktainer, exists but its maturity is unverified.
4. **No official compose support.** Community shims (`opossum`, a Swift
   `Container-Compose`) exist and explicitly skip custom `networks:` blocks
   and `container_name` — both required by DDEV's router pattern.
5. **Networking**: DNS-name resolution only works on the default network;
   custom bridge networks (macOS 26+ only) fall back to IP-only addressing
   between containers, breaking DDEV's shared-network-plus-hostname-alias
   model as-is.
6. **Storage**: bind mounts (virtiofs) are Apple's own slowest storage
   tier, well below named volumes — relevant to DDEV's typical
   bind-mounted-source workflow and to Mutagen-style sync, which has no
   integration with this runtime today.
7. **Build**: OCI image pull/run works; Dockerfile builds go through a
   BuildKit-translation shim that does not yet support named build
   contexts.
8. **Maturity**: reached 1.0 in mid-2026, under active but small-team
   development. An independent survey of 29 real `docker-compose` stacks
   found roughly 62% ran unmodified or with a one-line fix; failures
   clustered around named-volume/database-init quirks, `docker.sock`
   bind-mounts, and kernel-capability-dependent containers. No published
   attempt at a DDEV-shaped stack (web, database, cache, search, and
   auxiliary services together) was found.

## Feasibility gate

These need to hold before implementation work starts, not be assumed:

1. A stable, Docker-API-compatible socket shim for `container` that covers
   DDEV's actual Engine API call set (container, exec, network, volume, and
   image lifecycle — see `pkg/dockerutil/*`). Only Socktainer exists today,
   and it is unverified for this.
2. Cross-container DNS resolution on a custom bridge network, which needs
   macOS 26+ — or a redesign of `ddev-router`/Traefik around IP-based
   service discovery for this backend specifically.
3. A working Mutagen equivalent. Mutagen's `docker:` transport is
   Docker-CLI-specific today and has no `container` counterpart.

## Functional requirements (if the gate is passed)

1. **Runtime abstraction layer**: a real `Provider`-style interface in
   `pkg/dockerutil` for container, network, volume, image, exec, and log
   operations, rather than extending the current string-matching
   heuristics — Podman-style API compatibility does not cover this
   backend, so this would be DDEV's first genuine abstraction of the kind.
2. **Compose generation**: prefer targeting the Docker-API-compatible shim
   so the existing `docker/compose/v5` library keeps working unmodified,
   over adding a second compose execution path for a `container`-native
   tool — compose-library types are threaded deep into `pkg/ddevapp`, so a
   second path is far more invasive.
3. **Networking for this backend**: replace hostname-alias-based routing
   with IP-based service discovery for Traefik configuration when running
   under `container`, scoped to macOS 26+; document macOS 15 as
   unsupported for this backend.
4. **Volume and bind-mount strategy**: benchmark virtiofs bind-mount
   performance against real DDEV workloads (Drupal/WordPress file trees,
   `vendor/`, `node_modules/`) before committing to it.
5. **Build path**: verify DDEV's custom webimage and dbimage Dockerfiles
   build through the BuildKit-translation shim; audit for named
   build-context usage first.
6. **`host.docker.internal` equivalent**: define and implement whatever
   DNS or hostname mechanism DDEV needs on this backend, since none exists
   built-in.
7. **Platform gating**: backend support must be macOS-only,
   Apple-Silicon-only, and version-gated (26+) in DDEV's requirements
   checks (`pkg/dockerutil/requirements.go`), with clear user-facing errors
   on unsupported combinations.
8. **Detection and configuration**: extend provider detection (or its
   eventual replacement) to recognize this backend, and add a config knob
   to select it, alongside the existing Docker-provider configuration.

## Non-functional and process requirements

1. Treat this as an experimental, opt-in backend, not a default-path
   change — scope an initial implementation to a single-container smoke
   test (webimage only) before attempting multi-service stacks.
2. Track upstream compose-support progress in
   [apple/container discussion #194](https://github.com/apple/container/discussions/194);
   prefer an eventual official Apple compose implementation over the
   community shims as the integration target.
3. No CI coverage exists today for any non-Docker-API backend beyond
   Podman; new integration tests need Apple Silicon and macOS 26 runners,
   which DDEV's current test matrix does not have.

## Open risks

1. Apple Silicon-only excludes Intel Mac users entirely — DDEV's first
   backend with a hardware exclusion, not just an OS or version one.
2. Both the compose layer and the Docker-API layer this backend would rely
   on are third-party community shims, not maintained by Apple — a
   dependency chain outside DDEV's or Apple's control.
3. Mutagen sync has no path forward without either upstream Mutagen
   support for this runtime or a DDEV-built replacement.

## Sources

- [apple/container](https://github.com/apple/container) — readme and
  `docs/technical-overview.md`, `docs/networking.md`, `docs/volumes.md`
- [apple/container issue #636](https://github.com/apple/container/issues/636) —
  Docker socket/API compatibility request, closed as not planned
- [apple/container discussion #194](https://github.com/apple/container/discussions/194) —
  compose support request
- [apple/container-builder-shim](https://github.com/apple/container-builder-shim)
- [apple/container issue #1930](https://github.com/apple/container/issues/1930) —
  named build-context gap
- [Socktainer](https://socktainer.github.io/)
- [apple/container discussion #1516](https://github.com/apple/container/discussions/1516) —
  storage-tier performance notes from maintainers
