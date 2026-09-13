import ArgumentParser
import Foundation
import Synchronization
import Testing
@testable import SwiftDrupal

// MARK: - Doubles

/// Thread-safe capture of everything a command writes to stdout.
private final class OutputCapture: Sendable {
    private let storage = Mutex<[String]>([])
    func append(_ text: String) { storage.withLock { $0.append(text) } }
    var documents: [String] { storage.withLock { $0 } }
    var last: String { documents.last ?? "" }
    func reset() { storage.withLock { $0.removeAll() } }
}

/// In-memory privileged writer: `/etc/hosts` never touches disk.
private final class InMemoryHostsWriter: PrivilegedFileWriter, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: String] = [:]
    private(set) var writeCount = 0

    func readFile(atPath path: String) -> String? { lock.withLock { files[path] } }
    func writeFile(_ contents: String, atPath path: String) throws {
        lock.withLock {
            files[path] = contents
            writeCount += 1
        }
    }
    func removeFile(atPath path: String) throws { _ = lock.withLock { files.removeValue(forKey: path) } }
}

/// Service-side hostname controller that records calls.
private final class LifecycleTestHostnames: ServiceHostnameController, Sendable {
    let requireHostsFile: Bool
    private let events = Mutex<[String]>([])

    init(requireHostsFile: Bool = false) { self.requireHostsFile = requireHostsFile }

    var log: [String] { events.withLock { $0 } }

    func activate(hostname: String, ip: String) async throws -> HostnameActivationReport {
        events.withLock { $0.append("activate:\(hostname)=\(ip)") }
        return HostnameActivationReport(
            hostname: hostname, ip: ip, strategy: requireHostsFile ? .hostsFile : .localResolver,
            hostsFileWriteRequired: requireHostsFile,
            warnings: requireHostsFile ? ["Warning: resolver verification failed; using /etc/hosts for \(hostname)."] : [])
    }

    func deactivate(hostname: String) async { events.withLock { $0.append("deactivate:\(hostname)") } }
    func shutdown() {}
}

/// Drives a real `ServiceHost` in-process (no socket), mirroring
/// `ServiceClientContainerService`'s client-side hosts-file handling.
private struct InProcessServiceClient: LifecycleServiceClient {
    let host: ServiceHost
    let hostsFallback: (any HostnameStrategy)?

    private func call(_ request: ServiceRequest) async throws -> ServiceResponse {
        let response = await host.respond(to: request)
        if case .failure(let failure) = response { throw failure.error }
        return response
    }

    func ping() async throws -> ServiceInfo {
        guard case .pong(let info) = try await call(.ping) else { throw ServiceFailure(kind: .protocolError, message: "ping") }
        return info
    }

    func startContainer(id: String) async throws -> ServiceStartOutcome {
        guard case .started(let report) = try await call(.start(id: id)) else {
            throw ServiceFailure(kind: .protocolError, message: "start")
        }
        guard let report else { return ServiceStartOutcome(hostnameActivation: nil, warnings: []) }
        if report.hostsFileWriteRequired { try await hostsFallback?.activate(hostname: report.hostname, ip: report.ip) }
        return ServiceStartOutcome(hostnameActivation: report, warnings: report.warnings)
    }

    func deactivateHostname(hostname: String) async throws {
        _ = try await call(.deactivateHostname(hostname: hostname))
        try await hostsFallback?.deactivate(hostname: hostname)
    }

    func pullImage(_ reference: String) async throws { _ = try await call(.pullImage(reference: reference)) }
    func create(_ spec: ContainerSpec) async throws { _ = try await call(.create(spec: spec)) }
    func start(id: String) async throws { _ = try await startContainer(id: id) }
    func stop(id: String) async throws { _ = try await call(.stop(id: id)) }
    func delete(id: String) async throws { _ = try await call(.delete(id: id)) }
    func inspect(id: String) async throws -> ContainerStatus {
        guard case .status(let status) = try await call(.inspect(id: id)) else {
            throw ServiceFailure(kind: .protocolError, message: "inspect")
        }
        return status
    }
    func exec(id: String, _ request: ExecRequest) async throws -> ExecResult {
        try await host.containers.exec(id: id, request)
    }
    func logs(id: String, follow: Bool) async throws -> AsyncThrowingStream<LogLine, any Error> {
        try await host.containers.logs(id: id, follow: follow)
    }
}

/// A temp project (with config), temp state root, and a swappable in-process service.
private final class LifecycleFixture: Sendable {
    let base: URL
    let projectRoot: URL
    let stateRoot: URL
    let output = OutputCapture()
    let hostsWriter = InMemoryHostsWriter()
    let clientsMade = Counter()
    private let service: Mutex<(mock: MockContainerService, hostnames: LifecycleTestHostnames, host: ServiceHost)>
    let tty: Bool

    init(name: String = "site", requireHostsFile: Bool = false, writeConfig: Bool = true, tty: Bool = false) throws {
        base = FileManager.default.temporaryDirectory.appending(path: "sd-lifecycle-\(UUID().uuidString)", directoryHint: .isDirectory)
        projectRoot = base.appending(path: name, directoryHint: .isDirectory)
        stateRoot = base.appending(path: "state", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projectRoot.appending(path: "web"), withIntermediateDirectories: true)
        try Data("<?php".utf8).write(to: projectRoot.appending(path: "web/index.php"))
        if writeConfig { try ProjectConfig.default.write(projectRoot: projectRoot) }
        self.tty = tty
        let mock = MockContainerService()
        let hostnames = LifecycleTestHostnames(requireHostsFile: requireHostsFile)
        service = Mutex((mock, hostnames, ServiceHost(containers: mock, hostnames: hostnames)))
    }

    deinit { try? FileManager.default.removeItem(at: base) }

    var mock: MockContainerService { service.withLock { $0.mock } }
    var hostnames: LifecycleTestHostnames { service.withLock { $0.hostnames } }
    var hostsFile: HostsFileStrategy { HostsFileStrategy(writer: hostsWriter) }

    /// Simulates launchd restarting the service: every container and spec is forgotten.
    func restartService() {
        service.withLock { state in
            let mock = MockContainerService()
            state = (mock, state.hostnames, ServiceHost(containers: mock, hostnames: state.hostnames))
        }
    }

    func environment(client: (@Sendable () -> any LifecycleServiceClient)? = nil) -> LifecycleEnvironment {
        let clock = TestHealthCheckClock()
        let hostsFile = self.hostsFile
        let counter = clientsMade
        let makeClient: @Sendable () -> any LifecycleServiceClient =
            client ?? { [self] in
                InProcessServiceClient(host: service.withLock { $0.host }, hostsFallback: hostsFile)
            }
        let output = self.output
        let cwd = projectRoot
        let tty = self.tty
        return LifecycleEnvironment(
            makeClient: {
                counter.increment()
                return makeClient()
            },
            hostsFile: hostsFile,
            outputResolver: OutputFormatResolver { tty },
            writeOutput: { output.append($0) },
            currentDirectory: { cwd },
            stateRoot: stateRoot,
            healthChecker: HealthChecker(timeout: .seconds(5), pollInterval: .milliseconds(10), clock: clock),
            healthProbe: .ddevHealthcheck
        )
    }

    /// Parses `arguments` as the `drupal` binary would, runs the command in
    /// `environment`, and returns the process exit status.
    func invoke(_ arguments: [String], environment: LifecycleEnvironment? = nil) async -> Int32 {
        await LifecycleEnvironment.$current.withValue(environment ?? self.environment()) {
            do {
                var command = try Drupal.parseAsRoot(arguments)
                if var asyncCommand = command as? AsyncParsableCommand {
                    try await asyncCommand.run()
                } else {
                    try command.run()
                }
                return 0
            } catch {
                return Drupal.exitStatus(for: error)
            }
        }
    }

    func decodeLast<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: Data(output.last.utf8))
    }
}

/// A client pointed at a socket nobody listens on.
private func unreachableClient() -> ServiceClientContainerService {
    ServiceClientContainerService(socketPath: "/tmp/sd-none-\(UUID().uuidString.prefix(8)).sock", hostsFallback: nil)
}

// MARK: - Registration & output format

@Suite struct LifecycleCommandRegistrationTests {
    @Test func everyLifecycleSubcommandIsRegistered() throws {
        #expect(try Drupal.parseAsRoot(["init", "--json"]) is InitCommand)
        #expect(try Drupal.parseAsRoot(["start", "--json"]) is StartCommand)
        #expect(try Drupal.parseAsRoot(["stop", "--json"]) is StopCommand)
        #expect(try Drupal.parseAsRoot(["restart", "--json"]) is RestartCommand)
        #expect(try Drupal.parseAsRoot(["status", "--json"]) is StatusCommand)
        #expect(try Drupal.parseAsRoot(["describe", "--json"]) is StatusCommand)
        #expect(try Drupal.parseAsRoot(["delete", "--json", "--keep-data"]) is DeleteCommand)
        #expect(try Drupal.parseAsRoot(["config", "--json"]) is ConfigCommand)
        #expect(try Drupal.parseAsRoot(["validate", "--json"]) is ValidateCommand)
        // The service subcommands from Sortie 8 are still there.
        #expect(try Drupal.parseAsRoot(["service", "status"]) is ServiceStatusCommand)
    }

    @Test func invalidTimeoutIsAUsageError() {
        #expect(throws: (any Error).self) { _ = try Drupal.parseAsRoot(["start", "--timeout", "0"]) }
    }

    @Test func jsonWhenFlaggedOrNotATTYTextOtherwise() async throws {
        let tty = try LifecycleFixture(tty: true)
        #expect(await tty.invoke(["config"]) == 0)
        #expect(throws: (any Error).self) { _ = try JSONSerialization.jsonObject(with: Data(tty.output.last.utf8)) }
        #expect(tty.output.last.contains("Project: site"))

        #expect(await tty.invoke(["config", "--json"]) == 0)
        #expect(try tty.decodeLast(ResolvedConfigReport.self).name == "site")

        let piped = try LifecycleFixture(tty: false)
        for command in [["config"], ["validate"], ["init"], ["start"], ["status"], ["stop"], ["restart"], ["delete"]] {
            #expect(await piped.invoke(command) == 0, "\(command)")
            #expect(throws: Never.self, "\(command) should emit JSON") {
                _ = try JSONSerialization.jsonObject(with: Data(piped.output.last.utf8))
            }
        }
    }
}

// MARK: - start / stop idempotency

@Suite struct LifecycleStartStopTests {
    @Test func startCreatesDatabaseThenWebAndActivatesHostname() async throws {
        let fixture = try LifecycleFixture()
        #expect(await fixture.invoke(["start", "--json"]) == 0)
        let report = try fixture.decodeLast(LifecycleReport.self)

        #expect(report.command == "start")
        #expect(report.state == .running)
        #expect(report.changed)
        #expect(report.hostname == "site.drupal")
        #expect(report.url == "http://site.drupal")
        #expect(report.containers.map(\.id) == ["site-db", "site-web"])
        #expect(report.containers.allSatisfy { $0.created && $0.healthy == true && $0.state == .running })
        #expect(report.hostnameActivation?.hostname == "site.drupal")
        #expect(report.hostnameActivation?.strategy == .localResolver)
        #expect(report.warnings.isEmpty)

        let calls = await fixture.mock.calls
        let lifecycle = calls.filter {
            switch $0 {
            case .pullImage, .create, .start: true
            default: false
            }
        }
        #expect(lifecycle.count == 6)
        #expect(lifecycle.first == .pullImage(report.containers[0].image))
        #expect(lifecycle[2] == .start("site-db"))
        #expect(lifecycle[5] == .start("site-web"))
        #expect(fixture.hostnames.log.contains { $0.hasPrefix("activate:site.drupal=") })
    }

    @Test func startOnAlreadyStartedProjectExitsZeroWithoutRecreating() async throws {
        let fixture = try LifecycleFixture()
        #expect(await fixture.invoke(["start", "--json"]) == 0)
        let callsAfterFirst = await fixture.mock.calls.count

        #expect(await fixture.invoke(["start", "--json"]) == 0)
        let second = try fixture.decodeLast(LifecycleReport.self)
        #expect(second.state == .running)
        #expect(!second.changed)
        #expect(second.containers.allSatisfy { !$0.created && $0.wasRunning && !$0.changed })
        // The hostname is refreshed on every start.
        #expect(second.hostnameActivation != nil)

        let newCalls = await fixture.mock.calls.dropFirst(callsAfterFirst)
        #expect(!newCalls.contains { if case .create = $0 { true } else { false } })
        #expect(!newCalls.contains { if case .pullImage = $0 { true } else { false } })
    }

    @Test func stopOnAlreadyStoppedProjectExitsZero() async throws {
        let fixture = try LifecycleFixture()
        // Never started: nothing exists in the service.
        #expect(await fixture.invoke(["stop", "--json"]) == 0)
        #expect(try !fixture.decodeLast(LifecycleReport.self).changed)

        #expect(await fixture.invoke(["start", "--json"]) == 0)
        #expect(await fixture.invoke(["stop", "--json"]) == 0)
        let first = try fixture.decodeLast(LifecycleReport.self)
        #expect(first.changed)
        #expect(first.state == .stopped)
        #expect(first.containers.map(\.id) == ["site-web", "site-db"])
        #expect(first.containers.allSatisfy { $0.state == .stopped && $0.wasRunning })

        #expect(await fixture.invoke(["stop", "--json"]) == 0)
        let second = try fixture.decodeLast(LifecycleReport.self)
        #expect(!second.changed)
        #expect(second.state == .stopped)
        let stops = await fixture.mock.calls.filter { if case .stop = $0 { true } else { false } }
        #expect(stops.count == 2)
    }

    @Test func startAfterServiceRestartRecreatesContainers() async throws {
        let fixture = try LifecycleFixture()
        #expect(await fixture.invoke(["start"]) == 0)
        fixture.restartService()

        #expect(await fixture.invoke(["status"]) == 0)
        let status = try fixture.decodeLast(StatusReport.self)
        #expect(status.state == .stopped)
        #expect(status.containers.allSatisfy { $0.state == .notFound })

        #expect(await fixture.invoke(["start"]) == 0)
        let report = try fixture.decodeLast(LifecycleReport.self)
        #expect(report.state == .running)
        #expect(report.containers.allSatisfy { $0.created })
        #expect(report.hostnameActivation != nil)
    }

    @Test func startAfterStopRestartsExistingContainers() async throws {
        let fixture = try LifecycleFixture()
        #expect(await fixture.invoke(["start"]) == 0)
        #expect(await fixture.invoke(["stop"]) == 0)
        #expect(await fixture.invoke(["start"]) == 0)
        let report = try fixture.decodeLast(LifecycleReport.self)
        #expect(report.changed)
        #expect(report.containers.allSatisfy { !$0.created && !$0.wasRunning && $0.state == .running })
    }

    @Test func imageChangeRecreatesTheContainer() async throws {
        let fixture = try LifecycleFixture()
        #expect(await fixture.invoke(["start"]) == 0)
        var config = ProjectConfig.default
        let other = DDEVImageCatalog.supportedMariaDBVersions.first { $0 != config.database.version }
        try #require(other != nil)
        config.database.version = other!
        let newImage = try DDEVImageCatalog.databaseImage(type: "mariadb", version: other!)
        let oldImage = try DDEVImageCatalog.databaseImage(type: "mariadb", version: ProjectConfig.default.database.version)
        try #require(newImage != oldImage)
        try config.write(projectRoot: fixture.projectRoot)

        #expect(await fixture.invoke(["start"]) == 0)
        let report = try fixture.decodeLast(LifecycleReport.self)
        #expect(report.containers[0].created)
        #expect(report.containers[0].image == newImage)
        #expect(report.warnings.contains { $0.contains("Recreated site-db") })
    }

    @Test func hostsFileFallbackWarningIsSurfacedAndStopRemovesTheLine() async throws {
        let fixture = try LifecycleFixture(requireHostsFile: true)
        #expect(await fixture.invoke(["start", "--json"]) == 0)
        let report = try fixture.decodeLast(LifecycleReport.self)
        #expect(report.hostnameActivation?.hostsFileWriteRequired == true)
        #expect(report.warnings.contains { $0.contains("/etc/hosts") })
        let ip = try #require(report.containers.first { $0.role == .web }?.ipAddress)
        #expect(fixture.hostsFile.currentAddress(for: "site.drupal")?.description == ip)

        #expect(await fixture.invoke(["status"]) == 0)
        #expect(try fixture.decodeLast(StatusReport.self).hostsFileAddress == ip)

        #expect(await fixture.invoke(["stop"]) == 0)
        #expect(fixture.hostsFile.currentAddress(for: "site.drupal") == nil)
        #expect(fixture.hostnames.log.contains("deactivate:site.drupal"))
    }

    @Test func healthTimeoutExitsThirteen() async throws {
        let fixture = try LifecycleFixture()
        await fixture.mock.setExecHandler { _, _ in ExecResult(exitCode: 1) }
        #expect(await fixture.invoke(["start", "--timeout", "1"]) == SwiftDrupal.ExitCode.healthCheckTimeout.rawValue)
    }

    @Test func noWaitSkipsHealthChecks() async throws {
        let fixture = try LifecycleFixture()
        await fixture.mock.setExecHandler { _, _ in ExecResult(exitCode: 1) }
        #expect(await fixture.invoke(["start", "--no-wait"]) == 0)
        #expect(try fixture.decodeLast(LifecycleReport.self).containers.allSatisfy { $0.healthy == nil })
    }

    @Test func restartStopsThenStarts() async throws {
        let fixture = try LifecycleFixture()
        #expect(await fixture.invoke(["start"]) == 0)
        #expect(await fixture.invoke(["restart", "--json"]) == 0)
        let report = try fixture.decodeLast(RestartReport.self)
        #expect(report.command == "restart")
        #expect(report.stop.changed)
        #expect(report.start.state == .running)
        #expect(report.start.containers.allSatisfy { !$0.wasRunning })
    }
}

// MARK: - status / delete

@Suite struct LifecycleStatusDeleteTests {
    @Test func statusReportsStatesHostnameServiceAndConfig() async throws {
        let fixture = try LifecycleFixture()
        #expect(await fixture.invoke(["describe", "--json"]) == 0)
        let before = try fixture.decodeLast(StatusReport.self)
        #expect(before.state == .stopped)
        #expect(before.webIPAddress == nil)

        #expect(await fixture.invoke(["start"]) == 0)
        #expect(await fixture.invoke(["status", "--json"]) == 0)
        let status = try fixture.decodeLast(StatusReport.self)
        #expect(status.project == "site")
        #expect(status.hostname == "site.drupal")
        #expect(status.state == .running)
        #expect(status.containers.map(\.role) == [.db, .web])
        #expect(status.webIPAddress != nil)
        #expect(status.service.protocolVersion == ServiceProtocol.version)
        #expect(status.config.config == ProjectConfig.default)
        #expect(status.hostsFileAddress == nil)
    }

    @Test func deleteRemovesContainersAndDataButNotSourceAndIsRepeatable() async throws {
        let fixture = try LifecycleFixture()
        #expect(await fixture.invoke(["start"]) == 0)
        let dataDirectory = DatabaseContainerSpecBuilder.dataDirectoryHostURL(stateRoot: fixture.stateRoot, projectName: "site")
        // The live service creates this on `create`; the mock does not.
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        try Data("ibdata".utf8).write(to: dataDirectory.appending(path: "ibdata1"))

        #expect(await fixture.invoke(["delete", "--json"]) == 0)
        let report = try fixture.decodeLast(LifecycleReport.self)
        #expect(report.changed)
        #expect(report.containers.allSatisfy { $0.state == .notFound && $0.changed })
        #expect(report.removedDataDirectories?.count == 1)
        #expect(!FileManager.default.fileExists(atPath: dataDirectory.path))
        #expect(FileManager.default.fileExists(atPath: fixture.projectRoot.appending(path: "web/index.php").path))
        #expect(FileManager.default.fileExists(atPath: ProjectConfig.configFileURL(projectRoot: fixture.projectRoot).path))
        #expect(try await fixture.mock.inspect(id: "site-web").state == .notFound)
        #expect(fixture.hostnames.log.contains("deactivate:site.drupal"))

        #expect(await fixture.invoke(["delete", "--json"]) == 0)
        #expect(try !fixture.decodeLast(LifecycleReport.self).changed)
    }

    @Test func deleteKeepDataLeavesTheDataDirectory() async throws {
        let fixture = try LifecycleFixture()
        #expect(await fixture.invoke(["start"]) == 0)
        let dataDirectory = DatabaseContainerSpecBuilder.dataDirectoryHostURL(stateRoot: fixture.stateRoot, projectName: "site")
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)

        #expect(await fixture.invoke(["delete", "--keep-data"]) == 0)
        #expect(try fixture.decodeLast(LifecycleReport.self).removedDataDirectories == [])
        #expect(FileManager.default.fileExists(atPath: dataDirectory.path))
    }

    @Test func deleteRemovesAHostsFallbackLine() async throws {
        let fixture = try LifecycleFixture(requireHostsFile: true)
        #expect(await fixture.invoke(["start"]) == 0)
        #expect(fixture.hostsFile.currentAddress(for: "site.drupal") != nil)
        #expect(await fixture.invoke(["delete"]) == 0)
        #expect(fixture.hostsFile.currentAddress(for: "site.drupal") == nil)
    }
}

// MARK: - Service unavailable, and commands that need no service

@Suite struct LifecycleServiceAvailabilityTests {
    @Test(arguments: [["start"], ["stop"], ["restart"], ["status"], ["describe"], ["delete"]])
    func serviceCommandsExitFourteenWhenUnreachable(arguments: [String]) async throws {
        let fixture = try LifecycleFixture()
        let environment = fixture.environment(client: { unreachableClient() })
        #expect(await fixture.invoke(arguments + ["--json"], environment: environment) == 14)
    }

    @Test func configCommandsNeverBuildAServiceClient() async throws {
        let fixture = try LifecycleFixture(writeConfig: false)
        let environment = fixture.environment(client: { unreachableClient() })
        #expect(await fixture.invoke(["init", "--json"], environment: environment) == 0)
        #expect(await fixture.invoke(["config", "--json"], environment: environment) == 0)
        #expect(await fixture.invoke(["validate", "--json"], environment: environment) == 0)
        #expect(fixture.clientsMade.value == 0)
    }

    @Test func missingConfigExitsTen() async throws {
        let fixture = try LifecycleFixture(writeConfig: false)
        for command in ["start", "stop", "status", "delete", "config", "validate"] {
            #expect(await fixture.invoke([command]) == 10, "\(command)")
        }
        #expect(fixture.clientsMade.value == 0)
    }
}

// MARK: - init / config / validate

@Suite struct LifecycleConfigCommandTests {
    @Test func initWritesDefaultsAndIsIdempotent() async throws {
        let fixture = try LifecycleFixture(writeConfig: false)
        #expect(await fixture.invoke(["init", "--json"]) == 0)
        let first = try fixture.decodeLast(InitReport.self)
        #expect(first.created && first.written)
        #expect(first.resolved.config == ProjectConfig.default)
        #expect(first.resolved.name == "site")
        #expect(first.resolved.nameSource == "directory")
        #expect(try ProjectConfig.load(projectRoot: fixture.projectRoot) == .default)

        #expect(await fixture.invoke(["init", "--json"]) == 0)
        let second = try fixture.decodeLast(InitReport.self)
        #expect(!second.created && !second.written)
    }

    @Test func initOptionsUpdateOnlyTheGivenFields() async throws {
        let fixture = try LifecycleFixture()
        #expect(
            await fixture.invoke([
                "init", "--name", "other", "--webserver-type", "apache-fpm", "--web-environment", "FOO=bar",
                "--web-environment", "BAZ=1",
            ]) == 0)
        let report = try fixture.decodeLast(InitReport.self)
        #expect(report.written && !report.created)
        #expect(report.resolved.name == "other")
        #expect(report.resolved.hostname == "other.drupal")
        #expect(report.resolved.nameSource == "config")
        let config = try ProjectConfig.load(projectRoot: fixture.projectRoot)
        #expect(config.webserverType == "apache-fpm")
        #expect(config.webEnvironment == ["FOO=bar", "BAZ=1"])
        #expect(config.phpVersion == ProjectConfig.default.phpVersion)
    }

    @Test func initRejectsInvalidValuesWithoutWriting() async throws {
        let fixture = try LifecycleFixture(writeConfig: false)
        #expect(await fixture.invoke(["init", "--php-version", "4.0"]) == 10)
        #expect(!FileManager.default.fileExists(atPath: ProjectConfig.configFileURL(projectRoot: fixture.projectRoot).path))
    }

    @Test func initReplacesAnUnreadableConfigOnlyWithForce() async throws {
        let fixture = try LifecycleFixture(writeConfig: false)
        let url = ProjectConfig.configFileURL(projectRoot: fixture.projectRoot)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("docroot: [".utf8).write(to: url)

        #expect(await fixture.invoke(["init"]) == 10)
        #expect(await fixture.invoke(["init", "--force"]) == 0)
        #expect(try ProjectConfig.load(from: url) == .default)
    }

    @Test func configPrintsTheResolvedPlanFromASubdirectory() async throws {
        let fixture = try LifecycleFixture()
        let subdirectory = fixture.projectRoot.appending(path: "web")
        var environment = fixture.environment()
        environment.currentDirectory = { subdirectory }
        #expect(await fixture.invoke(["config", "--json"], environment: environment) == 0)
        let report = try fixture.decodeLast(ResolvedConfigReport.self)
        #expect(report.projectRoot == fixture.projectRoot.standardizedFileURL.path(percentEncoded: false))
        #expect(report.docrootPath == "/var/www/html/web")
        #expect(report.config.webEnvironment == [])
        #expect(report.containers.map(\.id) == ["site-db", "site-web"])
    }

    @Test func validateExitsTenForAnInvalidConfig() async throws {
        let fixture = try LifecycleFixture()
        #expect(await fixture.invoke(["validate", "--json"]) == 0)
        #expect(try fixture.decodeLast(ValidateReport.self).valid)

        var config = ProjectConfig.default
        config.webserverType = "lighttpd"
        try config.write(projectRoot: fixture.projectRoot)
        #expect(await fixture.invoke(["validate", "--json"]) == 10)
        #expect(await fixture.invoke(["config", "--json"]) == 10)
    }
}

// MARK: - Over a real socket

@Suite struct LifecycleOverSocketTests {
    @Test func startAndDeleteThroughServiceClientContainerService() async throws {
        let directory = "/tmp/sd-\(UUID().uuidString.prefix(8).lowercased())"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let socketPath = directory + "/s.sock"

        let fixture = try LifecycleFixture(requireHostsFile: true)
        let server = ServiceServer(
            socketPath: socketPath, host: ServiceHost(containers: fixture.mock, hostnames: fixture.hostnames))
        try server.start()
        defer { server.stop() }

        let hostsFile = fixture.hostsFile
        let environment = fixture.environment(client: {
            ServiceClientContainerService(socketPath: socketPath, hostsFallback: hostsFile)
        })

        #expect(await fixture.invoke(["start", "--json"], environment: environment) == 0)
        let report = try fixture.decodeLast(LifecycleReport.self)
        #expect(report.state == .running)
        #expect(report.warnings.contains { $0.contains("/etc/hosts") })
        #expect(hostsFile.currentAddress(for: "site.drupal") != nil)

        #expect(await fixture.invoke(["start", "--json"], environment: environment) == 0)
        #expect(await fixture.invoke(["status", "--json"], environment: environment) == 0)
        #expect(try fixture.decodeLast(StatusReport.self).state == .running)

        #expect(await fixture.invoke(["delete", "--json"], environment: environment) == 0)
        #expect(hostsFile.currentAddress(for: "site.drupal") == nil)
        #expect(await fixture.invoke(["stop", "--json"], environment: environment) == 0)
    }
}

// MARK: - post_start

@Suite struct PostStartTests {
    /// Writes the default config with `commands` as `post_start`.
    private func writePostStart(_ commands: [String], to fixture: LifecycleFixture) throws {
        var config = ProjectConfig.default
        config.postStart = commands
        try config.write(projectRoot: fixture.projectRoot)
    }

    /// Scripts the mock: health checks pass; each `/bin/sh -c <command>` exits
    /// with `exitCodes[command]` (default 0) and prints its command.
    private func scriptExec(_ fixture: LifecycleFixture, exitCodes: [String: Int32] = [:]) async {
        await fixture.mock.setExecHandler { _, request in
            guard request.arguments.count == 3, request.arguments[0] == "/bin/sh" else { return ExecResult(exitCode: 0) }
            request.output?(.stdout, Data("ran \(request.arguments[2])\n".utf8))
            return ExecResult(exitCode: exitCodes[request.arguments[2]] ?? 0)
        }
    }

    private func postStartCalls(_ fixture: LifecycleFixture) async -> [MockContainerService.Call] {
        await fixture.mock.calls.filter {
            if case .exec(_, let arguments) = $0 { arguments.first == "/bin/sh" } else { false }
        }
    }

    @Test func runsEachCommandInOrderInTheWebContainerAfterStart() async throws {
        let fixture = try LifecycleFixture()
        try writePostStart(["composer install", "drush cr", "drush uli"], to: fixture)
        await scriptExec(fixture)

        #expect(await fixture.invoke(["start", "--json"]) == 0)
        let report = try fixture.decodeLast(LifecycleReport.self)
        let postStart = try #require(report.postStart)
        #expect(!postStart.failed)
        #expect(postStart.containerId == "site-web")
        #expect(postStart.commands.map(\.command) == ["composer install", "drush cr", "drush uli"])
        #expect(postStart.commands.map(\.index) == [0, 1, 2])
        #expect(postStart.commands.allSatisfy { $0.succeeded && $0.exitCode == 0 })
        #expect(postStart.commands[1].output == "ran drush cr\n")
        #expect(postStart.skipped.isEmpty)

        let calls = await fixture.mock.calls
        #expect(await postStartCalls(fixture) == [
            .exec("site-web", ["/bin/sh", "-c", "composer install"]),
            .exec("site-web", ["/bin/sh", "-c", "drush cr"]),
            .exec("site-web", ["/bin/sh", "-c", "drush uli"]),
        ])
        // Only after both containers were started.
        let firstPostStart = try #require(calls.firstIndex(of: .exec("site-web", ["/bin/sh", "-c", "composer install"])))
        let webStart = try #require(calls.firstIndex(of: .start("site-web")))
        #expect(webStart < firstPostStart)
    }

    @Test func stopsAtTheFirstFailureReportsItAndExitsTwelve() async throws {
        let fixture = try LifecycleFixture()
        try writePostStart(["first", "second", "third", "fourth"], to: fixture)
        await scriptExec(fixture, exitCodes: ["second": 2])

        #expect(await fixture.invoke(["start", "--json"]) == SwiftDrupal.ExitCode.containerFailedToStart.rawValue)
        let report = try fixture.decodeLast(LifecycleReport.self)
        let postStart = try #require(report.postStart)
        #expect(postStart.failed)
        #expect(postStart.commands.map(\.command) == ["first", "second"])
        #expect(postStart.commands.last?.exitCode == 2)
        #expect(postStart.commands.last?.succeeded == false)
        #expect(postStart.skipped == ["third", "fourth"])
        #expect(report.state == .running)
        #expect(await postStartCalls(fixture).count == 2)

        let error = try #require(report.postStartError)
        #expect(error.exitCode == .containerFailedToStart)
        #expect(error.message.contains("`second`"))
        #expect(error.message.contains("exited 2"))
    }

    @Test func restartAlsoRunsPostStartAndExitsTwelveOnFailure() async throws {
        let fixture = try LifecycleFixture()
        try writePostStart(["boom"], to: fixture)
        await scriptExec(fixture, exitCodes: ["boom": 1])
        #expect(await fixture.invoke(["restart", "--json"]) == 12)
        let report = try fixture.decodeLast(RestartReport.self)
        #expect(report.start.postStart?.failed == true)
    }

    @Test func runsOnEveryStartIncludingIdempotentRepeats() async throws {
        let fixture = try LifecycleFixture()
        try writePostStart(["drush cr"], to: fixture)
        await scriptExec(fixture)
        #expect(await fixture.invoke(["start"]) == 0)
        #expect(await fixture.invoke(["start"]) == 0)
        #expect(await postStartCalls(fixture).count == 2)
    }

    @Test func noPostStartMeansNoExtraExecAndNoReportKey() async throws {
        let fixture = try LifecycleFixture()
        await scriptExec(fixture)
        #expect(await fixture.invoke(["start", "--json"]) == 0)
        #expect(try fixture.decodeLast(LifecycleReport.self).postStart == nil)
        #expect(!fixture.output.last.contains("postStart"))
        #expect(await postStartCalls(fixture).isEmpty)
    }

    @Test func outputIsTruncatedToTheTail() async throws {
        let fixture = try LifecycleFixture()
        try writePostStart(["noisy"], to: fixture)
        let chunk = Data(repeating: UInt8(ascii: "a"), count: PostStartReport.outputLimit)
        await fixture.mock.setExecHandler { _, request in
            guard request.arguments.first == "/bin/sh" else { return ExecResult(exitCode: 0) }
            request.output?(.stdout, chunk)
            request.output?(.stderr, Data("tail".utf8))
            return ExecResult(exitCode: 0)
        }
        #expect(await fixture.invoke(["start"]) == 0)
        let result = try #require(try fixture.decodeLast(LifecycleReport.self).postStart?.commands.first)
        #expect(result.outputTruncated)
        #expect(result.output.utf8.count == PostStartReport.outputLimit)
        #expect(result.output.hasSuffix("tail"))
    }

    @Test func serviceLossDuringPostStartExitsFourteen() async throws {
        let fixture = try LifecycleFixture()
        try writePostStart(["drush cr"], to: fixture)
        await fixture.mock.setExecHandler { _, request in
            if request.arguments.first == "/bin/sh" { throw DrupalError.serviceUnavailable("gone") }
            return ExecResult(exitCode: 0)
        }
        #expect(await fixture.invoke(["start"]) == 14)
    }
}
