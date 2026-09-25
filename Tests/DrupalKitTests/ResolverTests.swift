import Foundation
import Testing
@testable import DrupalKit

// The `.drupal` resolver: hosts file, DNS wire format, a live responder on an
// ephemeral port, install/uninstall against a sandbox, and start/stop
// registration. Nothing here touches /etc, launchd, or ~/Library.

private func sandbox() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: "drupalkit-resolver-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Suite struct HostsFileTests {
    @Test func setReplaceRemove() throws {
        let hosts = HostsFile(url: try sandbox().appending(path: "state/hosts"))
        #expect(try hosts.entries().isEmpty)
        #expect(try hosts.set("My-Site.drupal", to: "192.168.64.5"))
        #expect(try !hosts.set("my-site.drupal", to: "192.168.64.5"))  // unchanged
        #expect(try hosts.set("my-site.drupal", to: "192.168.64.9"))
        #expect(try hosts.set("other.drupal", to: "fd00::2"))
        #expect(try hosts.entries() == ["my-site.drupal": "192.168.64.9", "other.drupal": "fd00::2"])
        #expect(try hosts.remove("my-site.drupal"))
        #expect(try !hosts.remove("my-site.drupal"))
        #expect(try hosts.entries() == ["other.drupal": "fd00::2"])
    }

    @Test func parsesHostsFormatAndIgnoresJunk() {
        let text = """
            # comment
            192.168.64.2  a.drupal b.drupal  # trailing comment
            not-an-ip c.drupal
            10.0.0.1
            """
        #expect(HostsFile.parse(text) == ["a.drupal": "192.168.64.2", "b.drupal": "192.168.64.2"])
    }

    @Test func rejectsNonIP() throws {
        let hosts = HostsFile(url: try sandbox().appending(path: "hosts"))
        #expect(throws: DrupalError.self) { try hosts.set("x.drupal", to: "nope") }
    }
}

@Suite struct DNSWireTests {
    let hosts = ["my-site.drupal": "192.168.64.5", "v6.drupal": "fd00::2"]

    func ask(_ name: String, _ type: DNS.QType = .a) throws -> DNSProbe.Response {
        let response = try #require(DNS.answer(DNS.query(name, type: type, id: 0x1234), hosts: hosts))
        #expect(Array(response[0...1]) == [0x12, 0x34])
        return try #require(DNSProbe.parse(response))
    }

    @Test func answersRegisteredName() throws {
        #expect(try ask("my-site.drupal") == .init(rcode: 0, addresses: ["192.168.64.5"]))
        #expect(try ask("MY-SITE.Drupal") == .init(rcode: 0, addresses: ["192.168.64.5"]))
    }

    @Test func subdomainsResolveToTheirProject() throws {
        #expect(try ask("sub.my-site.drupal").addresses == ["192.168.64.5"])
    }

    @Test func aaaaForV4HostIsNoData() throws {
        #expect(try ask("my-site.drupal", .aaaa) == .init(rcode: 0, addresses: []))
        #expect(try ask("v6.drupal", .aaaa).addresses == ["fd00::2"])
    }

    @Test func unknownNameIsNXDomain() throws {
        #expect(try ask("nope.drupal").rcode == DNS.RCode.nxDomain.rawValue)
    }

    @Test func otherZonesAreRefused() throws {
        #expect(try ask("example.com").rcode == DNS.RCode.refused.rawValue)
        #expect(try ask("drupal.org").rcode == DNS.RCode.refused.rawValue)
    }

    @Test func malformedInput() {
        #expect(DNS.answer([1, 2, 3], hosts: hosts) == nil)
        var truncated = DNS.query("my-site.drupal", type: .a, id: 1)
        truncated.removeLast(3)
        #expect(DNS.answer(truncated, hosts: hosts).map { $0[3] & 0x0F } == DNS.RCode.formErr.rawValue)
    }
}

@Suite struct DNSResponderTests {
    /// A real UDP responder on an ephemeral port, picking up hosts-file changes live.
    @Test func servesFromTheHostsFileOverUDP() async throws {
        let hosts = HostsFile(url: try sandbox().appending(path: "hosts"))
        try hosts.set("my-site.drupal", to: "192.168.64.5")
        let responder = try DNSResponder(hostsFile: hosts, port: 0)
        let thread = Thread { responder.run() }
        thread.start()
        defer { responder.stop() }

        #expect(DNSProbe.query("my-site.drupal", port: responder.port)?.addresses == ["192.168.64.5"])
        // mtime granularity: make sure the change is visible as a change.
        try await Task.sleep(for: .milliseconds(1100))
        try hosts.set("my-site.drupal", to: "192.168.64.6")
        #expect(DNSProbe.query("my-site.drupal", port: responder.port)?.addresses == ["192.168.64.6"])
        #expect(DNSProbe.query("gone.drupal", port: responder.port)?.rcode == DNS.RCode.nxDomain.rawValue)
    }

    @Test func bindConflictIsAnError() throws {
        let hosts = HostsFile(url: try sandbox().appending(path: "hosts"))
        let first = try DNSResponder(hostsFile: hosts, port: 0)
        #expect(throws: DrupalError.self) { _ = try DNSResponder(hostsFile: hosts, port: first.port) }
    }
}

@Suite struct ResolverCommandTests {
    @Test func userInstallThenSudoInstallInEitherOrder() async throws {
        let dir = try sandbox()
        let services = FakeServices()
        let user = ResolverEnvironment.sandboxed(in: dir, services: services)
        let root = ResolverEnvironment.sandboxed(in: dir, isRoot: true, services: services)

        let first = await drupal("resolver", "install", in: dir, resolver: user)
        #expect(first.code == ExitStatus.permissionRequired.rawValue)
        #expect(first.envelope["command"] as? String == "resolver install")
        #expect(first.error["hint"] as? String == "Run once: sudo drupal resolver install")
        #expect(user.launchAgentState == .installed)
        #expect(services.isLoaded(ResolverEnvironment.agentLabel))

        let sudo = await drupal("resolver", "install", in: dir, resolver: root)
        #expect(sudo.code == 0)
        let written = try String(contentsOf: user.systemResolverFile, encoding: .utf8)
        #expect(written.contains("nameserver 127.0.0.1\nport 1\n"))

        let again = await drupal("resolver", "install", in: dir, resolver: user)
        #expect(again.code == 0)
        #expect(again.data["actions"] as? [String] == [])
        #expect(services.recorded == ["load"])  // idempotent: no reload
    }

    @Test func staleAgentIsReloaded() async throws {
        let dir = try sandbox()
        let services = FakeServices()
        var env = ResolverEnvironment.sandboxed(in: dir, services: services)
        _ = await drupal("resolver", "install", in: dir, resolver: env)
        env.executable = URL(filePath: "/opt/elsewhere/drupal")
        #expect(env.launchAgentState == .different)
        _ = await drupal("resolver", "install", in: dir, resolver: env)
        #expect(services.recorded == ["load", "unload", "load"])
        #expect(env.launchAgentState == .installed)
    }

    @Test func uninstallMirrorsInstall() async throws {
        let dir = try sandbox()
        let services = FakeServices()
        let user = ResolverEnvironment.sandboxed(in: dir, services: services)
        let root = ResolverEnvironment.sandboxed(in: dir, isRoot: true, services: services)
        _ = await drupal("resolver", "install", in: dir, resolver: user)
        _ = await drupal("resolver", "install", in: dir, resolver: root)

        #expect(await drupal("resolver", "uninstall", in: dir, resolver: user).code == ExitStatus.permissionRequired.rawValue)
        #expect(!services.isLoaded(ResolverEnvironment.agentLabel))
        #expect(await drupal("resolver", "uninstall", in: dir, resolver: root).code == 0)
        #expect(await drupal("resolver", "uninstall", in: dir, resolver: user).code == 0)
        #expect(user.systemResolverState == .missing && user.launchAgentState == .missing)
    }

    @Test func statusReportsProblemsButExitsZero() async throws {
        let dir = try sandbox()
        let r = await drupal("resolver", "status", in: dir, resolver: .sandboxed(in: dir))
        #expect(r.code == 0)
        #expect(r.data["healthy"] as? Bool == false)
        #expect((r.data["problems"] as? [String])?.count == 3)  // system file, agent, responder
        // `drupal resolver` alone is status.
        #expect(await drupal("resolver", in: dir, resolver: .sandboxed(in: dir)).envelope["command"] as? String == "resolver status")
    }

    @Test func startRegistersAndStopUnregisters() async throws {
        let dir = try tempProject(config: "")
        let env = ResolverEnvironment.sandboxed(in: dir.deletingLastPathComponent())
        let start = await drupal("start", in: dir, runtime: FakeRuntime(), resolver: env)
        #expect(start.code == 0)
        #expect(try env.hostsFile.entries() == ["my-pantheon-site.drupal": "192.168.64.2"])
        #expect((start.envelope["warnings"] as? [String])?.contains { $0.contains("resolver is set up") } == true)

        #expect(await drupal("stop", in: dir, runtime: FakeRuntime(), resolver: env).code == 0)
        #expect(try env.hostsFile.entries().isEmpty)
    }
}

@Suite struct SystemResolverFileTests {
    @Test func comparedByDirectiveNotBytes() throws {
        let dir = try sandbox()
        let env = ResolverEnvironment.sandboxed(in: dir)
        try FileManager.default.createDirectory(at: env.systemResolverFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "# someone else's comment\nport 1\nnameserver   127.0.0.1\n".write(to: env.systemResolverFile, atomically: true, encoding: .utf8)
        #expect(env.systemResolverState == .installed)
        try "nameserver 127.0.0.1\nport 2\n".write(to: env.systemResolverFile, atomically: true, encoding: .utf8)
        #expect(env.systemResolverState == .different)
    }
}
