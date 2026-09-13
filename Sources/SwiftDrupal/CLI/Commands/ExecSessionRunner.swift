import Foundation

/// Runs one streaming exec session against a project container and wires it
/// to the local terminal: raw mode when a pty is requested and the local
/// terminal is interactive, stdin forwarding, and stdout/stderr passthrough.
///
/// This is the logic shared by `ExecCommand` and `SSHCommand`; those types
/// are thin `ArgumentParser` wrappers that build one of these with live
/// dependencies (`ServiceClientContainerService`, `PosixTerminalController`,
/// `FileHandleInputSource`, `LiveExecOutputSink`). Tests exercise this type
/// directly with a `MockContainerService` and in-memory doubles for the
/// terminal, stdin, and stdout/stderr — never a real TTY or process stdio.
public struct ExecSessionRunner: Sendable {
    public var containerService: any ContainerService
    public var terminal: any TerminalController
    public var input: any ExecInputSource
    public var output: any ExecOutputSink

    public init(
        containerService: any ContainerService,
        terminal: any TerminalController,
        input: any ExecInputSource,
        output: any ExecOutputSink
    ) {
        self.containerService = containerService
        self.terminal = terminal
        self.input = input
        self.output = output
    }

    /// Runs `arguments` inside container `id` and waits for it to exit.
    ///
    /// When `allocateTTY` is true and the local terminal is interactive, the
    /// terminal is switched to raw mode for the call and restored afterwards
    /// — on the normal return path and on a thrown error alike. `terminal`
    /// bool passed on the wire follows `allocateTTY` directly (Sortie 8's
    /// `ExecRequestPayload.terminal`); output chunks are delivered to
    /// `output` synchronously as they arrive, all before this method returns
    /// the final `ExecResult`, so a caller never observes the exit code
    /// before the output it followed.
    @discardableResult
    public func run(
        id: String,
        arguments: [String],
        environment: [String] = [],
        workingDirectory: String? = nil,
        allocateTTY: Bool,
        forwardStdin: Bool = true
    ) async throws -> ExecResult {
        let useRawMode = allocateTTY && terminal.isInteractiveTTY
        // Registered before `enableRawMode()` runs so a throw from it (partial
        // failure part way through `tcsetattr`) still restores whatever the
        // terminal controller saved; `restore()` is a no-op if nothing was
        // saved.
        defer { if useRawMode { terminal.restore() } }
        if useRawMode { try terminal.enableRawMode() }

        let output = self.output
        let request = ExecRequest(
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            terminal: allocateTTY,
            stdin: forwardStdin ? input.makeStream() : nil,
            output: { stream, data in output.write(stream, data) }
        )
        return try await containerService.exec(id: id, request)
    }
}
