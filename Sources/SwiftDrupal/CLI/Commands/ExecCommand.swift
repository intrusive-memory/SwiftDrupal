import ArgumentParser
import Foundation

/// `drupal exec <service> -- <command>`: runs a command inside the web or db
/// container over the host service's streaming exec channel and exits with
/// the remote command's own exit code.
public struct ExecCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "exec",
        abstract: "Run a command inside a project container.",
        discussion: """
            Remote stdout/stderr are passed through unchanged and drupal exits with the remote command's exit \
            code. There are no -i/-t flags: a pseudo-terminal is allocated (and the local terminal put in raw \
            mode) exactly when stdin is a TTY. --json only changes how drupal's own errors are rendered. \
            Interrupted by SIGINT, drupal restores the terminal and exits 130 (128+signal).
            """
    )

    @OptionGroup public var output: OutputOptions

    @Argument(help: "Container to run in: \"web\" or \"db\".")
    public var service: String

    @Argument(parsing: .postTerminator, help: "Command to run, after \"--\", e.g. `drupal exec web -- drush cr`.")
    public var command: [String] = []

    public init() {}

    public func run() async throws {
        let status = try await execute(environment: LifecycleEnvironment.current)
        throw ArgumentParser.ExitCode(status)
    }

    /// Runs the command and returns the remote exit code.
    public func execute(environment: LifecycleEnvironment) async throws -> Int32 {
        guard !command.isEmpty else {
            throw ValidationError("Provide a command to run after \"--\", e.g. `drupal exec web -- ls`.")
        }

        let role = try ServiceTarget.role(for: service)
        let id = try ServiceTarget.containerID(role: role, projectRoot: environment.currentDirectory())

        let terminal = environment.makeTerminal()
        let runner = ExecSessionRunner(
            containerService: environment.makeClient(),
            terminal: terminal,
            input: environment.execInput,
            output: environment.execOutput
        )

        let cancelGuard = environment.installInterruptGuard({ terminal.restore() }, { Foundation.exit($0) })
        defer { cancelGuard() }

        let result = try await runner.run(
            id: id,
            arguments: command,
            allocateTTY: terminal.isInteractiveTTY
        )
        return result.exitCode
    }
}
