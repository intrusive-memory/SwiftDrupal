// Runtime spike: proves the core container mechanics SwiftDrupal needs, using
// apple/containerization directly (no `container` CLI, no Docker).
//
// Findings are written up in docs/spikes/01-containerization-runtime-spike.md.
// Run via scripts/run-spike.sh (it builds, codesigns with the virtualization
// entitlement, fetches a kernel if needed, and runs this binary).
//
// Configuration (environment variables):
//   SPIKE_HOME        state dir (kernel, image store, logs). Default:
//                     ~/Library/Application Support/swiftdrupal-spike
//   SPIKE_KERNEL      kernel path. Default: $SPIKE_HOME/vmlinux-arm64
//   SPIKE_INITFS      vminit image. Default: ghcr.io/apple/containerization/vminit:0.45.0
//   SPIKE_WEB_IMAGE   default docker.io/ddev/ddev-webserver:v1.25.4
//   SPIKE_DB_IMAGE    default docker.io/ddev/ddev-dbserver-mariadb-10.11:v1.25.4
//   SPIKE_SKIP_DB=1   skip the db container
//   SPIKE_SUBNET      optional fixed vmnet IPv4 subnet, e.g. 192.168.100.0/24
//   SPIKE_HOLD=N      keep containers running N seconds before teardown (manual poking)
//   SPIKE_RESTART_REUSE_ROOTFS=1
//                     restart test reuses the dirty rootfs instead of a fresh clone
//                     (reproduces the ddev-webserver hang described in the doc)
//   SPIKE_MODE=net    only boot one small container and hold it (SPIKE_NET_ID,
//                     SPIKE_HOLD, SPIKE_SUBNET); used to compare concurrent processes

import Containerization
import ContainerizationExtras
import ContainerizationOCI
import ContainerizationOS
import Foundation

// MARK: - Small helpers

let spikeStart = Date()

func elapsed(since start: Date) -> Double {
    (Date().timeIntervalSince(start) * 1000).rounded() / 1000
}

func log(_ message: String) {
    let t = String(format: "%8.3f", Date().timeIntervalSince(spikeStart))
    FileHandle.standardError.write(Data("[\(t)s] \(message)\n".utf8))
}

/// Times an async throwing operation and records it in the report.
func timed<T>(_ label: String, _ report: Report, _ body: () async throws -> T) async throws -> T {
    let start = Date()
    log("BEGIN \(label)")
    do {
        let value = try await body()
        let secs = elapsed(since: start)
        report.timing(label, secs)
        log("END   \(label) (\(secs)s)")
        return value
    } catch {
        let secs = elapsed(since: start)
        report.timing(label + " (FAILED)", secs)
        log("FAIL  \(label) after \(secs)s: \(error)")
        throw error
    }
}

/// Collects a report of everything that happened; dumped as JSON at the end.
final class Report: @unchecked Sendable {
    private let lock = NSLock()
    private var timings: [[String: Any]] = []
    private var results: [String: Any] = [:]

    func timing(_ label: String, _ seconds: Double) {
        lock.withLock { timings.append(["step": label, "seconds": seconds]) }
    }

    func set(_ key: String, _ value: Any) {
        lock.withLock { results[key] = value }
        log("RESULT \(key) = \(value)")
    }

    var aborted: Bool {
        lock.withLock { (results["overall"] as? String)?.hasPrefix("aborted") ?? false }
    }

    func json() -> String {
        lock.withLock {
            let obj: [String: Any] = ["timings": timings, "results": results]
            guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
                let s = String(data: data, encoding: .utf8)
            else { return "{}" }
            return s
        }
    }
}

/// A `Writer` that splits a container stdio stream into lines and stamps each
/// with a host-side receive time. Containerization delivers raw bytes with no
/// timestamps and no framing, so this is what `drupal logs` would have to do.
final class LineCollector: Writer, @unchecked Sendable {
    let name: String
    private let lock = NSLock()
    private var pending = Data()
    private var lines: [(Date, String)] = []
    private let file: FileHandle?
    private let echo: Bool

    init(name: String, logFile: URL?, echo: Bool = false) {
        self.name = name
        self.echo = echo
        if let logFile {
            FileManager.default.createFile(atPath: logFile.path, contents: nil)
            self.file = try? FileHandle(forWritingTo: logFile)
        } else {
            self.file = nil
        }
    }

    func write(_ data: Data) throws {
        lock.withLock {
            pending.append(data)
            while let nl = pending.firstIndex(of: 0x0A) {
                let lineData = pending[pending.startIndex..<nl]
                pending = Data(pending[pending.index(after: nl)...])
                emit(String(decoding: lineData, as: UTF8.self))
            }
        }
    }

    func close() throws {
        lock.withLock {
            if !pending.isEmpty {
                emit(String(decoding: pending, as: UTF8.self))
                pending.removeAll()
            }
            try? file?.close()
        }
    }

    private func emit(_ line: String) {
        let now = Date()
        lines.append((now, line))
        let stamped = "\(ISO8601DateFormatter.fractional.string(from: now)) [\(name)] \(line)\n"
        file?.write(Data(stamped.utf8))
        if echo { FileHandle.standardError.write(Data(stamped.utf8)) }
    }

    var text: String { lock.withLock { lines.map(\.1).joined(separator: "\n") } }
    var count: Int { lock.withLock { lines.count } }
    func tail(_ n: Int) -> [String] {
        lock.withLock {
            lines.suffix(n).map { "\(ISO8601DateFormatter.fractional.string(from: $0.0)) \($0.1)" }
        }
    }
}

extension ISO8601DateFormatter {
    nonisolated(unsafe) static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

/// Polls an HTTP URL from the host until it answers or the deadline passes.
func probeHTTP(_ url: URL, timeout: TimeInterval) async -> (status: Int, body: String, afterSeconds: Double)? {
    let start = Date()
    var last: (status: Int, body: String, afterSeconds: Double)?
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 3
    config.timeoutIntervalForResource = 3
    config.waitsForConnectivity = false
    config.connectionProxyDictionary = [:]
    let session = URLSession(configuration: config)
    while Date().timeIntervalSince(start) < timeout {
        do {
            let (data, resp) = try await session.data(from: url)
            if let http = resp as? HTTPURLResponse {
                last = (http.statusCode, String(decoding: data.prefix(2000), as: UTF8.self), elapsed(since: start))
                // 502/503 = nginx up but php-fpm not yet listening; keep polling.
                if http.statusCode < 500 { return last }
            }
        } catch {
            // Not up yet.
        }
        try? await Task.sleep(for: .milliseconds(500))
    }
    return last
}

/// Runs a host command and returns its combined output.
func host(_ argv: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: argv[0])
    p.arguments = Array(argv.dropFirst())
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return "failed to run \(argv): \(error)" }
    p.waitUntilExit()
    return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
}

struct ExecResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    let seconds: Double
}

/// Runs a one-shot process inside a running container and captures its output.
func execIn(_ container: LinuxContainer, id: String, _ argv: [String], env: [String] = [], user: ContainerizationOCI.User? = nil) async throws -> ExecResult {
    let out = LineCollector(name: "\(id):stdout", logFile: nil)
    let err = LineCollector(name: "\(id):stderr", logFile: nil)
    let start = Date()
    let process = try await container.exec(id) { config in
        config.arguments = argv
        config.environmentVariables = ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"] + env
        config.workingDirectory = "/"
        config.stdout = out
        config.stderr = err
        if let user { config.user = user }
    }
    try await process.start()
    let status = try await process.wait(timeoutInSeconds: 60)
    try await process.delete()
    return ExecResult(exitCode: status.exitCode, stdout: out.text, stderr: err.text, seconds: elapsed(since: start))
}

func hostsFile(for config: LinuxContainer.Configuration, names: [String]) -> Hosts {
    var hosts = Hosts.default
    if let ip = config.interfaces.first?.ipv4Address.address.description {
        hosts.entries.append(Hosts.Entry(ipAddress: ip, hostnames: names))
    }
    return hosts
}

func env(_ key: String) -> String? {
    guard let v = ProcessInfo.processInfo.environment[key], !v.isEmpty else { return nil }
    return v
}

// MARK: - The spike

@main
struct ContainerSpike {
    static func main() async {
        let report = Report()
        do {
            try await run(report)
            report.set("overall", "completed")
        } catch {
            report.set("overall", "aborted: \(error)")
        }
        let json = report.json()
        print(json)
        if let home = try? spikeHome() {
            try? json.write(to: home.appendingPathComponent("last-report.json"), atomically: true, encoding: .utf8)
        }
        if report.aborted { exit(1) }
    }

    static func spikeHome() throws -> URL {
        if let h = env("SPIKE_HOME") { return URL(fileURLWithPath: h) }
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return base.appendingPathComponent("swiftdrupal-spike")
    }

    static func run(_ report: Report) async throws {
        if env("SPIKE_MODE") == "net" {
            try await netProbe(report)
            return
        }
        let home = try spikeHome()
        let logs = home.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)

        let kernelPath = env("SPIKE_KERNEL") ?? home.appendingPathComponent("vmlinux-arm64").path
        let initfsRef = env("SPIKE_INITFS") ?? "ghcr.io/apple/containerization/vminit:0.45.0"
        let webRef = env("SPIKE_WEB_IMAGE") ?? "docker.io/ddev/ddev-webserver:v1.25.4"
        let dbRef = env("SPIKE_DB_IMAGE") ?? "docker.io/ddev/ddev-dbserver-mariadb-10.11:v1.25.4"
        let skipDB = env("SPIKE_SKIP_DB") == "1"
        let hold = Int(env("SPIKE_HOLD") ?? "0") ?? 0
        let arm64 = Platform(arch: "arm64", os: "linux")

        report.set("host.arch", Platform.current.description)
        report.set("kernel", kernelPath)
        report.set("initfs", initfsRef)
        guard FileManager.default.fileExists(atPath: kernelPath) else {
            throw SpikeError("kernel not found at \(kernelPath); run scripts/run-spike.sh which fetches one")
        }

        // ---- Step 1: kernel + initfs -> ContainerManager ------------------------
        let network: VmnetNetwork
        do {
            if let s = env("SPIKE_SUBNET") {
                network = try VmnetNetwork(subnet: try CIDRv4(s))
            } else {
                network = try VmnetNetwork()
            }
            report.set("step1.vmnet.subnet", network.subnet.description)
            report.set("step1.vmnet.gateway", network.ipv4Gateway.description)
        } catch {
            report.set("step1.vmnet", "FAILED: \(error)")
            throw error
        }

        let storeRoot = home.appendingPathComponent("store")
        var manager = try await timed("step1.containerManager.init (initfs pull+unpack if not cached)", report) {
            try await ContainerManager(
                kernel: Kernel(path: URL(fileURLWithPath: kernelPath), platform: .linuxArm),
                initfsReference: initfsRef,
                root: storeRoot,
                network: network
            )
        }
        report.set("step1.imageStore", manager.imageStore.path.path)

        // Clean up leftovers from an earlier, aborted run.
        for id in ["spike-web", "spike-db"] {
            try? manager.delete(id)
        }

        // ---- Step 2: pull ddev-webserver ----------------------------------------
        let webImage = try await pullImage(webRef, platform: arm64, manager: manager, report: report, key: "step2.web")

        // ---- Step 3: create + start with a virtiofs bind mount -------------------
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftdrupal-spike-project-\(ProcessInfo.processInfo.processIdentifier)")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }
        try "<h1>hello from the host via virtiofs</h1>\n".write(
            to: project.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try "<?php echo 'php ' . PHP_VERSION . ' says hi from ' . gethostname() . \"\\n\";\n".write(
            to: project.appendingPathComponent("index.php"), atomically: true, encoding: .utf8)
        report.set("step3.hostProjectDir", project.path)

        let webOut = LineCollector(name: "web:stdout", logFile: logs.appendingPathComponent("web.stdout.log"))
        let webErr = LineCollector(name: "web:stderr", logFile: logs.appendingPathComponent("web.stderr.log"))

        let webRootfs = try await prepareRootfs(id: "spike-web", image: webImage, platform: arm64, manager: manager, home: home, report: report, key: "step3.web")
        let web = try await timed("step3.web.manager.create (LinuxContainer config)", report) {
            try await manager.create(
                "spike-web",
                image: webImage,
                rootfs: webRootfs
            ) { config in
                config.cpus = 2
                config.memoryInBytes = 2.gib()
                config.hostname = "spike-web"
                // ContainerManager does not write /etc/hosts. Without an entry for
                // the container's own hostname, `sudo` in ddev-webserver's start.sh
                // does a DNS lookup for "spike-web" via the vmnet gateway and can
                // stall for minutes. Docker writes this entry automatically.
                config.hosts = hostsFile(for: config, names: ["spike-web", "web"])
                config.mounts.append(.share(source: project.path, destination: "/var/www/html"))
                config.process.environmentVariables += [
                    "DDEV_PHP_VERSION=8.3",
                    "DDEV_WEBSERVER_TYPE=nginx-fpm",
                    "DDEV_PROJECT=spike",
                    "DDEV_PROJECT_TYPE=drupal",
                    "DDEV_DOCROOT=",
                    "DDEV_XDEBUG_ENABLED=false",
                    "VIRTUAL_HOST=spike.drupal",
                    "HOSTNAME=spike-web",
                    "TZ=UTC",
                ]
                config.process.stdout = webOut
                config.process.stderr = webErr
            }
        }
        report.set("step3.web.processArgs", web.config.process.arguments.joined(separator: " "))
        report.set("step3.web.bootlog", home.appendingPathComponent("store/containers/spike-web/bootlog.log").path)

        try await timed("step3.web.container.create (VM boot + guest setup)", report) {
            try await web.create()
        }
        try await timed("step3.web.container.start (init process)", report) {
            try await web.start()
        }

        // ---- Step 4: IP + host reachability --------------------------------------
        guard let webIface = web.interfaces.first else { throw SpikeError("web container has no interface") }
        let webIP = webIface.ipv4Address.address.description
        report.set("step4.web.ipv4", webIface.ipv4Address.description)
        report.set("step4.web.gateway", webIface.ipv4Gateway?.description ?? "nil")

        await probeFromHost(ip: webIP, report: report, key: "step4.web.firstBoot")

        // ---- Step 5: exec ---------------------------------------------------------
        do {
            let r = try await timed("step5.exec", report) {
                try await execIn(
                    web, id: "exec-1",
                    ["/bin/sh", "-c", "php -v | head -1; id; ls -la /var/www/html; cat /etc/resolv.conf; ip -4 addr show eth0 2>/dev/null | grep inet; echo to-stderr >&2; exit 3"])
            }
            report.set("step5.exec.exitCode", r.exitCode)
            report.set("step5.exec.stdout", r.stdout)
            report.set("step5.exec.stderr", r.stderr)
        } catch {
            report.set("step5.exec", "FAILED: \(error)")
        }

        // Write-through test: a file written in the guest shows up on the host.
        do {
            let r = try await execIn(web, id: "exec-write", ["/bin/sh", "-c", "echo guest-wrote-this > /var/www/html/from-guest.txt && stat -c '%U:%G %a' /var/www/html/from-guest.txt"])
            let hostSees = (try? String(contentsOf: project.appendingPathComponent("from-guest.txt"), encoding: .utf8)) ?? "<missing>"
            report.set("step3.virtiofs.guestWrite", "exit=\(r.exitCode) owner=\(r.stdout) hostSees=\(hostSees.trimmingCharacters(in: .whitespacesAndNewlines))")
            try "changed on host\n".write(to: project.appendingPathComponent("index.html"), atomically: false, encoding: .utf8)
            let r3 = try await execIn(
                web, id: "exec-write-uid", ["/bin/sh", "-c", "id; echo x > /var/www/html/from-host-uid.txt && ls -ln /var/www/html"],
                user: ContainerizationOCI.User(uid: getuid(), gid: getgid()))
            report.set("step3.virtiofs.writeAsHostUid", "exit=\(r3.exitCode) \(r3.stdout) \(r3.stderr)")
            let hostAttrs = try? FileManager.default.attributesOfItem(atPath: project.appendingPathComponent("from-guest.txt").path)
            report.set("step3.virtiofs.hostOwnerOfRootWrittenFile", "\(hostAttrs?[.ownerAccountName] ?? "?")")
            let r2 = try await execIn(web, id: "exec-read", ["/bin/cat", "/var/www/html/index.html"])
            report.set("step3.virtiofs.hostEditVisibleInGuest", r2.stdout)
        } catch {
            report.set("step3.virtiofs.rw", "FAILED: \(error)")
        }

        // ---- Step 6: logs -------------------------------------------------------
        report.set("step6.web.stdout.lines", webOut.count)
        report.set("step6.web.stderr.lines", webErr.count)
        report.set("step6.web.stdout.tail", webOut.tail(8))
        report.set("step6.web.stderr.tail", webErr.tail(8))

        // ---- Optional: db container --------------------------------------------
        var db: LinuxContainer?
        if !skipDB {
            do {
                db = try await startDB(dbRef: dbRef, platform: arm64, manager: &manager, logs: logs, report: report, web: web)
            } catch {
                report.set("db", "FAILED: \(error)")
            }
        }

        if hold > 0 {
            log("Holding for \(hold)s: web at http://\(webIP)/ (Ctrl-C to abort)")
            try? await Task.sleep(for: .seconds(hold))
        }

        // ---- Step 4b: restart; is the IP stable? ------------------------------------
        let macBefore = (try? await execIn(web, id: "mac-before", ["/bin/cat", "/sys/class/net/eth0/address"]).stdout) ?? "?"
        report.set("step4b.web.macBefore", macBefore)
        report.set("step4b.host.arpBefore", host(["/usr/sbin/arp", "-an"]).split(separator: "\n").filter { $0.contains("(\(webIP))") }.joined(separator: "; "))
        do {
            try await timed("step4b.web.stop", report) { try await web.stop() }
            if env("SPIKE_RESTART_REUSE_ROOTFS") != "1" {
                // Fresh copy-on-write clone of the image rootfs, i.e. Docker/DDEV
                // "recreate container" semantics. Reusing the dirty rootfs hangs
                // ddev-webserver (stale /var/tmp/logpipe FIFO, see spike doc).
                _ = try await prepareRootfs(id: "spike-web", image: webImage, platform: arm64, manager: manager, home: home, report: report, key: "step4b.web")
                report.set("step4b.web.rootfs", "fresh clone")
            } else {
                report.set("step4b.web.rootfs", "reused dirty rootfs from first boot")
            }
            try await timed("step4b.web.create (reboot same LinuxContainer)", report) { try await web.create() }
            try await timed("step4b.web.start", report) { try await web.start() }
            let ipAfter = web.interfaces.first?.ipv4Address.address.description ?? "nil"
            report.set("step4b.web.ipAfterRestartSameObject", ipAfter)
            report.set("step4b.web.ipStableSameObject", ipAfter == webIP)
            let macAfter = (try? await execIn(web, id: "mac-after", ["/bin/cat", "/sys/class/net/eth0/address"]).stdout) ?? "?"
            report.set("step4b.web.macAfter", macAfter)
            await probeFromHost(ip: ipAfter, report: report, key: "step4b.web.afterRestart")
            report.set("step4b.host.arpAfter", host(["/usr/sbin/arp", "-an"]).split(separator: "\n").filter { $0.contains("(\(ipAfter))") }.joined(separator: "; "))
            let inside = try? await execIn(web, id: "curl-inside", ["/bin/sh", "-c", "curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1/index.html; echo; ps -eo pid,comm | head -20"])
            report.set("step4b.web.insideAfterRestart", inside?.stdout ?? "exec failed")
            report.set("step6.web.stdout.tailAfterRestart", webOut.tail(5))
            report.set("step6.web.stderr.tailAfterRestart", webErr.tail(5))
        } catch {
            report.set("step4b.restart", "FAILED: \(error)")
        }

        // ---- Step 7: stop + cleanup ----------------------------------------------
        if let db {
            try? await timed("step7.db.stop", report) { try await db.stop() }
            try? manager.delete("spike-db")
        }
        try await timed("step7.web.stop", report) { try await web.stop() }
        try manager.delete("spike-web")
        report.set("step7.cleanup", "containers stopped, per-container dirs + IP allocations released")
    }


    /// ContainerManager.create(_:reference:/image:) unpacks the image into a
    /// fresh ext4 file on every create, and manager.delete removes it. That
    /// unpack is by far the slowest step, so production code should unpack once
    /// per image digest and hand each container an APFS clone (clonefile(2):
    /// instant, copy-on-write) through the `create(_:image:rootfs:)` overload.
    static func prepareRootfs(id: String, image: Containerization.Image, platform: Platform, manager: ContainerManager, home: URL, report: Report, key: String) async throws -> Containerization.Mount {
        let cacheDir = home.appendingPathComponent("rootfs-cache")
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let digest = try await image.descriptor(for: platform).digest.replacingOccurrences(of: ":", with: "-")
        let cached = cacheDir.appendingPathComponent("\(digest).ext4")
        if !FileManager.default.fileExists(atPath: cached.path) {
            let partial = cacheDir.appendingPathComponent("\(digest).ext4.partial")
            try? FileManager.default.removeItem(at: partial)
            _ = try await timed("\(key).EXT4Unpacker.unpack (one-time per image digest)", report) {
                try await EXT4Unpacker(capacityInBytes: 8.gib()).unpack(image, for: platform, at: partial)
            }
            try FileManager.default.moveItem(at: partial, to: cached)
        } else {
            report.set("\(key).rootfsUnpack", "cached \(cached.lastPathComponent)")
        }
        let containerDir = manager.imageStore.path.appendingPathComponent("containers/\(id)")
        try FileManager.default.createDirectory(at: containerDir, withIntermediateDirectories: true)
        let dest = containerDir.appendingPathComponent("rootfs.ext4")
        try? FileManager.default.removeItem(at: dest)
        let start = Date()
        guard clonefile(cached.path, dest.path, 0) == 0 else {
            throw SpikeError("clonefile failed: \(String(cString: strerror(errno)))")
        }
        report.timing("\(key).clonefile rootfs", elapsed(since: start))
        return .block(format: "ext4", source: dest.path, destination: "/", options: [])
    }

    /// SPIKE_MODE=net: boot one small container (php -S) in this process and
    /// hold it, so two concurrent spike processes can be compared: does each
    /// process get its own vmnet subnet, or do they collide on the same IP?
    static func netProbe(_ report: Report) async throws {
        let home = try spikeHome()
        let id = env("SPIKE_NET_ID") ?? "net-\(ProcessInfo.processInfo.processIdentifier)"
        let hold = Int(env("SPIKE_HOLD") ?? "20") ?? 20
        let arm64 = Platform(arch: "arm64", os: "linux")
        let network = try env("SPIKE_SUBNET").map { try VmnetNetwork(subnet: try CIDRv4($0)) } ?? VmnetNetwork()
        report.set("net.\(id).subnet", network.subnet.description)
        var manager = try await ContainerManager(
            kernel: Kernel(path: home.appendingPathComponent("vmlinux-arm64"), platform: .linuxArm),
            initfsReference: env("SPIKE_INITFS") ?? "ghcr.io/apple/containerization/vminit:0.45.0",
            root: home.appendingPathComponent("store"),
            network: network
        )
        try? manager.delete(id)
        let image = try await pullImage(env("SPIKE_WEB_IMAGE") ?? "docker.io/ddev/ddev-webserver:v1.25.4", platform: arm64, manager: manager, report: report, key: "net")
        let rootfs = try await prepareRootfs(id: id, image: image, platform: arm64, manager: manager, home: home, report: report, key: "net.\(id)")
        let c = try await manager.create(id, image: image, rootfs: rootfs) { config in
            config.cpus = 1
            config.memoryInBytes = 512.mib()
            config.hostname = id
            config.hosts = hostsFile(for: config, names: [id])
            config.process.arguments = ["/bin/sh", "-c", "echo \(id) > /tmp/index.html; exec php -S 0.0.0.0:80 -t /tmp"]
        }
        try await c.create()
        try await c.start()
        let ip = c.interfaces.first?.ipv4Address.address.description ?? "nil"
        report.set("net.\(id).ip", ip)
        try? await Task.sleep(for: .seconds(2))
        await probeFromHost(ip: ip, report: report, key: "net.\(id)", paths: ["/index.html"], timeout: 10)
        try? await Task.sleep(for: .seconds(hold))
        // Probe again at the end: if another process grabbed the same IP, which one answers now?
        await probeFromHost(ip: ip, report: report, key: "net.\(id).afterHold", paths: ["/index.html"], timeout: 5)
        try await c.stop()
        try manager.delete(id)
    }

    static func pullImage(_ ref: String, platform: Platform, manager: ContainerManager, report: Report, key: String) async throws -> Containerization.Image {
        if let cached = try? await manager.imageStore.get(reference: ref) {
            report.set("\(key).pull", "cached (delete \(manager.imageStore.path.path) to re-measure)")
            return cached
        }
        let total = BytesCounter()
        let image = try await timed("\(key).imageStore.pull \(ref)", report) {
            try await manager.imageStore.pull(reference: ref, platform: platform) { events in
                for e in events {
                    if case .addSize(let n) = e { total.add(n) }
                }
            }
        }
        report.set("\(key).pulledBytes", total.value)
        return image
    }

    static func probeFromHost(ip: String, report: Report, key: String, paths: [String] = ["/index.html", "/index.php"], timeout: TimeInterval? = nil) async {
        for path in paths {
            guard let url = URL(string: "http://\(ip)\(path)") else { continue }
            if let r = await probeHTTP(url, timeout: timeout ?? (path == "/index.html" ? 90 : 10)) {
                report.set("\(key).GET \(path)", "HTTP \(r.status) after \(r.afterSeconds)s: \(r.body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))")
            } else {
                report.set("\(key).GET \(path)", "no HTTP response from host")
            }
        }
    }

    static func startDB(dbRef: String, platform: Platform, manager: inout ContainerManager, logs: URL, report: Report, web: LinuxContainer) async throws -> LinuxContainer {
        let dbImage = try await pullImage(dbRef, platform: platform, manager: manager, report: report, key: "db")
        let dbOut = LineCollector(name: "db:stdout", logFile: logs.appendingPathComponent("db.stdout.log"))
        let dbErr = LineCollector(name: "db:stderr", logFile: logs.appendingPathComponent("db.stderr.log"))
        let home = logs.deletingLastPathComponent()
        let dbRootfs = try await prepareRootfs(id: "spike-db", image: dbImage, platform: platform, manager: manager, home: home, report: report, key: "db")
        let db = try await timed("db.manager.create (LinuxContainer config)", report) {
            try await manager.create("spike-db", image: dbImage, rootfs: dbRootfs) { config in
                config.cpus = 2
                config.memoryInBytes = 1.gib()
                config.hostname = "spike-db"
                config.hosts = hostsFile(for: config, names: ["spike-db", "db"])
                config.process.environmentVariables += ["TZ=UTC", "DDEV_PROJECT=spike"]
                // mysqld refuses to run as root; DDEV runs the db container as the
                // host user's uid:gid (compose `user:`), and the image is built to
                // tolerate an arbitrary uid. Do the same.
                config.process.user = ContainerizationOCI.User(uid: getuid(), gid: getgid())
                config.process.stdout = dbOut
                config.process.stderr = dbErr
            }
        }
        try await timed("db.container.create (VM boot)", report) { try await db.create() }
        try await timed("db.container.start", report) { try await db.start() }
        guard let dbIP = db.interfaces.first?.ipv4Address.address.description else { throw SpikeError("db has no interface") }
        report.set("db.ipv4", db.interfaces.first?.ipv4Address.description ?? "nil")

        // Wait for mysqld, then check web -> db over the vmnet network.
        let start = Date()
        var ready = false
        var attempt = 0
        while Date().timeIntervalSince(start) < 120 {
            attempt += 1
            let r = try await execIn(db, id: "db-ping-\(attempt)", ["/bin/sh", "-c", "mysqladmin ping -uroot -proot --socket=/var/tmp/mysql.sock 2>&1 || mysqladmin ping -uroot 2>&1"])
            if r.exitCode == 0 { ready = true; break }
            try await Task.sleep(for: .seconds(2))
        }
        report.set("db.readyAfterSeconds", ready ? elapsed(since: start) : -1)
        let r = try await execIn(
            web, id: "web-to-db",
            ["/bin/sh", "-c", "mysql -h \(dbIP) -udb -pdb -e 'SELECT VERSION(), @@hostname' db 2>&1; echo exit=$?"])
        report.set("db.webToDbByIP", r.stdout)
        report.set("db.stdout.tail", dbOut.tail(5))
        report.set("db.stderr.tail", dbErr.tail(5))
        return db
    }
}

final class BytesCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var total: Int64 = 0
    func add(_ n: Int64) { lock.withLock { total += n } }
    var value: Int64 { lock.withLock { total } }
}

struct SpikeError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}
