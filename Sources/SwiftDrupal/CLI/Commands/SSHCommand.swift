import ArgumentParser
import Foundation

/// `drupal ssh [service]`: opens an interactive login shell in a project
/// container (the web container by default) over the host service's
/// streaming exec channel, with the local terminal in raw mode for the
/// duration.
public struct SSHCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "ssh",
        abstract: "Open an interactive shell in a project container (default: web)."
    )

    /// Runs the guest's login shell, falling back to `/bin/sh` if `$SHELL`
    /// isn't set inside the container image.
    public static let loginShellCommand = ["/bin/sh", "-c", "exec \"${SHELL:-/bin/sh}\" -l"]

    @Argument(help: "Container to open a shell in: \"web\" or \"db\" (default: web).")
    public var service: String?

    public init() {}

    public func run() async throws {
        let projectRoot = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
        let role = try ServiceTarget.role(for: service)
        let id = try ServiceTarget.containerID(role: role, projectRoot: projectRoot)

        let terminal = PosixTerminalController()
        let runner = ExecSessionRunner(
            containerService: ServiceClientContainerService(),
            terminal: terminal,
            input: FileHandleInputSource(),
            output: LiveExecOutputSink()
        )

        // Raw mode is the CLI's job (Sortie 8 handoff): restored on normal
        // exit and thrown errors by `ExecSessionRunner`'s own `defer`, and
        // here on SIGINT too, since raw mode alone doesn't guarantee the
        // signal is suppressed before it's entered.
        let guardToken = InterruptGuard.install(cleanup: { terminal.restore() })
        defer { guardToken.cancel() }

        let result = try await runner.run(
            id: id,
            arguments: Self.loginShellCommand,
            allocateTTY: true
        )
        throw ArgumentParser.ExitCode(result.exitCode)
    }
}
