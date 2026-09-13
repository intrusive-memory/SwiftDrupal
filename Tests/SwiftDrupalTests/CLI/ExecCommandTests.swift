import ArgumentParser
import Foundation
import Synchronization
import Testing
@testable import SwiftDrupal

@Suite struct ExecCommandTests {
    // MARK: - Registration and parsing

    @Test func execIsRegisteredAndParsesServiceAndCommand() throws {
        #expect(Drupal.configuration.subcommands.contains { $0 == ExecCommand.self })
        let parsed = try #require(try Drupal.parseAsRoot(["exec", "web", "--", "drush", "cr"]) as? ExecCommand)
        #expect(parsed.service == "web")
        #expect(parsed.command == ["drush", "cr"])
    }

    @Test func commandArgumentsThatLookLikeFlagsSurviveTheTerminator() throws {
        let parsed = try ExecCommand.parse(["db", "--", "mysql", "--version"])
        #expect(parsed.service == "db")
        #expect(parsed.command == ["mysql", "--version"])
    }

    @Test func missingCommandFailsBeforeAnyIO() async throws {
        // No "--", so ArgumentParser leaves `command` empty; `run()` must
        // reject this before touching the (unreachable-in-tests) service
        // socket or a real terminal.
        var command = try ExecCommand.parse(["web"])
        #expect(command.command.isEmpty)
        await #expect(throws: ValidationError.self) {
            try await command.run()
        }
    }

    @Test func unknownServiceIsRejectedByServiceTarget() {
        #expect(throws: DrupalError.self) { _ = try ServiceTarget.role(for: "cache") }
        do {
            _ = try ServiceTarget.role(for: "cache")
            Issue.record("expected invalidConfig")
        } catch let error as DrupalError {
            #expect(error.exitCode == .invalidConfig)
        } catch {
            Issue.record("wrong error type \(error)")
        }
    }

    @Test func webAndDbServiceNamesResolveCaseInsensitively() throws {
        #expect(try ServiceTarget.role(for: "web") == .web)
        #expect(try ServiceTarget.role(for: "WEB") == .web)
        #expect(try ServiceTarget.role(for: "Db") == .db)
    }

    // MARK: - TTY passthrough

    @Test func rawModeEnabledAndRestoredWhenTTYRequestedAndTerminalIsInteractive() async throws {
        let mock = MockContainerService()
        await mock.setExecHandler { _, _ in ExecResult(exitCode: 0) }
        let terminal = RecordingTerminalController(isInteractiveTTY: true)
        let runner = ExecSessionRunner(
            containerService: mock, terminal: terminal, input: ScriptedInputSource(), output: RecordingExecOutputSink())

        _ = try await runner.run(id: "site-web", arguments: ["/bin/sh"], allocateTTY: true)

        #expect(terminal.enableCallCount == 1)
        #expect(terminal.restoreCallCount == 1)
    }

    @Test func rawModeSkippedWhenTerminalIsNotInteractive() async throws {
        let mock = MockContainerService()
        await mock.setExecHandler { _, _ in ExecResult(exitCode: 0) }
        // Piped/non-TTY stdout: `ExecCommand` would compute `allocateTTY` as
        // false in this case, but exercise the runner's own guard directly.
        let terminal = RecordingTerminalController(isInteractiveTTY: false)
        let runner = ExecSessionRunner(
            containerService: mock, terminal: terminal, input: ScriptedInputSource(), output: RecordingExecOutputSink())

        _ = try await runner.run(id: "site-web", arguments: ["ls"], allocateTTY: true)

        #expect(terminal.enableCallCount == 0)
        #expect(terminal.restoreCallCount == 0)
    }

    @Test func rawModeSkippedWhenCallerDidNotRequestATTYEvenIfInteractive() async throws {
        let mock = MockContainerService()
        await mock.setExecHandler { _, _ in ExecResult(exitCode: 0) }
        let terminal = RecordingTerminalController(isInteractiveTTY: true)
        let runner = ExecSessionRunner(
            containerService: mock, terminal: terminal, input: ScriptedInputSource(), output: RecordingExecOutputSink())

        _ = try await runner.run(id: "site-web", arguments: ["ls"], allocateTTY: false)

        #expect(terminal.enableCallCount == 0)
        #expect(terminal.restoreCallCount == 0)
    }

    @Test func terminalFlagOnTheWireFollowsAllocateTTY() async throws {
        let mock = MockContainerService()
        let seenTerminalFlag = Mutex<Bool?>(nil)
        await mock.setExecHandler { _, request in
            seenTerminalFlag.withLock { $0 = request.terminal }
            return ExecResult(exitCode: 0)
        }
        let runner = ExecSessionRunner(
            containerService: mock, terminal: RecordingTerminalController(isInteractiveTTY: true),
            input: ScriptedInputSource(), output: RecordingExecOutputSink())

        _ = try await runner.run(id: "site-web", arguments: ["bash"], allocateTTY: true)
        #expect(seenTerminalFlag.withLock { $0 } == true)

        _ = try await runner.run(id: "site-web", arguments: ["ls"], allocateTTY: false)
        #expect(seenTerminalFlag.withLock { $0 } == false)
    }

    @Test func rawModeIsRestoredEvenWhenExecThrows() async throws {
        let mock = MockContainerService()
        await mock.failNext(.exec, with: .containerFailedToStart("container gone"))
        let terminal = RecordingTerminalController(isInteractiveTTY: true)
        let runner = ExecSessionRunner(
            containerService: mock, terminal: terminal, input: ScriptedInputSource(), output: RecordingExecOutputSink())

        await #expect(throws: DrupalError.containerFailedToStart("container gone")) {
            _ = try await runner.run(id: "site-web", arguments: ["sh"], allocateTTY: true)
        }
        #expect(terminal.enableCallCount == 1)
        #expect(terminal.restoreCallCount == 1)
    }

    @Test func rawModeIsRestoredEvenWhenEnablingItFails() async throws {
        let mock = MockContainerService()
        await mock.setExecHandler { _, _ in ExecResult(exitCode: 0) }
        let terminal = RecordingTerminalController(isInteractiveTTY: true)
        terminal.enableError = .platformUnavailable("tcsetattr failed")
        let runner = ExecSessionRunner(
            containerService: mock, terminal: terminal, input: ScriptedInputSource(), output: RecordingExecOutputSink())

        await #expect(throws: DrupalError.platformUnavailable("tcsetattr failed")) {
            _ = try await runner.run(id: "site-web", arguments: ["sh"], allocateTTY: true)
        }
        // `restore()` still runs (a no-op, since nothing was actually saved).
        #expect(terminal.restoreCallCount == 1)
    }

    // MARK: - Exit-code propagation

    @Test(arguments: [0, 1, 2, 127, 255])
    func remoteExitCodePassesThroughUnchanged(code: Int32) async throws {
        let mock = MockContainerService()
        await mock.setExecHandler { _, _ in ExecResult(exitCode: code) }
        let runner = ExecSessionRunner(
            containerService: mock, terminal: RecordingTerminalController(isInteractiveTTY: false),
            input: ScriptedInputSource(), output: RecordingExecOutputSink())

        let result = try await runner.run(id: "site-web", arguments: ["sh", "-c", "exit \(code)"], allocateTTY: false)
        #expect(result.exitCode == code)
    }

    @Test func serviceUnavailableDuringExecMapsToExitCode14() async throws {
        let mock = MockContainerService()
        await mock.failNext(.exec, with: .serviceUnavailable("cannot reach the drupal service"))
        let runner = ExecSessionRunner(
            containerService: mock, terminal: RecordingTerminalController(isInteractiveTTY: false),
            input: ScriptedInputSource(), output: RecordingExecOutputSink())

        do {
            _ = try await runner.run(id: "site-web", arguments: ["true"], allocateTTY: false)
            Issue.record("expected serviceUnavailable")
        } catch let error as DrupalError {
            #expect(error.exitCode == .serviceUnavailable)
            #expect(Drupal.exitStatus(for: error) == 14)
        }
    }

    // MARK: - Stream handling

    @Test func stdoutAndStderrArriveInOrderAndBeforeTheExitCodeIsReturned() async throws {
        let mock = MockContainerService()
        await mock.setExecHandler { _, request in
            request.output?(.stdout, Data("building...\n".utf8))
            request.output?(.stderr, Data("warning: x\n".utf8))
            request.output?(.stdout, Data("done\n".utf8))
            return ExecResult(exitCode: 9)
        }
        let sink = RecordingExecOutputSink()
        let runner = ExecSessionRunner(
            containerService: mock, terminal: RecordingTerminalController(isInteractiveTTY: false),
            input: ScriptedInputSource(), output: sink)

        let result = try await runner.run(id: "site-web", arguments: ["build"], allocateTTY: false)

        #expect(result.exitCode == 9)
        // All output the handler produced is already in the sink by the time
        // `run()` returns the exit code (Sortie 8 handoff: drain output
        // before propagating the exit code).
        #expect(
            sink.chunksAsStrings.map(\.1) == ["building...\n", "warning: x\n", "done\n"])
        #expect(sink.chunksAsStrings.map(\.0) == [.stdout, .stderr, .stdout])
    }

    @Test func stdinIsForwardedToTheRemoteProcess() async throws {
        let mock = MockContainerService()
        await mock.setExecHandler { _, request in
            var lines: [String] = []
            if let stdin = request.stdin {
                for await chunk in stdin { lines.append(String(decoding: chunk, as: UTF8.self)) }
            }
            for line in lines { request.output?(.stdout, Data(line.utf8)) }
            return ExecResult(exitCode: 0)
        }
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        let sink = RecordingExecOutputSink()
        let runner = ExecSessionRunner(
            containerService: mock, terminal: RecordingTerminalController(isInteractiveTTY: false),
            input: SingleUseInputSource(stream: stream), output: sink)

        async let result = runner.run(id: "site-web", arguments: ["cat"], allocateTTY: false)
        continuation.yield(Data("hello ".utf8))
        continuation.yield(Data("world".utf8))
        continuation.finish()

        _ = try await result
        #expect(sink.chunksAsStrings.map(\.1) == ["hello ", "world"])
    }

    @Test func execRequestCarriesTheResolvedContainerIDAndArguments() async throws {
        let mock = MockContainerService()
        await mock.setExecHandler { _, _ in ExecResult(exitCode: 0) }
        let runner = ExecSessionRunner(
            containerService: mock, terminal: RecordingTerminalController(isInteractiveTTY: false),
            input: ScriptedInputSource(), output: RecordingExecOutputSink())

        _ = try await runner.run(id: "my-project-web", arguments: ["drush", "cr"], allocateTTY: false)
        let calls = await mock.execRequests
        #expect(calls.count == 1)
        #expect(calls[0].id == "my-project-web")
        #expect(calls[0].arguments == ["drush", "cr"])
    }
}
