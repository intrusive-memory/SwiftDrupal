import ArgumentParser
import Foundation

/// `drupal export-db [<file>]`: runs the database container's dump utility
/// via the host service's exec channel (Sortie 8's
/// `ServiceClientContainerService`) and streams the plain SQL dump to `file`,
/// or to this process's own stdout when no path is given. Never falls back
/// to an in-process container handle (OQ-4): an unreachable service surfaces
/// as `DrupalError.serviceUnavailable` (exit 14).
public struct ExportDBCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "export-db",
        abstract: "Stream a SQL dump of the project's database container to a file or stdout.",
        discussion: """
            With a file argument, the result document goes to stdout. Without one, the SQL goes to stdout and the \
            result document (still JSON under --json or a non-TTY stdout) goes to stderr. An unreachable service \
            exits 14; a non-zero exit from the dump utility exits 1.
            """
    )

    @Argument(help: "Destination file for the dump. Omit to stream the dump to stdout.")
    public var file: String?

    @Option(name: .customLong("project-root"), help: "Project root directory (defaults to the current directory).")
    public var projectRoot: String?

    @OptionGroup public var output: OutputOptions

    public init() {}

    public func run() async throws {
        let environment = LifecycleEnvironment.current
        let cwd = environment.currentDirectory()
        let root = projectRoot.map { URL(fileURLWithPath: $0, isDirectory: true, relativeTo: cwd).standardizedFileURL } ?? cwd
        let projectName = DatabaseTransfer.resolveProjectName(projectRoot: root)
        let containerID = DatabaseTransfer.databaseContainerID(projectName: projectName)

        let destinationURL = file.map { URL(fileURLWithPath: $0, relativeTo: cwd).standardizedFileURL }

        let service = environment.makeClient()
        let result = try await DatabaseTransfer.exportDump(
            containerService: service,
            containerID: containerID,
            destination: destinationURL
        )

        // When no file is given, the dump itself is streamed to stdout as the
        // pipe's payload, so the status/result document goes to stderr
        // instead — printing it to stdout would corrupt the SQL stream for a
        // consumer like `drupal export-db | gzip > out.sql.gz`. With a file
        // destination, stdout is free and carries the JSON/text result as
        // every other command does.
        DatabaseTransferOutput.emit(
            result, format: output.format(using: environment.outputResolver),
            write: destinationURL == nil ? environment.writeError : environment.writeOutput
        )
        // See ImportDBCommand: the dump utility's status is in the result
        // document; the process exits with the generic failure code.
        if result.exitStatus != 0 {
            throw ArgumentParser.ExitCode.failure
        }
    }
}
