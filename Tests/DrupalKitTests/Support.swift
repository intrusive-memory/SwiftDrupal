import Foundation
import Synchronization
@testable import DrupalKit

// Test harness: runs the real command tree in-process against a temp
// directory with captured output and an injectable runtime/platform.

struct RunResult {
    var code: Int32
    var stdout: String
    var stderr: String

    /// The single JSON envelope on stdout (the last line for streaming commands).
    var envelope: [String: Any] {
        let line = stdout.split(separator: "\n").last.map(String.init) ?? ""
        return (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] ?? [:]
    }

    var data: [String: Any] { envelope["data"] as? [String: Any] ?? [:] }
    var error: [String: Any] { envelope["error"] as? [String: Any] ?? [:] }
}

func drupal(
    _ args: String...,
    in dir: URL,
    tty: Bool = false,
    runtime: any ContainerRuntime = UnimplementedRuntime(),
    platform: any PlatformChecking = PassingPlatform()
) async -> RunResult {
    await drupal(args, in: dir, tty: tty, runtime: runtime, platform: platform)
}

func drupal(
    _ args: [String],
    in dir: URL,
    tty: Bool = false,
    runtime: any ContainerRuntime = UnimplementedRuntime(),
    platform: any PlatformChecking = PassingPlatform()
) async -> RunResult {
    let out = CapturedOutput(), err = CapturedOutput()
    let env = CLIEnvironment(
        workingDirectory: dir, stdout: out, stderr: err,
        stdoutIsTTY: tty, stdinIsTTY: tty, runtime: runtime, platform: platform
    )
    let code = await DrupalCLI.run(args, environment: env)
    return RunResult(code: code, stdout: out.text, stderr: err.text)
}

/// A fresh directory `<unique>/<name>`, so project-name derivation is predictable.
func tempProject(_ name: String = "my-pantheon-site", config: String? = nil) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appending(path: "drupalkit-tests-\(UUID().uuidString)")
        .appending(path: name, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    if let config { try writeConfig(config, in: dir) }
    return dir
}

func writeConfig(_ text: String, in dir: URL) throws {
    let file = ProjectLayout.configFile(in: dir)
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: file, atomically: true, encoding: .utf8)
}

func readConfig(in dir: URL) throws -> String {
    try String(contentsOf: ProjectLayout.configFile(in: dir), encoding: .utf8)
}

struct PassingPlatform: PlatformChecking {
    func check() throws(DrupalError) {}
}

struct FailingPlatform: PlatformChecking {
    func check() throws(DrupalError) {
        throw DrupalError(.platformUnavailable, "test: unsupported host")
    }
}

/// Scripted runtime for exercising command logic past the runtime boundary.
final class FakeRuntime: ContainerRuntime {
    let execExitCode: Int32
    let logEntries: [LogEntry]
    private let calls = Mutex<[String]>([])

    init(execExitCode: Int32 = 0, logEntries: [LogEntry] = []) {
        self.execExitCode = execExitCode
        self.logEntries = logEntries
    }

    var recorded: [String] { calls.withLock { $0 } }
    private func record(_ s: String) { calls.withLock { $0.append(s) } }

    private func running(_ p: ResolvedProject) -> ProjectStatus {
        ProjectStatus(state: .running, services: [
            ServiceStatus(service: .web, state: .running, image: p.images.web, ipAddress: "192.168.64.2"),
            ServiceStatus(service: .db, state: .running, image: p.images.db, ipAddress: "192.168.64.3"),
        ])
    }

    func start(_ project: ResolvedProject, options: StartOptions) async throws(DrupalError) -> ProjectStatus {
        record("start")
        return running(project)
    }

    func stop(_ project: ResolvedProject) async throws(DrupalError) -> ProjectStatus {
        record("stop")
        return ProjectStatus(state: .stopped, services: [])
    }

    func status(_ project: ResolvedProject) async throws(DrupalError) -> ProjectStatus {
        record("status")
        return running(project)
    }

    func delete(_ project: ResolvedProject, keepData: Bool) async throws(DrupalError) {
        record("delete keepData=\(keepData)")
    }

    func exec(_ project: ResolvedProject, _ request: ExecRequest) async throws(DrupalError) -> ExecResult {
        record("exec \(request.service.rawValue) \(request.command.joined(separator: " "))")
        let captured = request.stdout == .capture
        return ExecResult(
            exitCode: execExitCode,
            stdout: captured ? Data("out\n".utf8) : nil,
            stderr: request.stderr == .capture ? Data("err\n".utf8) : nil
        )
    }

    func logs(_ project: ResolvedProject, _ request: LogRequest) -> AsyncThrowingStream<LogEntry, any Error> {
        let entries = logEntries.filter { request.services.contains($0.service) }
        return AsyncThrowingStream { c in
            for e in entries { c.yield(e) }
            c.finish()
        }
    }
}
