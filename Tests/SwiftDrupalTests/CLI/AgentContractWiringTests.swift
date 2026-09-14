import ArgumentParser
import Foundation
import Synchronization
import Testing
@testable import SwiftDrupal

// Command-level wiring tests (Sortie 7a audit) for the commands whose live
// dependencies were not previously injectable: exec, ssh, logs, import-db,
// export-db. Each runs through `Drupal.parseAsRoot` with a bound
// `LifecycleEnvironment`, a `MockContainerService`, and in-memory terminal and
// stdio doubles. No socket is opened except a connect to a path nobody listens
// on (the unreachable-service cases), and no signal is ever sent.

// MARK: - Doubles

/// Adapts `MockContainerService` to the service-client surface commands use.
private struct MockServiceClient: LifecycleServiceClient {
    let mock: MockContainerService

    func ping() async throws -> ServiceInfo {
        ServiceInfo(pid: 1)
    }
    func startContainer(id: String) async throws -> ServiceStartOutcome {
        try await mock.start(id: id)
        return ServiceStartOutcome(hostnameActivation: nil, warnings: [])
    }
    func deactivateHostname(hostname: String) async throws {}
    func pullImage(_ reference: String) async throws { try await mock.pullImage(reference) }
    func create(_ spec: ContainerSpec) async throws { try await mock.create(spec) }
    func start(id: String) async throws { try await mock.start(id: id) }
    func stop(id: String) async throws { try await mock.stop(id: id) }
    func delete(id: String) async throws { try await mock.delete(id: id) }
    func inspect(id: String) async throws -> ContainerStatus { try await mock.inspect(id: id) }
    func exec(id: String, _ request: ExecRequest) async throws -> ExecResult { try await mock.exec(id: id, request) }
    func logs(id: String, follow: Bool) async throws -> AsyncThrowingStream<LogLine, any Error> {
        try await mock.logs(id: id, follow: follow)
    }
}

private final class Lines: Sendable {
    private let storage = Mutex<[String]>([])
    func append(_ text: String) { storage.withLock { $0.append(text) } }
    var all: [String] { storage.withLock { $0 } }
    var last: String { all.last ?? "" }
}

private final class GuardRecorder: Sendable {
    private let state = Mutex((installed: 0, cancelled: 0))
    var installed: Int { state.withLock { $0.installed } }
    var cancelled: Int { state.withLock { $0.cancelled } }

    var installer: InterruptGuardInstaller {
        { [self] _, _ in
            state.withLock { $0.installed += 1 }
            return { [self] in state.withLock { $0.cancelled += 1 } }
        }
    }
}

private struct CommandResult {
    var status: Int32
    var error: (any Error)?
}

private final class WiringFixture: Sendable {
    let base: URL
    let projectRoot: URL
    let mock = MockContainerService()
    let stdout = Lines()
    let stderr = Lines()
    let guards = GuardRecorder()
    let execOutput = RecordingExecOutputSink()

    init(writeConfig: Bool = true) throws {
        base = FileManager.default.temporaryDirectory.appending(path: "sd-wiring-\(UUID().uuidString)", directoryHint: .isDirectory)
        projectRoot = base.appending(path: "site", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        if writeConfig { try ProjectConfig.default.write(projectRoot: projectRoot) }
    }

    deinit { try? FileManager.default.removeItem(at: base) }

    func environment(tty: Bool = false, terminalTTY: Bool = false, unreachable: Bool = false) -> LifecycleEnvironment {
        let mock = self.mock
        let stdout = self.stdout
        let stderr = self.stderr
        let root = projectRoot
        return LifecycleEnvironment(
            makeClient: { () -> any LifecycleServiceClient in
                if unreachable {
                    return ServiceClientContainerService(
                        socketPath: "/tmp/sd-none-\(UUID().uuidString.prefix(8)).sock", hostsFallback: nil)
                }
                return MockServiceClient(mock: mock)
            },
            hostsFile: HostsFileStrategy(writer: ReadOnlyPrivilegedFileWriter()),
            outputResolver: OutputFormatResolver { tty },
            writeOutput: { stdout.append($0) },
            currentDirectory: { root },
            stateRoot: base.appending(path: "state"),
            writeError: { stderr.append($0) },
            makeTerminal: { RecordingTerminalController(isInteractiveTTY: terminalTTY) },
            execInput: ScriptedInputSource(),
            execOutput: execOutput,
            installInterruptGuard: guards.installer
        )
    }

    func invoke(_ arguments: [String], environment: LifecycleEnvironment? = nil) async -> CommandResult {
        await LifecycleEnvironment.$current.withValue(environment ?? self.environment()) {
            do {
                var command = try Drupal.parseAsRoot(arguments)
                if var asyncCommand = command as? AsyncParsableCommand {
                    try await asyncCommand.run()
                } else {
                    try command.run()
                }
                return CommandResult(status: 0, error: nil)
            } catch {
                return CommandResult(status: Drupal.exitStatus(for: error), error: error)
            }
        }
    }
}

/// What `Drupal.main` would print on stderr for `result` in JSON mode, decoded.
private func jsonErrorReport(_ result: CommandResult) throws -> ErrorReport {
    let error = try #require(result.error)
    let rendered = try #require(Drupal.renderedError(for: error, format: .json))
    #expect(rendered.status == result.status)
    return try JSONDecoder().decode(ErrorReport.self, from: Data(rendered.text.utf8))
}

// MARK: - Error rendering in Drupal.main

@Suite struct ErrorRenderingWiringTests {
    struct Opaque: Error {}

    @Test func drupalErrorsRenderWithTheirCodeInBothFormats() throws {
        let json = try #require(Drupal.renderedError(for: DrupalError.serviceUnavailable("down"), format: .json))
        #expect(json.status == 14)
        let report = try JSONDecoder().decode(ErrorReport.self, from: Data(json.text.utf8))
        #expect(report.error.code == "serviceUnavailable")
        #expect(report.error.remedy == "drupal service install")

        let text = try #require(Drupal.renderedError(for: DrupalError.invalidConfig("bad"), format: .text))
        #expect(text.status == 10)
        #expect(text.text.hasPrefix("Error: Invalid config: bad"))
    }

    @Test func otherErrorsBecomeTheJSONEnvelopeInJSONMode() throws {
        let generic = try #require(Drupal.renderedError(for: Opaque(), format: .json))
        #expect(generic.status == 1)
        #expect(try JSONDecoder().decode(ErrorReport.self, from: Data(generic.text.utf8)).error.code == "failure")

        do {
            _ = try Drupal.parseAsRoot(["start", "--no-such-flag"])
            Issue.record("expected a parse error")
        } catch {
            let usage = try #require(Drupal.renderedError(for: error, format: .json))
            #expect(usage.status == 64)
            let report = try JSONDecoder().decode(ErrorReport.self, from: Data(usage.text.utf8))
            #expect(report.error.code == "usageError")
            #expect(report.error.exitCode == 64)
        }
    }

    @Test func argumentParserHandlingIsKeptForHelpPassthroughAndText() {
        #expect(Drupal.renderedError(for: CleanExit.helpRequest(), format: .json) == nil)
        #expect(Drupal.renderedError(for: ArgumentParser.ExitCode(7), format: .json) == nil)
        #expect(Drupal.renderedError(for: Opaque(), format: .text) == nil)
    }

    @Test func jsonFlagAfterTheTerminatorBelongsToTheRemoteCommand() {
        #expect(Drupal.jsonFlagPresent(in: ["status", "--json"]))
        #expect(Drupal.jsonFlagPresent(in: ["exec", "--json", "web", "--", "ls"]))
        #expect(!Drupal.jsonFlagPresent(in: ["exec", "web", "--", "tool", "--json"]))
    }
}

// MARK: - exec / ssh

@Suite struct ExecSSHWiringTests {
    @Test func execExitsWithTheRemoteStatusAndStreamsOutput() async throws {
        let fixture = try WiringFixture()
        await fixture.mock.setExecHandler { _, request in
            request.output?(.stdout, Data("hi\n".utf8))
            return ExecResult(exitCode: 7)
        }
        let result = await fixture.invoke(["exec", "web", "--", "drush", "status"])
        #expect(result.status == 7)
        #expect(await fixture.mock.calls.contains(.exec("site-web", ["drush", "status"])))
        #expect(fixture.execOutput.chunksAsStrings.map(\.1) == ["hi\n"])
        #expect(fixture.guards.installed == 1)
        #expect(fixture.guards.cancelled == 1)
    }

    @Test func execPseudoTerminalFollowsTheLocalTerminal() async throws {
        let fixture = try WiringFixture()
        let terminals = Mutex<[Bool]>([])
        await fixture.mock.setExecHandler { _, request in
            terminals.withLock { $0.append(request.terminal) }
            return ExecResult(exitCode: 0)
        }
        #expect(await fixture.invoke(["exec", "db", "--", "ls"], environment: fixture.environment(terminalTTY: false)).status == 0)
        #expect(await fixture.invoke(["exec", "db", "--", "ls"], environment: fixture.environment(terminalTTY: true)).status == 0)
        #expect(terminals.withLock { $0 } == [false, true])
    }

    @Test(arguments: [["exec", "web", "--", "ls"], ["ssh"], ["ssh", "db"]])
    func unreachableServiceExitsFourteenWithAJSONError(arguments: [String]) async throws {
        let fixture = try WiringFixture()
        let result = await fixture.invoke(arguments + ["--json"], environment: fixture.environment(unreachable: true))
        #expect(result.status == 14)
        #expect(try jsonErrorReport(result).error.code == "serviceUnavailable")
    }

    @Test(arguments: [["exec", "cache", "--", "ls"], ["ssh", "cache"]])
    func unknownServiceExitsTen(arguments: [String]) async throws {
        let fixture = try WiringFixture()
        let result = await fixture.invoke(arguments)
        #expect(result.status == 10)
        #expect(try jsonErrorReport(result).error.code == "invalidConfig")
        #expect(await fixture.mock.calls.isEmpty)
    }

    @Test func missingConfigExitsTen() async throws {
        let fixture = try WiringFixture(writeConfig: false)
        #expect(await fixture.invoke(["exec", "web", "--", "ls"]).status == 10)
        #expect(await fixture.invoke(["ssh"]).status == 10)
        #expect(await fixture.invoke(["logs"]).status == 10)
    }

    @Test func execWithoutACommandIsAUsageError() async throws {
        let fixture = try WiringFixture()
        let result = await fixture.invoke(["exec", "web", "--json"])
        #expect(result.status == 64)
        #expect(try jsonErrorReport(result).error.code == "usageError")
    }

    @Test func sshRunsTheLoginShellWithAPseudoTerminalAndPassesTheStatusThrough() async throws {
        let fixture = try WiringFixture()
        let terminal = Mutex<Bool?>(nil)
        await fixture.mock.setExecHandler { _, request in
            terminal.withLock { $0 = request.terminal }
            return ExecResult(exitCode: 3)
        }
        #expect(await fixture.invoke(["ssh"]).status == 3)
        #expect(await fixture.mock.calls.contains(.exec("site-web", SSHCommand.loginShellCommand)))
        #expect(terminal.withLock { $0 } == true)
        #expect(fixture.guards.cancelled == 1)
    }
}

// MARK: - logs

@Suite struct LogsWiringTests {
    static let lines = [
        LogLine(timestamp: Date(timeIntervalSince1970: 1_700_000_000), stream: .stdout, message: "first"),
        LogLine(timestamp: Date(timeIntervalSince1970: 1_700_000_001), stream: .stderr, message: "second"),
    ]

    @Test func nonTTYEmitsOneJSONObjectPerLine() async throws {
        let fixture = try WiringFixture()
        await fixture.mock.setLogLines("site-web", Self.lines)
        #expect(await fixture.invoke(["logs", "web"]).status == 0)
        let documents = try fixture.stdout.all.map {
            try JSONDecoder().decode(LogLineJSONDocument.self, from: Data($0.utf8))
        }
        #expect(documents.map(\.message) == ["first", "second"])
        #expect(documents.map(\.service) == ["web", "web"])
        #expect(documents.map(\.stream) == ["stdout", "stderr"])
        #expect(fixture.guards.installed == 0)
    }

    @Test func ttyEmitsTextUnlessJSONIsForced() async throws {
        let fixture = try WiringFixture()
        await fixture.mock.setLogLines("site-db", Self.lines)
        #expect(await fixture.invoke(["logs", "db"], environment: fixture.environment(tty: true)).status == 0)
        #expect(fixture.stdout.all.allSatisfy { $0.contains("[db]") })
        #expect(fixture.stdout.all.count == 2)

        #expect(await fixture.invoke(["logs", "db", "--json"], environment: fixture.environment(tty: true)).status == 0)
        #expect(throws: Never.self) {
            _ = try JSONDecoder().decode(LogLineJSONDocument.self, from: Data(fixture.stdout.last.utf8))
        }
    }

    @Test func bothContainersAreReadAndFollowInstallsTheInterruptGuard() async throws {
        let fixture = try WiringFixture()
        await fixture.mock.setLogLines("site-web", [Self.lines[0]])
        await fixture.mock.setLogLines("site-db", [Self.lines[1]])
        #expect(await fixture.invoke(["logs", "--follow"]).status == 0)
        #expect(Set(fixture.stdout.all.compactMap {
            try? JSONDecoder().decode(LogLineJSONDocument.self, from: Data($0.utf8)).service
        }) == ["web", "db"])
        let calls = await fixture.mock.calls
        #expect(calls.contains(.logs("site-web", follow: true)))
        #expect(calls.contains(.logs("site-db", follow: true)))
        #expect(fixture.guards.installed == 1)
        #expect(fixture.guards.cancelled == 1)
    }

    @Test func unreachableServiceExitsFourteen() async throws {
        let fixture = try WiringFixture()
        let result = await fixture.invoke(["logs", "--json"], environment: fixture.environment(unreachable: true))
        #expect(result.status == 14)
        #expect(try jsonErrorReport(result).error.code == "serviceUnavailable")
    }
}

// MARK: - import-db / export-db

@Suite struct DatabaseCommandWiringTests {
    @Test func importWritesTheJSONResultToStdout() async throws {
        let fixture = try WiringFixture()
        let dump = fixture.base.appending(path: "dump.sql")
        try Data("CREATE TABLE t (id int);\n".utf8).write(to: dump)
        #expect(await fixture.invoke(["import-db", dump.path]).status == 0)
        let result = try JSONDecoder().decode(DatabaseTransfer.Result.self, from: Data(fixture.stdout.last.utf8))
        #expect(result.operation == "import")
        #expect(result.containerID == "site-db")
        #expect(result.success)
        #expect(fixture.stderr.all.isEmpty)
    }

    @Test func importResolvesARelativeFileAgainstTheWorkingDirectory() async throws {
        let fixture = try WiringFixture()
        try Data("SELECT 1;\n".utf8).write(to: fixture.projectRoot.appending(path: "dump.sql"))
        #expect(await fixture.invoke(["import-db", "dump.sql"]).status == 0)
    }

    @Test func aFailingDatabaseClientExitsOneAfterReportingItsStatus() async throws {
        let fixture = try WiringFixture()
        let dump = fixture.base.appending(path: "dump.sql")
        try Data("garbage".utf8).write(to: dump)
        await fixture.mock.setExecHandler { _, _ in ExecResult(exitCode: 12) }
        #expect(await fixture.invoke(["import-db", dump.path]).status == 1)
        let result = try JSONDecoder().decode(DatabaseTransfer.Result.self, from: Data(fixture.stdout.last.utf8))
        #expect(result.exitStatus == 12)
        #expect(!result.success)
    }

    /// A 10-byte gzip header followed by a deflate block with the reserved type 3.
    static let corruptGzip = Data([0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0x07, 0x00])

    @Test func aCorruptGzipDumpExitsOneWithAJSONError() async throws {
        let fixture = try WiringFixture()
        let dump = fixture.base.appending(path: "dump.sql.gz")
        try Self.corruptGzip.write(to: dump)
        let result = await fixture.invoke(["import-db", dump.path, "--json"])
        #expect(result.status == 1)
        #expect(try jsonErrorReport(result).error.code == "failure")
    }

    @Test func aTruncatedGzipDumpExitsOneInsteadOfReportingSuccess() async throws {
        let fixture = try WiringFixture()
        let full = try gzipCompress(Data(String(repeating: "INSERT INTO t VALUES (1);\n", count: 200).utf8))
        let dump = fixture.base.appending(path: "dump.sql.gz")
        try full.prefix(full.count / 2).write(to: dump)
        let result = await fixture.invoke(["import-db", dump.path, "--json"])
        #expect(result.status == 1)
        #expect(try jsonErrorReport(result).error.message.contains("truncated"))
        #expect(fixture.stdout.all.isEmpty)
    }

    @Test func importOfAMissingFileExitsTen() async throws {
        let fixture = try WiringFixture()
        let result = await fixture.invoke(["import-db", "/nonexistent/dump.sql"])
        #expect(result.status == 10)
        #expect(try jsonErrorReport(result).error.code == "invalidConfig")
    }

    @Test func exportToAFileReportsOnStdout() async throws {
        let fixture = try WiringFixture()
        await fixture.mock.setExecHandler { _, request in
            request.output?(.stdout, Data("-- dump\n".utf8))
            return ExecResult(exitCode: 0)
        }
        let destination = fixture.base.appending(path: "out/dump.sql")
        #expect(await fixture.invoke(["export-db", destination.path]).status == 0)
        let result = try JSONDecoder().decode(DatabaseTransfer.Result.self, from: Data(fixture.stdout.last.utf8))
        #expect(result.bytesProcessed == 8)
        #expect(fixture.stderr.all.isEmpty)
    }

    @Test func exportToStdoutReportsOnStderr() async throws {
        let fixture = try WiringFixture()
        #expect(await fixture.invoke(["export-db"]).status == 0)
        #expect(fixture.stdout.all.isEmpty)
        let result = try JSONDecoder().decode(DatabaseTransfer.Result.self, from: Data(fixture.stderr.last.utf8))
        #expect(result.operation == "export")
        #expect(result.file == nil)
    }

    @Test(arguments: [["import-db", "DUMP"], ["export-db"]])
    func unreachableServiceExitsFourteen(arguments: [String]) async throws {
        let fixture = try WiringFixture()
        let dump = fixture.base.appending(path: "dump.sql")
        try Data("SELECT 1;".utf8).write(to: dump)
        let resolved = arguments.map { $0 == "DUMP" ? dump.path : $0 }
        let result = await fixture.invoke(resolved + ["--json"], environment: fixture.environment(unreachable: true))
        #expect(result.status == 14)
        #expect(try jsonErrorReport(result).error.code == "serviceUnavailable")
    }
}
