import ArgumentParser
import Foundation

/// `drupal import-db <file>`: streams a plain (or gzip-compressed) SQL dump
/// into the project's database container via the host service's exec
/// channel (Sortie 8's `ServiceClientContainerService`). Never falls back to
/// an in-process container handle (OQ-4): an unreachable service surfaces as
/// `DrupalError.serviceUnavailable` (exit 14).
public struct ImportDBCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "import-db",
        abstract: "Stream a SQL dump into the project's database container."
    )

    @Argument(
        help: "Path to the SQL dump to import. A gzip-compressed file (.gz extension, or gzip magic bytes) is decompressed while streaming."
    )
    public var file: String

    @Option(name: .customLong("project-root"), help: "Project root directory (defaults to the current directory).")
    public var projectRoot: String?

    @OptionGroup public var output: OutputOptions

    public init() {}

    public func run() async throws {
        let root = URL(fileURLWithPath: projectRoot ?? FileManager.default.currentDirectoryPath, isDirectory: true)
        let projectName = DatabaseTransfer.resolveProjectName(projectRoot: root)
        let containerID = DatabaseTransfer.databaseContainerID(projectName: projectName)

        let fileURL = URL(fileURLWithPath: file)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw DrupalError.invalidConfig("import file not found: \(fileURL.path)")
        }
        let compressed = try DatabaseTransfer.isGzipCompressed(fileURL)

        let service = ServiceClientContainerService()
        let result = try await DatabaseTransfer.importDump(
            containerService: service,
            containerID: containerID,
            fileURL: fileURL,
            compressed: compressed
        )

        DatabaseTransferOutput.emit(result, format: output.format())
        if result.exitStatus != 0 {
            throw ArgumentParser.ExitCode(result.exitStatus)
        }
    }
}
