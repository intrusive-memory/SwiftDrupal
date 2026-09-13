import ArgumentParser
import Darwin
import Foundation
import Synchronization
import Testing
@testable import SwiftDrupal

@Suite struct SSHCommandTests {
    // MARK: - Registration and parsing

    @Test func sshIsRegisteredAndAcceptsAnOptionalService() throws {
        #expect(Drupal.configuration.subcommands.contains { $0 == SSHCommand.self })
        let noArgument = try #require(try Drupal.parseAsRoot(["ssh"]) as? SSHCommand)
        #expect(noArgument.service == nil)
        let withService = try #require(try Drupal.parseAsRoot(["ssh", "db"]) as? SSHCommand)
        #expect(withService.service == "db")
    }

    @Test func missingServiceDefaultsToWeb() throws {
        #expect(try ServiceTarget.role(for: nil) == .web)
        #expect(try ServiceTarget.role(for: "") == .web)
    }

    @Test func unknownServiceIsRejected() {
        #expect(throws: DrupalError.self) { _ = try ServiceTarget.role(for: "redis") }
    }

    @Test func loginShellCommandRunsAnInteractiveLoginShell() {
        #expect(SSHCommand.loginShellCommand.contains("-c"))
        #expect(SSHCommand.loginShellCommand.contains { $0.contains("-l") })
    }

    // MARK: - TTY passthrough

    @Test func rawModeEnabledAndRestoredForAnInteractiveSession() async throws {
        let mock = MockContainerService()
        await mock.setExecHandler { _, _ in ExecResult(exitCode: 0) }
        let terminal = RecordingTerminalController(isInteractiveTTY: true)
        let runner = ExecSessionRunner(
            containerService: mock, terminal: terminal, input: ScriptedInputSource(), output: RecordingExecOutputSink())

        // `ssh` always requests a pty (SSHCommand.run passes allocateTTY: true).
        _ = try await runner.run(id: "site-web", arguments: SSHCommand.loginShellCommand, allocateTTY: true)

        #expect(terminal.enableCallCount == 1)
        #expect(terminal.restoreCallCount == 1)
    }

    @Test func rawModeSkippedWhenNotAttachedToARealTerminal() async throws {
        // `drupal ssh < /dev/null | cat`: still requests a pty on the wire
        // (ssh always does), but there is no local terminal to put in raw
        // mode.
        let mock = MockContainerService()
        await mock.setExecHandler { _, _ in ExecResult(exitCode: 0) }
        let terminal = RecordingTerminalController(isInteractiveTTY: false)
        let runner = ExecSessionRunner(
            containerService: mock, terminal: terminal, input: ScriptedInputSource(), output: RecordingExecOutputSink())

        _ = try await runner.run(id: "site-web", arguments: SSHCommand.loginShellCommand, allocateTTY: true)

        #expect(terminal.enableCallCount == 0)
        #expect(terminal.restoreCallCount == 0)
    }

    @Test func rawModeRestoredWhenTheSessionEndsWithAnError() async throws {
        let mock = MockContainerService()
        await mock.failNext(.exec, with: .serviceUnavailable("cannot reach the drupal service"))
        let terminal = RecordingTerminalController(isInteractiveTTY: true)
        let runner = ExecSessionRunner(
            containerService: mock, terminal: terminal, input: ScriptedInputSource(), output: RecordingExecOutputSink())

        await #expect(throws: DrupalError.self) {
            _ = try await runner.run(id: "site-web", arguments: SSHCommand.loginShellCommand, allocateTTY: true)
        }
        #expect(terminal.enableCallCount == 1)
        #expect(terminal.restoreCallCount == 1)
    }

    /// `SSHCommand.run()` also installs an `InterruptGuard` so raw mode is
    /// restored even if the process is interrupted mid-session (not just on
    /// normal return/throw, which the runner's own `defer` already covers).
    /// SIGUSR1 stands in for SIGINT so the test process is never at risk.
    /// Deliberately not SIGUSR2: `ServiceShutdownTests` in ServiceTests.swift
    /// already uses SIGUSR2 as its own stand-in signal and, under Swift
    /// Testing's parallel execution, a `DispatchSourceSignal` fires for every
    /// active source watching a signal, not just the newest — sharing a
    /// signal number with that suite could cross-fire either test's handler.
    ///
    /// This sends exactly one real signal. `install`'s handler resets the
    /// disposition to `SIG_DFL` as part of its one-shot `cancel()`, and
    /// `SIG_DFL` for `SIGUSR1` terminates the process — so, unlike
    /// `ServiceShutdownTests`'s repeated-kill loop (whose signal is never
    /// cancelled back to `SIG_DFL`), this test must never signal itself a
    /// second time after that first delivery.
    @Test func interruptGuardRestoresTheTerminalOnSignal() async throws {
        Darwin.signal(SIGUSR1, SIG_IGN)
        let terminal = RecordingTerminalController(isInteractiveTTY: true)
        let exitedWith = Mutex<Int32?>(nil)
        let exited = AsyncStream<Void>.makeStream()

        let token = InterruptGuard.install(
            signal: SIGUSR1,
            cleanup: { terminal.restore() },
            exit: { code in
                exitedWith.withLock { $0 = code }
                exited.continuation.yield()
            })
        defer { token.cancel() }

        kill(getpid(), SIGUSR1)
        var iterator = exited.stream.makeAsyncIterator()
        _ = await iterator.next()

        #expect(terminal.restoreCallCount == 1)
        #expect(exitedWith.withLock { $0 } == 128 + SIGUSR1)
    }

    /// `cancel()` itself (no real signal involved) is idempotent. Uses
    /// SIGWINCH — distinct from SIGUSR1 above and SIGUSR2 in
    /// `ServiceShutdownTests` — so an active source here can't cross-fire
    /// with, or be cross-fired by, either of those; SIGWINCH's default
    /// disposition is also itself "ignore", so even a stray delivery
    /// wouldn't end the process.
    @Test func interruptGuardTokenCancelIsIdempotent() {
        let terminal = RecordingTerminalController(isInteractiveTTY: true)
        let token = InterruptGuard.install(
            signal: SIGWINCH, cleanup: { terminal.restore() }, exit: { _ in })
        token.cancel()
        token.cancel()
        token.cancel()
        // Cancelling never itself runs `cleanup()`.
        #expect(terminal.restoreCallCount == 0)
    }

    // MARK: - Exit-code propagation

    @Test(arguments: [0, 1, 130])
    func remoteShellExitCodePassesThroughUnchanged(code: Int32) async throws {
        let mock = MockContainerService()
        await mock.setExecHandler { _, _ in ExecResult(exitCode: code) }
        let runner = ExecSessionRunner(
            containerService: mock, terminal: RecordingTerminalController(isInteractiveTTY: true),
            input: ScriptedInputSource(), output: RecordingExecOutputSink())

        let result = try await runner.run(id: "site-web", arguments: SSHCommand.loginShellCommand, allocateTTY: true)
        #expect(result.exitCode == code)
    }

    @Test func defaultServiceResolvesToTheWebContainerID() throws {
        let projectRoot = try Self.makeProjectRoot(name: nil)
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        let role = try ServiceTarget.role(for: nil)
        #expect(try ServiceTarget.containerID(role: role, projectRoot: projectRoot).hasSuffix("-web"))
    }

    @Test func explicitDbServiceResolvesToTheDbContainerID() throws {
        let projectRoot = try Self.makeProjectRoot(name: "my-site")
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        let role = try ServiceTarget.role(for: "db")
        #expect(try ServiceTarget.containerID(role: role, projectRoot: projectRoot) == "my-site-db")
    }

    // MARK: - Stream handling

    @Test func interactiveOutputIsDeliveredInOrder() async throws {
        let mock = MockContainerService()
        await mock.setExecHandler { _, request in
            request.output?(.stdout, Data("$ ".utf8))
            request.output?(.stdout, Data("whoami\n".utf8))
            request.output?(.stdout, Data("www-data\n".utf8))
            return ExecResult(exitCode: 0)
        }
        let sink = RecordingExecOutputSink()
        let runner = ExecSessionRunner(
            containerService: mock, terminal: RecordingTerminalController(isInteractiveTTY: true), input: ScriptedInputSource(),
            output: sink)

        _ = try await runner.run(id: "site-web", arguments: SSHCommand.loginShellCommand, allocateTTY: true)
        #expect(sink.chunksAsStrings.map(\.1) == ["$ ", "whoami\n", "www-data\n"])
    }

    @Test func keystrokesAreForwardedAsStdin() async throws {
        let mock = MockContainerService()
        await mock.setExecHandler { _, request in
            var received = Data()
            if let stdin = request.stdin {
                for await chunk in stdin { received.append(chunk) }
            }
            request.output?(.stdout, received)
            return ExecResult(exitCode: 0)
        }
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        let sink = RecordingExecOutputSink()
        let runner = ExecSessionRunner(
            containerService: mock, terminal: RecordingTerminalController(isInteractiveTTY: true),
            input: SingleUseInputSource(stream: stream), output: sink)

        async let result = runner.run(id: "site-web", arguments: SSHCommand.loginShellCommand, allocateTTY: true)
        continuation.yield(Data("ls -la\r".utf8))
        continuation.finish()

        _ = try await result
        #expect(sink.chunksAsStrings.map(\.1) == ["ls -la\r"])
    }

    private static func makeProjectRoot(name: String?) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "SwiftDrupalTests-ssh-\(UUID().uuidString)", directoryHint: .isDirectory)
        var config = ProjectConfig.default
        config.name = name
        try config.write(projectRoot: root)
        return root
    }
}
