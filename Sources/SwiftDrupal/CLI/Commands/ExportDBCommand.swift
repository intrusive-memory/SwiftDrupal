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
        abstract: "Stream a SQL dump of the project's database container to a file or stdout."
    )

    @Argument(help: "Destination file for the dump. Omit to stream the dump to stdout.")
    public var file: String?

    @Option(name: .customLong("project-root"), help: "Project root directory (defaults to the current directory).")
    public var projectRoot: String?

    @OptionGroup public var output: OutputOptions

    public init() {}

    public func run() async throws {
        let root = URL(fileURLWithPath: projectRoot ?? FileManager.default.currentDirectoryPath, isDirectory: true)
        let projectName = DatabaseTransfer.resolveProjectName(projectRoot: root)
        let containerID = DatabaseTransfer.databaseContainerID(projectName: projectName)

        let destinationURL = file.map { URL(fileURLWithPath: $0) }

        let service = ServiceClientContainerService()
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
            result, format: output.format(),
            to: destinationURL == nil ? .standardError : .standardOutput
        )
        if result.exitStatus != 0 {
            throw ArgumentParser.ExitCode(result.exitStatus)
        }
    }
}
