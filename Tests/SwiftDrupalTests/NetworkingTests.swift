import Darwin
import Foundation
import Testing
@testable import SwiftDrupal

// MARK: - Helpers

private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "SwiftDrupalNetworkingTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private struct ParsedResponse {
    var id: UInt16
    var flags: UInt16
    var rcode: UInt8 { UInt8(flags & 0x0F) }
    var qdcount: UInt16
    var ancount: UInt16
    var answerIP: String?
    var ttl: UInt32?

    init(_ bytes: [UInt8]) {
        func u16(_ i: Int) -> UInt16 { UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1]) }
        id = u16(0)
        flags = u16(2)
        qdcount = u16(4)
        ancount = u16(6)
        guard ancount > 0 else { return }
        // Skip the question: labels, then type + class.
        var offset = 12
        while bytes[offset] != 0 { offset += Int(bytes[offset]) + 1 }
        offset += 5
        // Answer: 2-byte name pointer, type, class, ttl, rdlength, rdata.
        #expect(bytes[offset] == 0xC0 && bytes[offset + 1] == 0x0C)
        #expect(u16(offset + 2) == DNSQueryHandler.typeA)
        ttl = UInt32(u16(offset + 6)) << 16 | UInt32(u16(offset + 8))
        #expect(u16(offset + 10) == 4)
        answerIP = bytes[(offset + 12)..<(offset + 16)].map(String.init).joined(separator: ".")
    }
}

/// In-memory writer that records every write (and never touches disk).
private final class RecordingWriter: PrivilegedFileWriter, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: String] = [:]
    private(set) var writeCount = 0

    func readFile(atPath path: String) -> String? { lock.withLock { files[path] } }
    func writeFile(_ contents: String, atPath path: String) throws {
        lock.withLock { files[path] = contents; writeCount += 1 }
    }
    func removeFile(atPath path: String) throws { _ = lock.withLock { files.removeValue(forKey: path) } }
}

private struct StubVerifier: HostnameResolverVerifier {
    let result: Bool
    func verify(hostname: String, expectedIP: String) async -> Bool { result }
}

private struct FailingStrategy: HostnameStrategy {
    var kind: HostnameStrategyKind { .localResolver }
    func activate(hostname: String, ip: String) async throws {
        throw HostnameError.responderFailed("simulated bind failure")
    }
    func deactivate(hostname: String) async throws {}
    func currentAddress(for hostname: String) -> IPv4? { nil }
}

// MARK: - DNS query answering

@Suite struct DNSQueryHandlerTests {
    let store = DNSRecordStore()
    var handler: DNSQueryHandler { DNSQueryHandler(store: store) }

    init() { store.set(IPv4("192.168.64.7")!, for: "mysite.drupal") }

    @Test func answersARecordForRegisteredHostname() throws {
        let reply = try #require(handler.response(to: DNSQueryHandler.makeQuery(id: 0xBEEF, name: "mysite.drupal")))
        let parsed = ParsedResponse(reply)
        #expect(parsed.id == 0xBEEF)
        #expect(parsed.flags & 0x8000 != 0)  // QR
        #expect(parsed.flags & 0x0400 != 0)  // AA
        #expect(parsed.flags & 0x0100 != 0)  // RD echoed
        #expect(parsed.rcode == DNSQueryHandler.RCode.noError.rawValue)
        #expect(parsed.qdcount == 1)
        #expect(parsed.ancount == 1)
        #expect(parsed.answerIP == "192.168.64.7")
        #expect(parsed.ttl == 1)
    }

    @Test func matchingIsCaseInsensitiveAndIgnoresTrailingDot() throws {
        for name in ["MySite.DRUPAL", "mysite.drupal."] {
            let reply = try #require(handler.response(to: DNSQueryHandler.makeQuery(id: 1, name: name)))
            #expect(ParsedResponse(reply).answerIP == "192.168.64.7")
        }
        // Mixed-case bytes on the wire (makeQuery lowercases, so hand-craft).
        var query = DNSQueryHandler.makeQuery(id: 2, name: "mysite.drupal")
        query[13] = UInt8(ascii: "M")
        let reply = try #require(handler.response(to: query))
        #expect(ParsedResponse(reply).answerIP == "192.168.64.7")
        #expect(reply[13] == UInt8(ascii: "M"))  // question echoed verbatim
    }

    @Test func subdomainOfRegisteredHostnameResolves() throws {
        let reply = try #require(handler.response(to: DNSQueryHandler.makeQuery(id: 3, name: "www.mysite.drupal")))
        #expect(ParsedResponse(reply).answerIP == "192.168.64.7")
    }

    @Test func unknownDrupalNameIsNXDOMAIN() throws {
        let reply = try #require(handler.response(to: DNSQueryHandler.makeQuery(id: 4, name: "other.drupal")))
        let parsed = ParsedResponse(reply)
        #expect(parsed.rcode == DNSQueryHandler.RCode.nameError.rawValue)
        #expect(parsed.ancount == 0)
        #expect(parsed.qdcount == 1)
    }

    @Test func nonDrupalNameIsRefused() throws {
        for name in ["example.com", "drupal.org", "mysite.drupalx"] {
            let reply = try #require(handler.response(to: DNSQueryHandler.makeQuery(id: 5, name: name)))
            let parsed = ParsedResponse(reply)
            #expect(parsed.rcode == DNSQueryHandler.RCode.refused.rawValue, "\(name)")
            #expect(parsed.ancount == 0)
        }
    }

    @Test func aaaaQueryForKnownNameIsNoDataNotNXDOMAIN() throws {
        let reply = try #require(handler.response(to: DNSQueryHandler.makeQuery(id: 6, name: "mysite.drupal", type: 28)))
        let parsed = ParsedResponse(reply)
        #expect(parsed.rcode == DNSQueryHandler.RCode.noError.rawValue)
        #expect(parsed.ancount == 0)
    }

    @Test func updatingTheStoreChangesTheAnswer() throws {
        store.set(IPv4("192.168.64.99")!, for: "mysite.drupal")
        let reply = try #require(handler.response(to: DNSQueryHandler.makeQuery(id: 7, name: "mysite.drupal")))
        #expect(ParsedResponse(reply).answerIP == "192.168.64.99")
        store.remove("mysite.drupal")
        let gone = try #require(handler.response(to: DNSQueryHandler.makeQuery(id: 8, name: "mysite.drupal")))
        #expect(ParsedResponse(gone).rcode == DNSQueryHandler.RCode.nameError.rawValue)
    }

    @Test func malformedInputIsDroppedOrFormErr() throws {
        #expect(handler.response(to: [0x00, 0x01, 0x02]) == nil)  // shorter than a header
        var response = DNSQueryHandler.makeQuery(id: 9, name: "mysite.drupal")
        response[2] |= 0x80  // QR set: a response, not a query
        #expect(handler.response(to: response) == nil)

        let truncated = Array(DNSQueryHandler.makeQuery(id: 10, name: "mysite.drupal").dropLast(3))
        let reply = try #require(handler.response(to: truncated))
        #expect(ParsedResponse(reply).rcode == DNSQueryHandler.RCode.formatError.rawValue)
    }

    @Test func nonStandardOpcodeIsNotImplemented() throws {
        var query = DNSQueryHandler.makeQuery(id: 11, name: "mysite.drupal")
        query[2] |= 0x28  // opcode 5 (UPDATE)
        let reply = try #require(handler.response(to: query))
        #expect(ParsedResponse(reply).rcode == DNSQueryHandler.RCode.notImplemented.rawValue)
    }

    @Test func ipv4Validation() {
        #expect(IPv4("10.0.0.1")?.description == "10.0.0.1")
        #expect(IPv4("256.0.0.1") == nil)
        #expect(IPv4("1.2.3") == nil)
        #expect(IPv4("a.b.c.d") == nil)
        #expect(IPv4("1..2.3") == nil)
    }
}

// MARK: - Socket layer (ephemeral port on 127.0.0.1 only)

@Suite struct LocalDNSServerTests {
    @Test func answersOverUDPOnEphemeralLoopbackPort() throws {
        let store = DNSRecordStore()
        store.set(IPv4("192.168.64.20")!, for: "socket.drupal")
        let server = LocalDNSServer(handler: DNSQueryHandler(store: store), port: 0)
        let port = try server.start()
        defer { server.stop() }
        #expect(port != 0 && port != 53)
        #expect(try server.start() == port)  // idempotent

        let reply = try Self.udpQuery(DNSQueryHandler.makeQuery(id: 0x4242, name: "socket.drupal"), port: port)
        let parsed = ParsedResponse(reply)
        #expect(parsed.id == 0x4242)
        #expect(parsed.answerIP == "192.168.64.20")

        server.stop()
        #expect(!server.isRunning)
        #expect(server.port == nil)
    }

    static func udpQuery(_ query: [UInt8], port: UInt16) throws -> [UInt8] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        try #require(fd >= 0)
        defer { close(fd) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
        let sent = query.withUnsafeBytes { raw in
            withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        try #require(sent == query.count)
        var buffer = [UInt8](repeating: 0, count: 512)
        let received = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
        try #require(received > 0)
        return Array(buffer[0..<received])
    }
}

// MARK: - /etc/hosts editing (temp files only)

@Suite struct HostsFileTests {
    static let original = """
        ##
        # Host Database
        ##
        127.0.0.1\tlocalhost
        255.255.255.255\tbroadcasthost
        ::1             localhost
        10.0.0.5\tmysite.drupal
        """ + "\n"

    @Test func insertAppendsMarkedLineAndPreservesContent() {
        let updated = HostsFileEditor.inserting(hostname: "mysite.drupal", ip: IPv4("192.168.64.7")!, into: Self.original)
        #expect(updated.hasPrefix(Self.original))
        #expect(updated == Self.original + "192.168.64.7\tmysite.drupal\t# managed-by: drupal\n")
    }

    @Test func insertIsIdempotentAndReplacesOwnedLineOnIPChange() {
        let ip1 = IPv4("192.168.64.7")!
        let once = HostsFileEditor.inserting(hostname: "mysite.drupal", ip: ip1, into: Self.original)
        let twice = HostsFileEditor.inserting(hostname: "mysite.drupal", ip: ip1, into: once)
        #expect(once == twice)

        let moved = HostsFileEditor.inserting(hostname: "mysite.drupal", ip: IPv4("192.168.64.8")!, into: twice)
        #expect(moved.components(separatedBy: HostsFileEditor.marker).count == 2)  // exactly one owned line
        #expect(moved.contains("192.168.64.8\tmysite.drupal"))
        #expect(!moved.contains("192.168.64.7"))
    }

    @Test func removeDeletesOnlyOwnedLines() {
        let withTwo = HostsFileEditor.inserting(
            hostname: "other.drupal", ip: IPv4("192.168.64.9")!,
            into: HostsFileEditor.inserting(hostname: "mysite.drupal", ip: IPv4("192.168.64.7")!, into: Self.original))
        let removed = HostsFileEditor.removing(hostname: "mysite.drupal", from: withTwo)
        // The user's own unmarked `10.0.0.5 mysite.drupal` line survives.
        #expect(removed == Self.original + "192.168.64.9\tother.drupal\t# managed-by: drupal\n")
        #expect(HostsFileEditor.removing(hostname: "other.drupal", from: removed) == Self.original)
    }

    @Test func insertIntoContentWithoutTrailingNewlineOrEmpty() {
        let ip = IPv4("1.2.3.4")!
        #expect(HostsFileEditor.inserting(hostname: "a.drupal", ip: ip, into: "127.0.0.1 localhost")
            == "127.0.0.1 localhost\n1.2.3.4\ta.drupal\t# managed-by: drupal\n")
        #expect(HostsFileEditor.inserting(hostname: "a.drupal", ip: ip, into: "")
            == "1.2.3.4\ta.drupal\t# managed-by: drupal\n")
    }

    @Test func strategyActivateAndDeactivateAgainstTempFile() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hosts = dir.appending(path: "hosts")
        try Self.original.write(to: hosts, atomically: true, encoding: .utf8)

        let strategy = HostsFileStrategy(path: hosts.path, writer: DirectFileWriter())
        #expect(strategy.kind == .hostsFile)
        try await strategy.activate(hostname: "fresh.drupal", ip: "192.168.64.7")
        try await strategy.activate(hostname: "fresh.drupal", ip: "192.168.64.7")
        let afterActivate = try String(contentsOf: hosts, encoding: .utf8)
        #expect(afterActivate == Self.original + "192.168.64.7\tfresh.drupal\t# managed-by: drupal\n")
        #expect(strategy.currentAddress(for: "FRESH.drupal")?.description == "192.168.64.7")

        try await strategy.update(hostname: "fresh.drupal", ip: "192.168.64.11")
        #expect(strategy.currentAddress(for: "fresh.drupal")?.description == "192.168.64.11")

        try await strategy.deactivate(hostname: "fresh.drupal")
        try await strategy.deactivate(hostname: "fresh.drupal")
        #expect(try String(contentsOf: hosts, encoding: .utf8) == Self.original)
        #expect(strategy.currentAddress(for: "fresh.drupal") == nil)
    }

    @Test func strategySkipsWriteWhenUnchanged() async throws {
        let writer = RecordingWriter()
        let strategy = HostsFileStrategy(path: "/nonexistent-test-path/hosts", writer: writer)
        try await strategy.activate(hostname: "a.drupal", ip: "10.1.1.1")
        try await strategy.activate(hostname: "a.drupal", ip: "10.1.1.1")
        #expect(writer.writeCount == 1)
    }

    @Test func strategyRejectsInvalidInput() async throws {
        let strategy = HostsFileStrategy(path: "/nonexistent-test-path/hosts", writer: RecordingWriter())
        await #expect(throws: HostnameError.invalidIPAddress("nope")) {
            try await strategy.activate(hostname: "a.drupal", ip: "nope")
        }
        await #expect(throws: HostnameError.invalidHostname("example.com")) {
            try await strategy.activate(hostname: "example.com", ip: "10.0.0.1")
        }
    }
}

// MARK: - Resolver registration, strategies, and fallback

@Suite struct HostnameStrategySelectionTests {
    @Test func resolverFileUsesPortDirectiveAndRegistersOnce() throws {
        let writer = RecordingWriter()
        let registrar = ResolverFileRegistrar(path: "/nonexistent-test-path/resolver/drupal", writer: writer)
        #expect(ResolverFileRegistrar.defaultPath == "/etc/resolver/drupal")
        let contents = ResolverFileRegistrar.contents(port: 1053)
        #expect(contents.contains("nameserver 127.0.0.1\n"))
        #expect(contents.contains("port 1053\n"))

        #expect(try registrar.register(port: 1053))
        #expect(try !registrar.register(port: 1053))  // one-time: no second privileged write
        #expect(writer.writeCount == 1)
        #expect(try registrar.register(port: 2053))  // stale port is rewritten
        try registrar.unregister()
        #expect(!registrar.isRegistered(port: 2053))
    }

    @Test func defaultKindIsLocalResolver() {
        #expect(HostnameStrategyKind.default == .localResolver)
        let config = HostnameResolution.Configuration(
            resolverFilePath: "/nonexistent-test-path/resolver", hostsFilePath: "/nonexistent-test-path/hosts",
            responderPort: 0, writer: RecordingWriter(), verifier: StubVerifier(result: true))
        let coordinator = HostnameResolution.makeDefaultCoordinator(configuration: config)
        #expect(coordinator.primary.kind == .localResolver)
        #expect(coordinator.fallback.kind == .hostsFile)
        #expect(coordinator.primary is LocalResolverStrategy)
        #expect(coordinator.fallback is HostsFileStrategy)
    }

    @Test func verifiedLocalResolverIsSelectedAndAnswers() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let resolverPath = dir.appending(path: "resolver/drupal").path
        let hostsPath = dir.appending(path: "hosts").path
        try "127.0.0.1\tlocalhost\n".write(toFile: hostsPath, atomically: true, encoding: .utf8)

        let config = HostnameResolution.Configuration(
            resolverFilePath: resolverPath, hostsFilePath: hostsPath,
            responderPort: 0, writer: DirectFileWriter(), verifier: StubVerifier(result: true))
        let coordinator = HostnameResolution.makeDefaultCoordinator(configuration: config)
        let primary = try #require(coordinator.primary as? LocalResolverStrategy)
        defer { primary.shutdown() }

        let activation = try await coordinator.activate(hostname: "site.drupal", ip: "192.168.64.30")
        #expect(activation.kind == .localResolver)
        #expect(!activation.usedFallback)
        #expect(activation.warnings.isEmpty)

        let port = try #require(primary.server.port)
        #expect(try String(contentsOfFile: resolverPath, encoding: .utf8) == ResolverFileRegistrar.contents(port: port))
        #expect(try String(contentsOfFile: hostsPath, encoding: .utf8) == "127.0.0.1\tlocalhost\n")

        // Real query through the running responder.
        let reply = try LocalDNSServerTests.udpQuery(DNSQueryHandler.makeQuery(id: 1, name: "site.drupal"), port: port)
        #expect(ParsedResponse(reply).answerIP == "192.168.64.30")

        // IP update on the next start is reflected immediately.
        try await primary.update(hostname: "site.drupal", ip: "192.168.64.31")
        let updated = try LocalDNSServerTests.udpQuery(DNSQueryHandler.makeQuery(id: 2, name: "site.drupal"), port: port)
        #expect(ParsedResponse(updated).answerIP == "192.168.64.31")
    }

    @Test func resolverVerificationFailureFallsBackToHostsFile() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let resolverPath = dir.appending(path: "resolver/drupal").path
        let hostsPath = dir.appending(path: "hosts").path
        let originalHosts = "127.0.0.1\tlocalhost\n"
        try originalHosts.write(toFile: hostsPath, atomically: true, encoding: .utf8)

        let config = HostnameResolution.Configuration(
            resolverFilePath: resolverPath, hostsFilePath: hostsPath,
            responderPort: 0, writer: DirectFileWriter(), verifier: StubVerifier(result: false))
        let coordinator = HostnameResolution.makeDefaultCoordinator(configuration: config)
        defer { (coordinator.primary as? LocalResolverStrategy)?.shutdown() }

        let activation = try await coordinator.activate(hostname: "broken.drupal", ip: "192.168.64.40")

        #expect(activation.usedFallback)
        #expect(activation.kind == .hostsFile)
        #expect(activation.strategy is HostsFileStrategy)
        #expect(activation.warnings.count == 1)
        #expect(activation.warnings[0].contains("fell back to the hosts-file strategy"))
        #expect(activation.warnings[0].contains("broken.drupal"))

        // The fallback strategy answers the query instead.
        #expect(activation.strategy.currentAddress(for: "broken.drupal")?.description == "192.168.64.40")
        let hosts = try String(contentsOfFile: hostsPath, encoding: .utf8)
        #expect(hosts == originalHosts + "192.168.64.40\tbroken.drupal\t# managed-by: drupal\n")
        // The unverified primary no longer claims the hostname.
        #expect(coordinator.primary.currentAddress(for: "broken.drupal") == nil)
    }

    @Test func primaryActivationErrorAlsoFallsBack() async throws {
        let writer = RecordingWriter()
        let hostsPath = "/nonexistent-test-path/hosts"
        let coordinator = HostnameResolutionCoordinator(
            primary: FailingStrategy(),
            fallback: HostsFileStrategy(path: hostsPath, writer: writer),
            verifier: StubVerifier(result: true))
        let activation = try await coordinator.activate(hostname: "x.drupal", ip: "10.9.9.9")
        #expect(activation.usedFallback)
        #expect(activation.warnings.first?.contains("simulated bind failure") == true)
        #expect(writer.readFile(atPath: hostsPath)?.contains("10.9.9.9\tx.drupal") == true)
    }

    @Test func invalidIPDoesNotTriggerFallback() async throws {
        let writer = RecordingWriter()
        let coordinator = HostnameResolutionCoordinator(
            primary: FailingStrategy(),
            fallback: HostsFileStrategy(path: "/nonexistent-test-path/hosts", writer: writer),
            verifier: StubVerifier(result: true))
        await #expect(throws: HostnameError.invalidIPAddress("999.1.1.1")) {
            _ = try await coordinator.activate(hostname: "x.drupal", ip: "999.1.1.1")
        }
        #expect(writer.writeCount == 0)
    }
}
