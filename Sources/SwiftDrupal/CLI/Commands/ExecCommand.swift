import ArgumentParser
import Foundation

/// `drupal exec <service> -- <command>`: runs a command inside the web or db
/// container over the host service's streaming exec channel and exits with
/// the remote command's own exit code.
public struct ExecCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "exec",
        abstract: "Run a command inside a project container."
    )

    @Argument(help: "Container to run in: \"web\" or \"db\".")
    public var service: String

    @Argument(parsing: .postTerminator, help: "Command to run, after \"--\", e.g. `drupal exec web -- drush cr`.")
    public var command: [String] = []

    public init() {}

    public func run() async throws {
        guard !command.isEmpty else {
            throw ValidationError("Provide a command to run after \"--\", e.g. `drupal exec web -- ls`.")
        }

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

        let guardToken = InterruptGuard.install(cleanup: { terminal.restore() })
        defer { guardToken.cancel() }

        let result = try await runner.run(
            id: id,
            arguments: command,
            allocateTTY: terminal.isInteractiveTTY
        )
        throw ArgumentParser.ExitCode(result.exitCode)
    }
}
