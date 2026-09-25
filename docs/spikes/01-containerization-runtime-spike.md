# Spike 01 — `Containerization` runtime mechanics

**Date:** 2026-09-25
**Host:** Apple Silicon, macOS 26 (Darwin 27.0), Xcode 26 toolchain, Swift 6.3
**Library:** `apple/containerization` 0.45.0 (the version pinned in `Package.resolved`)
**Code:** `Sources/ContainerSpike/ContainerSpike.swift` (target/product `container-spike`)
**Run:** `scripts/run-spike.sh` (builds in release, ad-hoc signs with the
virtualization entitlement, fetches a kernel if one is missing, runs the spike;
JSON report on stdout and in `$SPIKE_HOME/last-report.json`)

This spike asks whether SwiftDrupal can drive the DDEV images directly through
the `Containerization` Swift library, with no `container` CLI and no Docker.
**It can.** Every step below worked. It turned up one architectural constraint
that the requirements don't yet account for (the VMs live inside the process
that creates them), plus a handful of image-level quirks that production code
has to handle.

## Results by step

| # | Step | Result |
|---|------|--------|
| 1 | Kernel + vminit initfs | **Worked.** No kernel was installed, because the `container` CLI had never run `system start`. Fetched the Kata 3.17.0 kernel, the same one `make fetch-default-kernel` uses. vminit is pulled from `ghcr.io/apple/containerization/vminit:0.45.0`. |
| 2 | Pull `ddev/ddev-webserver:v1.25.4` (arm64) | **Worked.** 439 MB compressed (one layer), 14.0 s. |
| 3 | Create + start with a virtiofs mount at `/var/www/html` | **Worked.** Reads and writes go both ways and show up live, with no ownership problems. |
| 4 | Container IP; can the host reach it? | **Worked.** The host reached `http://192.168.64.2/` directly: no port forwarding, no sudo. The IP stays the same across a restart in the same process, but **not reliably across processes** (details below). |
| 5 | Exec | **Worked.** stdout, stderr and exit code are all captured separately. Round trip is about 0.1 s. |
| 6 | Log stream | **Worked.** The init process's stdout and stderr arrive as raw bytes through a `Writer` you supply. There are **no timestamps and no line framing**, so we have to add both. |
| 7 | Stop + cleanup | **Worked.** Stop takes 0.04–0.1 s. `ContainerManager.delete` frees the IP and removes the per-container directory. |
| + | `ddev/ddev-dbserver-mariadb-10.11:v1.25.4` | **Worked** once running as the host uid (mysqld refuses to run as root). mysqld was ready 2.1 s after start. Web reached db by IP on the shared vmnet network (`mysql -h 192.168.64.3 -udb -pdb` → `10.11.19-MariaDB`). |

## Timings

Measured on this machine. "Cold" means nothing was cached yet.

| Operation | Time |
|---|---|
| `VmnetNetwork()` (create vmnet network) | ~0.2 s |
| `ContainerManager(kernel:initfsReference:root:network:)`, cold (pull vminit + build `initfs.ext4`) | 5.8 s |
| …same, cached | 0.002 s |
| `imageStore.pull` ddev-webserver (439 MB, 1 layer, arm64 only) | 14.0 s |
| `imageStore.pull` ddev-dbserver-mariadb-10.11 (179 MB, 33 layers) | 9.8 s |
| `EXT4Unpacker.unpack` ddev-webserver → ext4, **debug build** | 138–163 s |
| `EXT4Unpacker.unpack` ddev-webserver → ext4, **release build** | **2.0 s** |
| `EXT4Unpacker.unpack` ddev-dbserver, debug build | 29 s |
| `clonefile(2)` of a cached rootfs (8 GiB sparse, ~1.5 GB used) | <1 ms |
| `LinuxContainer.create()` (VM boot + vminitd + mounts + network) | 0.26–0.34 s |
| `LinuxContainer.start()` (init process) | 0.03–0.07 s |
| web `start()` → first HTTP 200 from the host (static file) | ~2.5 s |
| web `start()` → first PHP 200 (php-fpm ready; nginx returns 502 until then) | ~2–3 s after the static file |
| db `start()` → `mysqladmin ping` OK | 2.1 s |
| exec round trip (`sh -c …`) | ~0.1 s |
| `stop()` | 0.04–0.1 s |

Once images and rootfs are cached, a web + db start takes about 3 seconds in
total, and nearly all of that is the images' own entrypoints.

## The API that was actually used

These signatures were read from `.build/checkouts/containerization` at 0.45.0.

```swift
// Network: vmnet shared mode (NAT). The library allocates IPs; vmnet has DHCP disabled.
let network = try VmnetNetwork()                      // or VmnetNetwork(subnet: try CIDRv4("192.168.100.0/24"))

// Manager: pulls the vminit image, writes <root>/initfs.ext4, and wraps a VZVirtualMachineManager.
var manager = try await ContainerManager(
    kernel: Kernel(path: kernelURL, platform: .linuxArm),
    initfsReference: "ghcr.io/apple/containerization/vminit:0.45.0",
    root: storeRoot,                                   // image store + containers/<id>/
    network: network)

// Images: pull ONLY arm64. get(reference:pull:true) pulls every platform in the index.
let image = try await manager.imageStore.pull(
    reference: "docker.io/ddev/ddev-webserver:v1.25.4",
    platform: Platform(arch: "arm64", os: "linux"),
    progress: { events in /* ProgressEvent.addSize etc. */ })

// Rootfs: unpack once per image digest, then give each container an APFS clone.
let mount = try await EXT4Unpacker(capacityInBytes: 8.gib()).unpack(image, for: arm64, at: cacheURL)
clonefile(cacheURL.path, "<root>/containers/<id>/rootfs.ext4", 0)

// Container: the overload that takes a prepared rootfs Mount.
let web = try await manager.create("spike-web", image: image,
    rootfs: .block(format: "ext4", source: clonedPath, destination: "/", options: [])) { config in
    // config.process has already been seeded from the image config (Entrypoint+Cmd, Env, WorkingDir, User).
    // config.interfaces has already been allocated by the network; config.dns = gateway.
    config.cpus = 2; config.memoryInBytes = 2.gib()    // the VM also gets +1 CPU and +128 MiB overhead
    config.hostname = "spike-web"
    config.hosts = Hosts.default + [own IP → hostname]   // ContainerManager does NOT write /etc/hosts
    config.mounts.append(.share(source: projectDir, destination: "/var/www/html"))   // virtiofs
    config.process.environmentVariables += ["DDEV_PHP_VERSION=8.3", ...]
    config.process.user = User(uid: getuid(), gid: getgid())   // required for the db image
    config.process.stdout = myWriter                   // `Writer` protocol: write(Data), close()
    config.process.stderr = myWriter
}
try await web.create()                                 // boots the VM
try await web.start()                                  // runs the init process
let ip = web.interfaces.first!.ipv4Address.address     // e.g. 192.168.64.2

// Exec
let p = try await web.exec("exec-1") { $0.arguments = [...]; $0.stdout = w; $0.stderr = w2; $0.user = ... }
try await p.start(); let status = try await p.wait(timeoutInSeconds: 60); try await p.delete()

// Lifecycle
try await web.stop()                                   // kills everything, unmounts, stops the VM
try await web.create(); try await web.start()          // a LinuxContainer can be re-created after stop (same IP)
try manager.delete("spike-web")                        // releases the IP, removes containers/<id>/
```

The library also offers `wait()`, `kill(_:)`, `statistics()`, `copyIn`/`copyOut`,
Unix-socket relays (`config.sockets`), a boot log (`config.bootLog`, which
defaults to `containers/<id>/bootlog.log`), and `LinuxPod` (several containers
in one VM, marked experimental).

## Architectural finding: the VMs live in the process that creates them

`VZVirtualMachineManager` runs each VM through a Virtualization.framework XPC
service that belongs to the calling process. When the spike was killed with
`kill -9` while it held a container, the container's IP stopped answering
within 2 s and the per-VM `com.apple.Virtualization.VirtualMachine` XPC
process went away. Likewise, the `vmnet_network_ref`, the IP allocator, the
stdio pipes and the exec channel (gRPC to vminitd over vsock) all exist only
inside that process.

So `drupal start` cannot simply boot the containers and exit. Something has to
keep running and own the VMs:

- `drupal start` spawns a detached supervisor: **the same `drupal` binary**,
  re-executed as a hidden subcommand (e.g. `drupal __supervise <project>`). This
  keeps faith with the "single binary, no separate daemon binary" decision.
  There is one supervisor per project, holding that project's vmnet network,
  web and db.
- The supervisor listens on a Unix socket in the project's state directory.
  `drupal exec`, `drush`, `composer`, `logs`, `status` and `stop` all become
  JSON requests to it. Exec in particular has to go through the supervisor:
  only the owning process can reach vminitd.
- The supervisor writes container stdout/stderr to log files, stamping each
  line as it arrives. That gives `drupal logs` history after the fact, not just
  a live stream.
- `stop` is a request to the supervisor, which stops the containers and exits.
  If the supervisor has crashed, the containers are already gone; `start` has
  to detect that and clear out stale `containers/<id>/` directories, because
  `ContainerManager.create(…reference:…)` refuses to overwrite an existing
  directory.

A crash of the supervisor takes the whole environment down with it. That
matches `docker compose down` semantics, which is acceptable for a dev tool.

## IP reachability and Open Question #2

What was observed:

- **The host can reach the container IP directly.** `curl http://<ip>/` works
  with no port mapping and no privileges, and any port the container listens on
  (80, 443, 3306 …) is reachable. The v1.0 plan of pointing `<name>.drupal`
  straight at the web container's IP, with no router, works.
- **The library allocates IPs, not DHCP.** `VmnetNetwork` turns vmnet's DHCP
  off and hands out `.2`, `.3`, … from a rotating allocator in the calling
  process. The first container in a fresh process always gets `.2`.
- **vmnet picks the subnet**, and it depends on what else is running. Two
  concurrent spike processes got `192.168.64.0/24` and `192.168.65.0/24`, so
  processes are isolated from each other and there were no collisions. A later
  single run got `192.168.65.0/24` because 64 was still taken, and then 64 again
  on the run after that. **The same project can therefore come up on a
  different IP from one `start` to the next.**
- **A subnet can be pinned.** `VmnetNetwork(subnet: "192.168.100.0/24")` worked
  and gave `.2` deterministically. Pinning a subnet that is already in use fails
  with `vmnet_return_t(rawValue: 1001)` (VMNET_FAILURE), so the caller finds out
  immediately and can fall back.
- Within one process, `stop` followed by `create`/`start` on the same
  `LinuxContainer` keeps the same IP. The MAC address is random on every boot,
  but that caused no reachability problems.

**Recommendation for Open Question #2:** keep the **local resolver** as the
primary design. The IP genuinely can change between starts, and a resolver
reads the live IP from the supervisor without writing anything privileged per
start. The resolver fits naturally inside the per-project supervisor, or in a
small shared one. It can listen on `127.0.0.1` on an unprivileged port, because
`/etc/resolver/drupal` accepts a `port` line, so the only privileged step is the
one-time write of that file. **The resolver itself was not built in this
spike.** That is the next thing to prove, together with how macOS behaves with
`/etc/resolver` for a non-standard TLD.

The `/etc/hosts` fallback is also cheaper than the requirements assume. The
supervisor can pin a per-project subnet derived from a hash of the project name
(web `.2`, db `.3`) and fall back to a vmnet-chosen subnet only if that one is
taken. With a pin, the IP is stable in the common case, so `/etc/hosts` needs a
privileged write once at `init`, not on every `start`, and again only if the
pin ever fails.

## Gotchas

1. **Entitlement plus signing.** Virtualization.framework will not create a VM
   unless the binary carries `com.apple.security.virtualization`. An ad-hoc
   signature is enough:
   `codesign --force --sign - --entitlements scripts/container-spike.entitlements <bin>`.
   `swift build` drops the signature, so you must re-sign after every build.
   vmnet shared mode needed **no** further entitlement and no sudo on macOS 26.
   The `ctr-example` README warns that error 1001 can appear depending on where
   the binary lives; I didn't hit that running from the repo's `.build/`.
2. **Kernel.** The Homebrew `container` 1.4.1 had never run `container system
   start`, so `~/Library/Application Support/com.apple.container` did not exist
   and there was no kernel to reuse. The spike downloads the 290 MB Kata
   Containers 3.17.0 static tarball and extracts only `vmlinux.container`
   (Linux 6.12.28, 14.7 MB). The production CLI needs a one-time "fetch
   runtime assets" step, ideally a download of just the kernel file with a
   checksum, plus reuse of `~/Library/Application
   Support/com.apple.container/kernels/*` when the `container` CLI has already
   installed one.
3. **Match the vminit version to the library version.** vminitd is the guest
   half of a gRPC contract with the host library. Tags are published at
   `ghcr.io/apple/containerization/vminit:<lib version>` (0.45.0 exists, and so
   do 0.46.0 and 0.47.0). `ctr-example` hard-codes the stale `0.26.5`. Pin both
   together.
4. **Build in release.** In a debug build, `EXT4Unpacker` took 138–163 s for
   the ddev-webserver layer; in release it took 2.0 s, about 80x faster. The
   shipped CLI is a release build, but tests and dev loops should not unpack
   real images in debug.
5. **Don't use `ContainerManager.create(_:reference:)` / `create(_:image:rootfsSizeInBytes:)` as-is.**
   Both unpack the image into a fresh ext4 on every create, and `delete`
   removes it again. Unpack once per image digest, then `clonefile(2)` the
   result (instant, copy-on-write on APFS) and pass it to
   `create(_:image:rootfs:)`. Also, `imageStore.get(reference:pull: true)`
   pulls **every** platform, which doubles the download for DDEV's multi-arch
   images. Call `pull(reference:platform:)` instead.
6. **Start every run from a fresh rootfs.** DDEV always recreates containers
   (`ddev stop` removes them), and its images assume a clean filesystem.
   Restarting ddev-webserver on its dirty rootfs **hangs**: supervisord starts,
   but nginx and php-fpm never do. The likely cause is that `start.sh` only
   starts the `cat < /var/tmp/logpipe` reader when it creates the FIFO, and a
   FIFO left over from the first boot means there is no reader. Every
   supervisord program logging to that FIFO then blocks on open. With a fresh
   clone, the restart served HTTP 200 in about 2.5 s. To reproduce, run with
   `SPIKE_RESTART_REUSE_ROOTFS=1`. Persistent state such as the MariaDB datadir
   belongs on its own mount (a block volume, not virtiofs, for InnoDB). This
   spike did not test that.
7. **`ContainerManager` writes `/etc/resolv.conf` (nameserver = the vmnet
   gateway) but not `/etc/hosts`.** Without an entry for the container's own
   hostname, `sudo` in `start.sh` looks up `spike-web` over DNS through the
   gateway. In one run that stalled start-up for **5+ minutes**. Always set
   `config.hosts` with `<own IP> <hostname>`, which Docker does automatically.
   The same mechanism provides DDEV's `db` alias inside web: create db first so
   its IP is known, then add `db` to web's hosts entries.
8. **Users.** ddev-dbserver's mysqld refuses to run as root; running it as the
   host `uid:gid` works, as it does in DDEV. ddev-webserver runs fine as root
   with nginx-fpm. DDEV itself runs web as the host uid, but it builds a derived
   image to add that user to `/etc/passwd`, and v1.0 says "unmodified images".
   Running web as root is acceptable anyway, because of the next point.
9. **virtiofs ownership is mapped to whoever is asking.** Inside the guest, host
   files appear owned by the accessing uid: root sees `root:root`, uid 502 sees
   `502:20`. Files the guest writes, even as root, are owned by the host user
   on the host. There is no chown or permission friction either way. Host edits
   are visible in the guest immediately, and guest writes on the host.
10. **The image HEALTHCHECK is not run.** Containerization ignores the OCI/Docker
    `Healthcheck` (`/healthcheck.sh` in both DDEV images). The CLI must run it
    itself through exec.
11. **Readiness.** nginx answers 502 for about 2–3 s after the static page
    already works, until php-fpm is listening. "Started" and "ready" need to be
    separate states, driven by the health check.
12. **Exec into a dead container gives a misleading error.** If the init process
    has exited (as the db did while it still ran as root), `exec` fails with
    `vmexec error … Code=3 "No such process" … no PID data from sync pipe`.
    Check with `wait`/state before exec and report "container exited" instead.
13. **Logs.** A `Writer` receives raw chunks, separately for stdout and stderr,
    with no timestamps and no line framing. Writers are fixed at create time,
    and the library closes them when the process exits. The spike's
    `LineCollector` splits lines and stamps each with the host receive time.
    Guest clocks were within about 1 s of the host. ddev-webserver's
    `start.sh` runs under `set -x`, so the bulk of its log volume is shell trace
    on stderr.
14. **What ddev-webserver needs to boot:** only `/start.sh` plus environment
    variables. `DDEV_PHP_VERSION` switched the 8.4-default image to PHP 8.3 at
    start. `DDEV_WEBSERVER_TYPE=nginx-fpm`, `DDEV_PROJECT`, `DDEV_PROJECT_TYPE`,
    `VIRTUAL_HOST` and `TZ` were also set. With no `/mnt/ddev_config` or
    `/mnt/ddev-global-cache` mounts it still boots, and the default site serves
    `/var/www/html`. Serving a real Drupal docroot (`web/`) means generating
    DDEV's nginx site config and mounting it at `/mnt/ddev_config/nginx_full`.
    That is not covered here. The image also starts mailpit.
15. **Resources.** The VM gets `cpus + 1` and `memory + 128 MiB`. A rootfs is an
    8 GiB sparse file: ddev-webserver uses about 1.5 GB of it, ddev-dbserver
    about 0.4 GB. The image store (both images plus vminit) is 669 MB, and
    `initfs.ext4` takes 170 MB on disk.
16. **Rosetta and architecture.** Not needed: both DDEV images publish arm64,
    and `Kernel(platform: .linuxArm)` plus pulling only arm64 keeps everything
    native. `ContainerManager(rosetta:)` exists if an amd64-only image ever
    turns up.

## What a production `ContainerRuntime` should look like

Based on the above, split the runtime into a narrow protocol that the CLI
commands use, with two implementations behind it:

```swift
public protocol ContainerRuntime: Sendable {
    /// Kernel + vminit present and version-matched; downloads on first use.
    func ensureRuntimeAssets(progress: ProgressSink?) async throws -> RuntimeAssets
    /// Pull the arm64 variant only; no-op if the digest is cached.
    func pullImage(_ reference: String, progress: ProgressSink?) async throws -> ImageRef
    /// Boot a container from a *fresh* CoW clone of the cached rootfs for that digest.
    func run(_ spec: ContainerSpec) async throws -> ContainerInfo
    func stop(_ name: String) async throws                         // idempotent
    func exec(_ name: String, _ spec: ExecSpec) async throws -> ExecResult          // buffered (agents / --json)
    func execStreaming(_ name: String, _ spec: ExecSpec) -> AsyncThrowingStream<ExecEvent, Error>
    func logs(_ name: String, since: Date?, follow: Bool) -> AsyncThrowingStream<LogLine, Error>
    func status(_ name: String) async throws -> ContainerInfo      // state, ip, health, startedAt
}

public struct ContainerSpec: Sendable, Codable {
    var name: String                 // "<project>-web"
    var image: String                // "docker.io/ddev/ddev-webserver:v1.25.4"
    var hostname: String
    var extraHosts: [String: String] // "db" -> IP; own hostname is added automatically
    var environment: [String: String]
    var mounts: [HostMount]          // host dir -> guest path (virtiofs); block volumes later
    var user: UserSpec?              // nil = image default; db uses host uid:gid
    var cpus: Int, memoryMiB: Int
    var healthcheck: [String]?       // run via exec; drives "ready"
}

public struct LogLine: Sendable, Codable { var time: Date; var stream: Stream; var text: String }
public struct ContainerInfo: Sendable, Codable { var name: String; var state: State; var ipv4: String?; var health: Health }
```

- **`ContainerizationRuntime`** runs **inside the supervisor process** and
  wraps `ContainerManager`, `VmnetNetwork` and `LinuxContainer` as shown in the
  spike: an arm64-only pull, a rootfs cache keyed by digest plus `clonefile`, a
  fresh clone on every run, `/etc/hosts` always written, the health-check loop,
  and timestamped log files.
- **`SupervisorClient`** runs **in every other `drupal` invocation**. It
  implements the same protocol as JSON over the project's Unix socket, and
  starts the supervisor on `run` when none is running. CLI commands only ever
  see `ContainerRuntime`, so their code is the same either way and a
  `FakeRuntime` covers unit tests without VMs.
- IP policy (a pinned per-project subnet, else whatever vmnet offers) and the
  `*.drupal` resolver sit in the supervisor next to the runtime, because only
  the supervisor knows the live IP.
- Keep `Containerization` types out of the protocol. It is pre-1.0 and ships
  breaking minor releases, and the CLI shouldn't have to follow those
  changes.

## Package.swift

This spike adds one executable target/product, `container-spike` →
`Sources/ContainerSpike`, depending on the `Containerization`,
`ContainerizationOCI`, `ContainerizationExtras` and `ContainerizationOS`
products. `ContainerizationOS` supplies `.gib()`/`.mib()`, and
`ContainerizationExtras` supplies `CIDRv4`/`ProgressEvent`. For the real CLI:

- Pin the dependency (`exact: "0.45.0"`, or `.upToNextMinor`) instead of
  `from: "0.1.0"`. The library is pre-1.0 with breaking minor releases, and
  the vminit image tag has to move in lock-step with it.
- The `drupal` target will need the same four products once it absorbs the
  runtime.
- Signing with the entitlement has to become part of the build and install
  story, for example `make install` or a post-build script. SwiftPM can't embed
  entitlements on its own.

## Not covered (follow-ups)

- The `*.drupal` local resolver and `/etc/resolver/drupal` behaviour.
- Persistent block volumes for `/var/lib/mysql`, rather than the image's
  ephemeral rootfs.
- Serving a real Drupal composer project: the nginx site config for
  `docroot: web`, and `/mnt/ddev_config` / `/mnt/ddev-global-cache` mounts.
- The supervisor process itself: detaching, the socket protocol, crash
  recovery.
- Several projects running at once (each gets its own subnet; reachability
  between projects was not tested).
- virtiofs performance under a real `composer install` or Drupal bootstrap.
