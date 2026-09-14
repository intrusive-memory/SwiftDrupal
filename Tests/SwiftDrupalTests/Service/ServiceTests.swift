import ArgumentParser
import Darwin
import Foundation
import Synchronization
import Testing
@testable import SwiftDrupal

// MARK: - Helpers

/// A short socket directory under /tmp: `sockaddr_un.sun_path` caps paths at
/// 104 bytes, which deep `NSTemporaryDirectory()` paths can exceed.
private struct ShortTempDirectory: ~Copyable {
    let path: String

    init() throws {
        path = "/tmp/sd-\(UUID().uuidString.prefix(8).lowercased())"
        try FileManager.default.createDirectory(
            atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    var socketPath: String { path + "/s.sock" }

    deinit { try? FileManager.default.removeItem(atPath: path) }
}

/// Ordered, thread-safe event log shared by recording doubles.
private final class EventLog: Sendable {
    private let storage = Mutex<[String]>([])
    func append(_ event: String) { storage.withLock { $0.append(event) } }
    var events: [String] { storage.withLock { $0 } }
}

/// In-memory privileged writer (never touches real system files).
private final class MemoryWriter: PrivilegedFileWriter, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: String] = [:]
    private(set) var writes: [String] = []

    func readFile(atPath path: String) -> String? { lock.withLock { files[path] } }
    func writeFile(_ contents: String, atPath path: String) throws {
        lock.withLock {
            files[path] = contents
            writes.append(path)
        }
    }
    func removeFile(atPath path: String) throws { _ = lock.withLock { files.removeValue(forKey: path) } }
}

/// Scriptable hostname controller that records into an `EventLog`.
private final class RecordingHostnames: ServiceHostnameController, Sendable {
    let log: EventLog
    let requireHostsFile: Bool

    init(log: EventLog = EventLog(), requireHostsFile: Bool = false) {
        self.log = log
        self.requireHostsFile = requireHostsFile
    }

    func activate(hostname: String, ip: String) async throws -> HostnameActivationReport {
        log.append("activate:\(hostname)=\(ip)")
        return HostnameActivationReport(
            hostname: hostname, ip: ip, strategy: requireHostsFile ? .hostsFile : .localResolver,
            hostsFileWriteRequired: requireHostsFile,
            warnings: requireHostsFile ? ["Warning: fell back to the hosts-file strategy for \(hostname)."] : [])
    }

    func deactivate(hostname: String) async { log.append("deactivate:\(hostname)") }
    func shutdown() { log.append("responder-stopped") }
}

/// Forwards to a mock and records stop events into a shared log.
private struct EventRecordingContainers: ContainerService {
    let inner: MockContainerService
    let log: EventLog

    func pullImage(_ reference: String) async throws { try await inner.pullImage(reference) }
    func create(_ spec: ContainerSpec) async throws { try await inner.create(spec) }
    func start(id: String) async throws { try await inner.start(id: id) }
    func stop(id: String) async throws {
        try await Task.sleep(for: .milliseconds(20))  // a graceful stop takes time
        try await inner.stop(id: id)
        log.append("container-stopped:\(id)")
    }
    func delete(id: String) async throws { try await inner.delete(id: id) }
    func inspect(id: String) async throws -> ContainerStatus { try await inner.inspect(id: id) }
    func exec(id: String, _ request: ExecRequest) async throws -> ExecResult { try await inner.exec(id: id, request) }
    func logs(id: String, follow: Bool) async throws -> AsyncThrowingStream<LogLine, any Error> {
        try await inner.logs(id: id, follow: follow)
    }
}

private func webSpec(_ name: String = "site") -> ContainerSpec {
    ContainerSpec(
        id: "\(name)-web", role: .web, imageReference: "docker.io/ddev/ddev-webserver:v1",
        hostname: "\(name).drupal", environment: ["A=1"],
        mounts: [MountSpec(hostPath: "/p", containerPath: "/var/www/html")])
}

private func dbSpec(_ name: String = "site") -> ContainerSpec {
    ContainerSpec(id: "\(name)-db", role: .db, imageReference: "docker.io/ddev/ddev-dbserver:v1", hostname: "\(name)-db")
}

/// A running server over a real socket with a mock container service behind it.
private final class ServiceFixture: Sendable {
    let directory: String
    let socketPath: String
    let mock = MockContainerService()
    let hostnames: RecordingHostnames
    let server: ServiceServer

    init(hostnames: RecordingHostnames = RecordingHostnames()) throws {
        directory = "/tmp/sd-\(UUID().uuidString.prefix(8).lowercased())"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        socketPath = directory + "/s.sock"
        self.hostnames = hostnames
        server = ServiceServer(socketPath: socketPath, host: ServiceHost(containers: mock, hostnames: hostnames))
        try server.start()
    }

    func client(hostsFallback: (any HostnameStrategy)? = nil) -> ServiceClientContainerService {
        ServiceClientContainerService(socketPath: socketPath, hostsFallback: hostsFallback)
    }

    deinit {
        server.stop()
        try? FileManager.default.removeItem(atPath: directory)
    }
}

// MARK: - Framing

@Suite struct ServiceFramingTests {
    static let allRequests: [ServiceRequest] = [
        .ping,
        .pullImage(reference: "docker.io/ddev/ddev-webserver:v1.24.8"),
        .create(spec: webSpec()),
        .start(id: "site-web"),
        .stop(id: "site-web"),
        .delete(id: "site-db"),
        .inspect(id: "site-web"),
        .exec(
            id: "site-web",
            request: ExecRequestPayload(
                arguments: ["drush", "cr"], environment: ["X=1"], workingDirectory: "/var/www/html",
                terminal: true, hasStdin: true)),
        .logs(id: "site-web", follow: true),
        .activateHostname(hostname: "site.drupal", ip: "192.168.64.2"),
        .deactivateHostname(hostname: "site.drupal"),
    ]

    @Test(arguments: allRequests)
    func requestRoundTripsThroughFraming(request: ServiceRequest) throws {
        let frame = try ServiceFraming.encode(request)
        let length = frame.prefix(4).reduce(0) { $0 << 8 | Int($1) }
        #expect(length == frame.count - 4)

        var decoder = ServiceFrameDecoder()
        decoder.append(frame)
        #expect(try decoder.next(ServiceRequest.self) == request)
        #expect(decoder.bufferedByteCount == 0)
    }

    @Test func everyRequestKindIsCovered() {
        // Keep `allRequests` exhaustive when a request case is added.
        let kinds = Set(Self.allRequests.map { String(describing: $0).prefix(while: { $0 != "(" }) })
        #expect(kinds.count == 11)
        #expect(Self.allRequests.filter(\.isStreaming).count == 2)
    }

    @Test func responsesAndStreamInputsRoundTrip() throws {
        let report = HostnameActivationReport(
            hostname: "site.drupal", ip: "192.168.64.2", strategy: .hostsFile, hostsFileWriteRequired: true,
            warnings: ["w"])
        let responses: [ServiceResponse] = [
            .pong(info: ServiceInfo(pid: 42)), .ok, .started(hostnameActivation: report),
            .started(hostnameActivation: nil),
            .status(ContainerStatus(id: "a", state: .running, ipAddress: "1.2.3.4", imageReference: "img")),
            .hostnameActivation(report), .failure(ServiceFailure(kind: .containerFailedToStart, message: "boom")),
            .streamOpened,
            .logLine(LogLine(timestamp: Date(timeIntervalSince1970: 1_700_000_000.123), stream: .stderr, message: "hi")),
            .output(stream: .stdout, data: Data([0, 1, 2, 255])), .exited(ExecResult(exitCode: 3)), .streamEnded,
        ]
        let inputs: [ServiceStreamInput] = [.stdin(data: Data("abc".utf8)), .stdinClosed]

        var bytes = Data()
        for response in responses { bytes.append(try ServiceFraming.encode(response)) }
        for input in inputs { bytes.append(try ServiceFraming.encode(input)) }

        var decoder = ServiceFrameDecoder()
        decoder.append(bytes)
        for response in responses { #expect(try decoder.next(ServiceResponse.self) == response) }
        for input in inputs { #expect(try decoder.next(ServiceStreamInput.self) == input) }
        #expect(try decoder.nextPayload() == nil)
    }

    @Test func framesReassembleFromSingleByteChunks() throws {
        var bytes = Data()
        for request in Self.allRequests { bytes.append(try ServiceFraming.encode(request)) }
        var decoder = ServiceFrameDecoder()
        var decoded: [ServiceRequest] = []
        for byte in bytes {
            decoder.append(Data([byte]))
            if let request = try decoder.next(ServiceRequest.self) { decoded.append(request) }
        }
        #expect(decoded == Self.allRequests)
    }

    @Test func oversizedFrameHeaderIsRejected() {
        var decoder = ServiceFrameDecoder()
        decoder.append(Data([0xFF, 0xFF, 0xFF, 0xFF]))
        #expect(throws: ServiceFailure.self) { _ = try decoder.nextPayload() }
    }

    @Test func failuresMapBackToTypedErrors() {
        #expect(ServiceFailure(DrupalError.healthCheckTimeout("t")).error as? DrupalError == .healthCheckTimeout("t"))
        #expect(ServiceFailure(HostnameError.invalidIPAddress("x")).error as? HostnameError == .invalidIPAddress("x"))
        #expect((ServiceFailure(CancellationError()).error as? ServiceFailure)?.kind == .other)
    }
}

// MARK: - Client <-> server conformance over a real socket

@Suite struct ServiceSocketConformanceTests {
    @Test func socketIsOwnerOnly() throws {
        let fixture = try ServiceFixture()
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.socketPath)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(attributes[.type] as? FileAttributeType == .typeSocket)
    }

    @Test func lifecycleCallsReachTheServiceContainerService() async throws {
        let fixture = try ServiceFixture()
        let client = fixture.client()

        #expect(try await client.ping().protocolVersion == ServiceProtocol.version)
        try await client.pullImage("docker.io/ddev/ddev-dbserver:v1")
        try await client.create(dbSpec())
        #expect(try await client.inspect(id: "site-db").state == .created)
        try await client.start(id: "site-db")
        let running = try await client.inspect(id: "site-db")
        #expect(running.state == .running)
        #expect(running.ipAddress != nil)
        #expect(running.imageReference == dbSpec().imageReference)
        try await client.stop(id: "site-db")
        try await client.delete(id: "site-db")
        #expect(try await client.inspect(id: "missing") == .notFound("missing"))

        #expect(await fixture.mock.pulledImages == ["docker.io/ddev/ddev-dbserver:v1"])
        #expect(await fixture.mock.specs.isEmpty)
        #expect(await fixture.mock.calls.contains(.create("site-db")))
    }

    @Test func createSendsTheFullSpec() async throws {
        let fixture = try ServiceFixture()
        try await fixture.client().create(webSpec())
        #expect(await fixture.mock.specs["site-web"] == webSpec())
    }

    @Test func serviceErrorsArriveAsTheSameDrupalError() async throws {
        let fixture = try ServiceFixture()
        await fixture.mock.failNext(.start, with: .containerFailedToStart("no kernel"))
        try await fixture.client().create(dbSpec())
        await #expect(throws: DrupalError.containerFailedToStart("no kernel")) {
            try await fixture.client().start(id: "site-db")
        }
        await #expect(throws: DrupalError.containerFailedToStart("unknown container nope")) {
            try await fixture.client().start(id: "nope")
        }
        await fixture.mock.failNext(.logs, with: .platformUnavailable("x"))
        await #expect(throws: DrupalError.platformUnavailable("x")) {
            _ = try await fixture.client().logs(id: "site-db", follow: false)
        }
    }

    @Test func startingWebContainerActivatesItsHostnameInTheService() async throws {
        let fixture = try ServiceFixture()
        let client = fixture.client()
        try await client.create(webSpec())
        try await client.create(dbSpec())
        _ = try await client.startContainer(id: "site-db")
        let outcome = try await client.startContainer(id: "site-web")

        let ip = try #require(try await client.inspect(id: "site-web").ipAddress)
        #expect(outcome.hostnameActivation?.hostname == "site.drupal")
        #expect(outcome.hostnameActivation?.ip == ip)
        #expect(outcome.hostnameActivation?.strategy == .localResolver)
        #expect(outcome.warnings.isEmpty)
        // Only the web container's IP is registered.
        #expect(fixture.hostnames.log.events == ["activate:site.drupal=\(ip)"])

        try await client.stop(id: "site-web")
        #expect(fixture.hostnames.log.events.last == "deactivate:site.drupal")
    }

    @Test func resolverFailureMakesTheCLIWriteTheHostsFile() async throws {
        let fixture = try ServiceFixture(hostnames: RecordingHostnames(requireHostsFile: true))
        let hostsDirectory = FileManager.default.temporaryDirectory.appending(path: "sd-hosts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: hostsDirectory) }
        let hostsPath = hostsDirectory.appending(path: "hosts").path
        let client = fixture.client(hostsFallback: HostsFileStrategy(path: hostsPath, writer: DirectFileWriter()))

        try await client.create(webSpec())
        let outcome = try await client.startContainer(id: "site-web")
        let ip = try #require(outcome.hostnameActivation?.ip)

        #expect(outcome.hostnameActivation?.hostsFileWriteRequired == true)
        #expect(outcome.warnings.count == 1)
        #expect(outcome.warnings[0].contains("hosts-file"))
        #expect(try String(contentsOfFile: hostsPath, encoding: .utf8) == "\(ip)\tsite.drupal\t# managed-by: drupal\n")

        try await client.deactivateHostname(hostname: "site.drupal")
        #expect(try String(contentsOfFile: hostsPath, encoding: .utf8) == "")
    }

    @Test func liveControllerDefersHostsFileToTheClient() async throws {
        let responder = LocalDNSServer(handler: DNSQueryHandler(store: DNSRecordStore()), port: 0)
        defer { responder.stop() }
        let writer = MemoryWriter()
        let strategy = LocalResolverStrategy(
            server: responder, registrar: ResolverFileRegistrar(path: "/nonexistent-sd/resolver", writer: writer))
        let failing = ResolverHostnameController(strategy: strategy, verifier: FixedVerifier(result: false))
        let report = try await failing.activate(hostname: "a.drupal", ip: "10.0.0.5")
        #expect(report.hostsFileWriteRequired)
        #expect(report.strategy == .hostsFile)
        #expect(strategy.currentAddress(for: "a.drupal") == nil)

        let working = ResolverHostnameController(strategy: strategy, verifier: FixedVerifier(result: true))
        let ok = try await working.activate(hostname: "a.drupal", ip: "10.0.0.6")
        #expect(!ok.hostsFileWriteRequired)
        #expect(strategy.currentAddress(for: "a.drupal")?.description == "10.0.0.6")
        working.shutdown()
        #expect(!responder.isRunning)
    }

    @Test func serviceProcessCannotPerformPrivilegedWrites() {
        let registrar = ResolverFileRegistrar(path: "/nonexistent-sd/resolver", writer: ReadOnlyPrivilegedFileWriter())
        #expect(throws: HostnameError.self) { try registrar.register(port: 1053) }
    }

    @Test func secondServerOnSameSocketIsRejectedAndStaleSocketIsReplaced() throws {
        let directory = try ShortTempDirectory()
        let host = ServiceHost(containers: MockContainerService(), hostnames: RecordingHostnames())
        let first = ServiceServer(socketPath: directory.socketPath, host: host)
        try first.start()
        #expect(throws: UnixSocketError.addressInUse(directory.socketPath)) {
            try ServiceServer(socketPath: directory.socketPath, host: host).start()
        }
        first.stop()
        #expect(!FileManager.default.fileExists(atPath: directory.socketPath))

        // A stale node (no listener) is replaced.
        let staleFD = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = try UnixSocket.makeAddress(directory.socketPath)
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(staleFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        close(staleFD)
        #expect(FileManager.default.fileExists(atPath: directory.socketPath))
        let second = ServiceServer(socketPath: directory.socketPath, host: host)
        try second.start()
        second.stop()
    }

    @Test func overlongSocketPathIsRejected() {
        let path = "/tmp/" + String(repeating: "x", count: 120)
        #expect(throws: UnixSocketError.pathTooLong(path)) { _ = try UnixSocket.connect(path: path) }
    }
}

private struct FixedVerifier: HostnameResolverVerifier {
    let result: Bool
    func verify(hostname: String, expectedIP: String) async -> Bool { result }
}

// MARK: - Streaming order

@Suite struct ServiceStreamingOrderTests {
    @Test func logLinesArriveInOrder() async throws {
        let fixture = try ServiceFixture()
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let lines = (0..<2_000).map {
            LogLine(timestamp: base.addingTimeInterval(Double($0)), stream: $0 % 3 == 0 ? .stderr : .stdout, message: "line \($0)")
        }
        await fixture.mock.setLogLines("site-web", lines)

        var received: [LogLine] = []
        for try await line in try await fixture.client().logs(id: "site-web", follow: false) {
            received.append(line)
        }
        #expect(received == lines)
    }

    @Test func followStreamDeliversLiveLinesAndCancelsCleanly() async throws {
        let buffer = LogBuffer()
        let host = ServiceHost(containers: BufferLogsContainers(buffer: buffer), hostnames: RecordingHostnames())
        let directory = try ShortTempDirectory()
        let server = ServiceServer(socketPath: directory.socketPath, host: host)
        try server.start()
        defer { server.stop() }

        buffer.append(Data("backlog\n".utf8), stream: .stdout)
        let stream = try await ServiceClientContainerService(socketPath: directory.socketPath, hostsFallback: nil)
            .logs(id: "any", follow: true)
        var iterator = stream.makeAsyncIterator()
        #expect(try await iterator.next()?.message == "backlog")
        for index in 0..<50 { buffer.append(Data("live \(index)\n".utf8), stream: .stdout) }
        for index in 0..<50 { #expect(try await iterator.next()?.message == "live \(index)") }
        buffer.finish()
        #expect(try await iterator.next() == nil)
    }

    @Test func execOutputAndStdinAreOrdered() async throws {
        let fixture = try ServiceFixture()
        await fixture.mock.setExecHandler { _, request in
            // Echo stdin back as stdout, interleaved with numbered stderr chunks.
            var index = 0
            if let stdin = request.stdin {
                for await chunk in stdin {
                    request.output?(.stdout, chunk)
                    request.output?(.stderr, Data("e\(index)".utf8))
                    index += 1
                }
            }
            return ExecResult(exitCode: Int32(index))
        }

        let (stdin, feed) = AsyncStream<Data>.makeStream()
        let chunks = Mutex<[(StdioStream, String)]>([])
        let request = ExecRequest(
            arguments: ["cat"], stdin: stdin,
            output: { stream, data in chunks.withLock { $0.append((stream, String(decoding: data, as: UTF8.self))) } })

        let client = fixture.client()
        async let result = client.exec(id: "site-web", request)
        for index in 0..<100 { feed.yield(Data("o\(index)".utf8)) }
        feed.finish()

        #expect(try await result.exitCode == 100)
        let received = chunks.withLock { $0 }
        let expected = (0..<100).flatMap { [(StdioStream.stdout, "o\($0)"), (StdioStream.stderr, "e\($0)")] }
        #expect(received.map(\.0) == expected.map(\.0))
        #expect(received.map(\.1) == expected.map(\.1))
        #expect(await fixture.mock.execRequests.first?.arguments == ["cat"])
    }

    @Test func execFailureIsRethrown() async throws {
        let fixture = try ServiceFixture()
        await fixture.mock.failNext(.exec, with: .containerFailedToStart("not running"))
        await #expect(throws: DrupalError.containerFailedToStart("not running")) {
            _ = try await fixture.client().exec(id: "x", ExecRequest(arguments: ["true"]))
        }
    }
}

/// Serves `logs` from a real `LogBuffer` so follow mode can be exercised.
private struct BufferLogsContainers: ContainerService {
    let buffer: LogBuffer
    func pullImage(_ reference: String) async throws {}
    func create(_ spec: ContainerSpec) async throws {}
    func start(id: String) async throws {}
    func stop(id: String) async throws {}
    func delete(id: String) async throws {}
    func inspect(id: String) async throws -> ContainerStatus { .notFound(id) }
    func exec(id: String, _ request: ExecRequest) async throws -> ExecResult { ExecResult(exitCode: 0) }
    func logs(id: String, follow: Bool) async throws -> AsyncThrowingStream<LogLine, any Error> {
        buffer.stream(follow: follow)
    }
}

// MARK: - Shutdown ordering

@Suite struct ServiceShutdownTests {
    @Test func terminationStopsContainersBeforeResponder() async throws {
        let directory = try ShortTempDirectory()
        let log = EventLog()
        let mock = MockContainerService()
        let host = ServiceHost(
            containers: EventRecordingContainers(inner: mock, log: log), hostnames: RecordingHostnames(log: log))
        let server = ServiceServer(socketPath: directory.socketPath, host: host)
        let (trigger, fire) = AsyncStream<Void>.makeStream()

        let running = Task {
            try await ServiceRunner(server: server).run {
                for await _ in trigger { return }
            }
        }
        while !server.isListening { try await Task.sleep(for: .milliseconds(5)) }

        let client = ServiceClientContainerService(socketPath: directory.socketPath, hostsFallback: nil)
        try await client.create(webSpec())
        try await client.create(dbSpec())
        try await client.start(id: "site-db")
        _ = try await client.startContainer(id: "site-web")

        fire.yield()
        try await running.value

        let events = log.events.filter { !$0.hasPrefix("activate") }
        #expect(events == ["container-stopped:site-db", "container-stopped:site-web", "responder-stopped"]
            || events == ["container-stopped:site-web", "container-stopped:site-db", "responder-stopped"])
        #expect(events.last == "responder-stopped")
        #expect(try await mock.inspect(id: "site-web").state == .stopped)
        #expect(try await mock.inspect(id: "site-db").state == .stopped)
        // The socket is gone, so clients now get serviceUnavailable.
        #expect(!FileManager.default.fileExists(atPath: directory.socketPath))
        await #expect(throws: DrupalError.self) { _ = try await client.ping() }
    }

    @Test func realSignalTriggersOrderedShutdown() async throws {
        // SIGUSR2 stands in for SIGTERM so the test process is never at risk.
        Darwin.signal(SIGUSR2, SIG_IGN)
        let directory = try ShortTempDirectory()
        let log = EventLog()
        let mock = MockContainerService()
        let host = ServiceHost(
            containers: EventRecordingContainers(inner: mock, log: log), hostnames: RecordingHostnames(log: log))
        let server = ServiceServer(socketPath: directory.socketPath, host: host)
        let received = Mutex<Int32?>(nil)

        let running = Task {
            try await ServiceRunner(server: server).run {
                let signal = await TerminationSignal.wait(signals: [SIGUSR2])
                received.withLock { $0 = signal }
            }
        }
        while !server.isListening { try await Task.sleep(for: .milliseconds(5)) }
        try await ServiceClientContainerService(socketPath: directory.socketPath, hostsFallback: nil).create(dbSpec())

        let signaller = Task {
            while !Task.isCancelled {
                kill(getpid(), SIGUSR2)
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        try await running.value
        signaller.cancel()

        #expect(received.withLock { $0 } == SIGUSR2)
        #expect(log.events == ["container-stopped:site-db", "responder-stopped"])
    }

    @Test func containerStopFailureStillStopsResponder() async throws {
        let log = EventLog()
        let mock = MockContainerService()
        let host = ServiceHost(containers: mock, hostnames: RecordingHostnames(log: log))
        _ = await host.respond(to: .create(spec: dbSpec()))
        await mock.failNext(.stop, with: .containerFailedToStart("stuck"))
        await host.shutdown()
        #expect(log.events == ["responder-stopped"])
        #expect(await host.respond(to: .inspect(id: "site-db")) == .failure(
            ServiceFailure(kind: .serviceUnavailable, message: "the drupal service is shutting down")))
    }
}

// MARK: - serviceUnavailable

@Suite struct ServiceUnavailableTests {
    @Test func missingSocketFailsFastWithServiceUnavailable() async throws {
        let directory = try ShortTempDirectory()
        let client = ServiceClientContainerService(socketPath: directory.socketPath, hostsFallback: nil)

        let operations: [@Sendable () async throws -> Void] = [
            { _ = try await client.ping() },
            { try await client.pullImage("x") },
            { try await client.create(webSpec()) },
            { try await client.start(id: "a") },
            { try await client.stop(id: "a") },
            { try await client.delete(id: "a") },
            { _ = try await client.inspect(id: "a") },
            { _ = try await client.exec(id: "a", ExecRequest(arguments: ["true"])) },
            { _ = try await client.logs(id: "a", follow: true) },
            { _ = try await client.activateHostname(hostname: "a.drupal", ip: "10.0.0.1") },
        ]
        for operation in operations {
            do {
                try await operation()
                Issue.record("expected serviceUnavailable")
            } catch let error as DrupalError {
                guard case .serviceUnavailable(let message) = error else {
                    Issue.record("wrong error \(error)")
                    continue
                }
                #expect(message.contains("drupal service install"))
                #expect(error.exitCode == .serviceUnavailable)
                #expect(Drupal.exitStatus(for: error) == 14)
            }
        }
    }

    @Test func serviceUnavailableRendersJSONErrorNamingTheRemedy() throws {
        let error = DrupalError.serviceUnavailable("cannot reach the drupal service")
        let json = Drupal.errorOutput(for: error, format: .json)
        let report = try JSONDecoder().decode(ErrorReport.self, from: Data(json.utf8))
        #expect(report.error.code == "serviceUnavailable")
        #expect(report.error.exitCode == 14)
        #expect(report.error.remedy == "drupal service install")
        #expect(Drupal.errorOutput(for: error, format: .text).contains("drupal service install"))
        #expect(DrupalError.invalidConfig("x").remedy == nil)
    }

    @Test func exitCodeIsNextAfterHealthCheckTimeout() {
        #expect(SwiftDrupal.ExitCode.serviceUnavailable.rawValue == SwiftDrupal.ExitCode.healthCheckTimeout.rawValue + 1)
        #expect(SwiftDrupal.ExitCode.serviceUnavailable.argumentParserExitCode.rawValue == 14)
    }
}

// MARK: - LaunchAgent install / uninstall / status

private final class RecordingLaunchctl: LaunchctlRunner, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var invocations: [[String]] = []
    var statusFor: @Sendable ([String]) -> Int32 = { _ in 0 }

    func run(_ arguments: [String]) throws -> (status: Int32, output: String) {
        lock.withLock { invocations.append(arguments) }
        return (statusFor(arguments), "")
    }
}

@Suite struct LaunchAgentTests {
    @Test func plistMatchesGoldenFile() throws {
        let url = try #require(Bundle.module.url(forResource: "LaunchAgent.golden", withExtension: "plist", subdirectory: "Fixtures"))
        let golden = try String(contentsOf: url, encoding: .utf8)
        let rendered = LaunchAgentPlist.render(
            executablePath: "/usr/local/bin/drupal", logPath: "/Users/tester/Library/Logs/SwiftDrupal/service.log")
        #expect(rendered == golden)

        let parsed = try #require(
            try PropertyListSerialization.propertyList(from: Data(rendered.utf8), format: nil) as? [String: Any])
        #expect(parsed["Label"] as? String == ServicePaths.label)
        #expect(parsed["ProgramArguments"] as? [String] == ["/usr/local/bin/drupal", "service", "run"])
        #expect(parsed["RunAtLoad"] as? Bool == true)
        #expect(parsed["KeepAlive"] as? Bool == true)
    }

    @Test func plistEscapesXML() {
        let rendered = LaunchAgentPlist.render(executablePath: "/a&b/<drupal>", logPath: "/l")
        #expect(rendered.contains("<string>/a&amp;b/&lt;drupal&gt;</string>"))
    }

    @Test func pathsDeriveFromHome() {
        let paths = ServicePaths(home: URL(filePath: "/Users/tester", directoryHint: .isDirectory))
        #expect(paths.socketPath == "/Users/tester/Library/Application Support/SwiftDrupal/service.sock")
        #expect(paths.plistURL.path == "/Users/tester/Library/LaunchAgents/com.intrusive-memory.swiftdrupal.service.plist")
        #expect(ServicePaths.current(environment: ["SWIFTDRUPAL_SERVICE_SOCKET": "/tmp/x.sock"]).socketPath == "/tmp/x.sock")
    }

    @Test func installWritesPlistBootstrapsAndRegistersResolver() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "sd-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let launchctl = RecordingLaunchctl()
        let writer = MemoryWriter()
        let installer = ServiceInstaller(
            paths: ServicePaths(home: home), executablePath: "/opt/drupal/bin/drupal", uid: 501,
            launchctl: launchctl, registrar: ResolverFileRegistrar(path: "/test/resolver/drupal", writer: writer))

        let report = try installer.install()

        let plistPath = home.appending(path: "Library/LaunchAgents/com.intrusive-memory.swiftdrupal.service.plist").path
        #expect(report.plistPath == plistPath)
        #expect(try String(contentsOfFile: plistPath, encoding: .utf8).contains("<string>/opt/drupal/bin/drupal</string>"))
        #expect(launchctl.invocations == [
            ["bootout", "gui/501/com.intrusive-memory.swiftdrupal.service"],
            ["bootstrap", "gui/501", plistPath],
        ])
        #expect(report.resolverFileWritten)
        #expect(writer.readFile(atPath: "/test/resolver/drupal") == ResolverFileRegistrar.contents(port: 1053))
        #expect(report.warnings.isEmpty)

        // Reinstall: resolver already current, no second privileged write.
        #expect(try !installer.install().resolverFileWritten)
        #expect(writer.writes.count == 1)

        let uninstall = try installer.uninstall()
        #expect(uninstall.plistRemoved)
        #expect(uninstall.resolverFileRemoved)
        #expect(!FileManager.default.fileExists(atPath: plistPath))
        #expect(writer.readFile(atPath: "/test/resolver/drupal") == nil)
        #expect(launchctl.invocations.last == ["bootout", "gui/501/com.intrusive-memory.swiftdrupal.service"])
    }

    @Test func bootstrapFailureThrowsAndRelativeExecutableIsRejected() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "sd-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let launchctl = RecordingLaunchctl()
        launchctl.statusFor = { $0.first == "bootstrap" ? 5 : 0 }
        let writer = MemoryWriter()
        let installer = ServiceInstaller(
            paths: ServicePaths(home: home), executablePath: "/x/drupal", uid: 501, launchctl: launchctl,
            registrar: ResolverFileRegistrar(path: "/test/r", writer: writer))
        #expect(throws: ServiceInstallError.self) { _ = try installer.install() }
        #expect(writer.writes.isEmpty)

        var relative = installer
        relative.executablePath = "drupal"
        #expect(throws: ServiceInstallError.self) { _ = try relative.install() }
    }

    @Test func statusReportsEachLayer() async throws {
        let directory = try ShortTempDirectory()
        let home = FileManager.default.temporaryDirectory.appending(path: "sd-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let launchctl = RecordingLaunchctl()
        launchctl.statusFor = { _ in 113 }  // "Could not find service"
        let installer = ServiceInstaller(
            paths: ServicePaths(home: home, socketPathOverride: directory.socketPath), executablePath: "/x/drupal",
            uid: 501, launchctl: launchctl, registrar: ResolverFileRegistrar(path: "/test/r", writer: MemoryWriter()))

        let down = await installer.status()
        #expect(!down.plistInstalled && !down.agentLoaded && !down.socketReachable && !down.resolverRegistered)
        #expect(down.service == nil)
        #expect(launchctl.invocations == [["print", "gui/501/com.intrusive-memory.swiftdrupal.service"]])

        let server = ServiceServer(
            socketPath: directory.socketPath,
            host: ServiceHost(containers: MockContainerService(), hostnames: RecordingHostnames()))
        try server.start()
        defer { server.stop() }
        launchctl.statusFor = { _ in 0 }
        let up = await installer.status()
        #expect(up.agentLoaded && up.socketReachable)
        #expect(up.service?.pid == getpid())

        let json = try JSONEncoder().encode(up)
        let object = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        #expect(object["socketReachable"] as? Bool == true)
        #expect(object["label"] as? String == "com.intrusive-memory.swiftdrupal.service")
    }
}

// MARK: - Command registration

@Suite struct ServiceCommandRegistrationTests {
    @Test func serviceSubcommandsAreRegistered() throws {
        #expect(Drupal.configuration.subcommands.contains { $0 == ServiceCommand.self })
        #expect(try Drupal.parseAsRoot(["service", "run"]) is ServiceRunCommand)
        #expect(try Drupal.parseAsRoot(["service", "install", "--json"]) is ServiceInstallCommand)
        #expect(try Drupal.parseAsRoot(["service", "uninstall"]) is ServiceUninstallCommand)
        #expect(try Drupal.parseAsRoot(["service", "status", "--json"]) is ServiceStatusCommand)
    }

    @Test func runIsHiddenFromHelp() {
        #expect(ServiceRunCommand.configuration.shouldDisplay == false)
        let help = ServiceCommand.helpMessage()
        #expect(!help.contains("run "))
        #expect(help.contains("install"))
        #expect(help.contains("status"))
    }
}
