import ArgumentParser
import Foundation

/// `drupal ssh [service]`: opens an interactive login shell in a project
/// container (the web container by default) over the host service's
/// streaming exec channel, with the local terminal in raw mode for the
/// duration.
public struct SSHCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "ssh",
        abstract: "Open an interactive shell in a project container (default: web).",
        discussion: """
            Always requests a pseudo-terminal; the local terminal is put in raw mode only when stdin is a TTY. \
            There are no -i/-t flags. drupal exits with the shell's exit code. --json only changes how drupal's \
            own errors are rendered. Interrupted by SIGINT, drupal restores the terminal and exits 130.
            """
    )

    /// Runs the guest's login shell, falling back to `/bin/sh` if `$SHELL`
    /// isn't set inside the container image.
    public static let loginShellCommand = ["/bin/sh", "-c", "exec \"${SHELL:-/bin/sh}\" -l"]

    @OptionGroup public var output: OutputOptions

    @Argument(help: "Container to open a shell in: \"web\" or \"db\" (default: web).")
    public var service: String?

    public init() {}

    public func run() async throws {
        let status = try await execute(environment: LifecycleEnvironment.current)
        throw ArgumentParser.ExitCode(status)
    }

    /// Runs the shell session and returns the remote exit code.
    public func execute(environment: LifecycleEnvironment) async throws -> Int32 {
        let role = try ServiceTarget.role(for: service)
        let id = try ServiceTarget.containerID(role: role, projectRoot: environment.currentDirectory())

        let terminal = environment.makeTerminal()
        let runner = ExecSessionRunner(
            containerService: environment.makeClient(),
            terminal: terminal,
            input: environment.execInput,
            output: environment.execOutput
        )

        // Raw mode is the CLI's job (Sortie 8 handoff): restored on normal
        // exit and thrown errors by `ExecSessionRunner`'s own `defer`, and
        // here on SIGINT too, since raw mode alone doesn't guarantee the
        // signal is suppressed before it's entered.
        let cancelGuard = environment.installInterruptGuard({ terminal.restore() }, { Foundation.exit($0) })
        defer { cancelGuard() }

        let result = try await runner.run(
            id: id,
            arguments: Self.loginShellCommand,
            allocateTTY: true
        )
        return result.exitCode
    }
}
