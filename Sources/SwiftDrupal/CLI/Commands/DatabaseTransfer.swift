import Foundation
import Synchronization

/// Shared streaming logic behind `drupal import-db` and `drupal export-db`
/// (Sortie 5). Kept independent of `ArgumentParser` so it can be exercised
/// directly in tests against a mock `ContainerService`.
///
/// Both commands go through whatever `ContainerService` they are given —
/// production commands always pass a `ServiceClientContainerService`, so an
/// unreachable host service surfaces as `DrupalError.serviceUnavailable`
/// (exit 14) with no in-process fallback (OQ-4). Data is streamed in bounded
/// chunks in both directions; the whole dump is never held in memory.
public enum DatabaseTransfer {

    // MARK: - Project / container resolution

    /// The project name for the project rooted at `projectRoot`: an explicit
    /// `name:` in `.drupal/config.yaml` wins, otherwise the directory name.
    /// A missing or unreadable config file is not an error here — only the
    /// name is needed to derive the database container id.
    public static func resolveProjectName(projectRoot: URL) -> String {
        let configURL = ProjectConfig.configFileURL(projectRoot: projectRoot)
        let config = try? ProjectConfig.load(from: configURL)
        return ProjectNaming.projectName(projectRoot: projectRoot, config: config)
    }

    /// The id of the project's database container, as built by
    /// `DatabaseContainerSpecBuilder` (Sortie 2/8): `<project>-db`.
    public static func databaseContainerID(projectName: String) -> String {
        ContainerNaming.containerID(projectName: projectName, role: .db)
    }

    // MARK: - Database client credentials

    /// v1.0 supports MariaDB only (`DDEVImageCatalog.supportedDatabaseTypes`).
    /// These match DDEV's own `ddev-dbserver` image defaults: database `db`,
    /// owned by user `db`/password `db` — the credentials Drupal's own
    /// `settings.php` convention already expects for a local DDEV-style site.
    public enum Credentials {
        public static let database = "db"
        public static let user = "db"
        public static let password = "db"
    }

    /// Arguments to run the MariaDB/MySQL CLI client with a dump on its stdin.
    public static let importClientArguments = [
        "mysql", "-u\(Credentials.user)", "-p\(Credentials.password)", Credentials.database,
    ]

    /// Arguments to run the dump utility, writing a plain SQL dump to stdout.
    public static let exportClientArguments = [
        "mysqldump", "-u\(Credentials.user)", "-p\(Credentials.password)", Credentials.database,
    ]

    // MARK: - Gzip detection

    public static let gzipMagicBytes: [UInt8] = [0x1F, 0x8B]

    /// True when `url` is a gzip-compressed file: `.gz` extension (any case)
    /// or the file starts with the gzip magic bytes `1f 8b`.
    public static func isGzipCompressed(_ url: URL) throws -> Bool {
        if url.pathExtension.lowercased() == "gz" { return true }
        guard let handle = FileHandle(forReadingAtPath: url.path) else {
            throw DrupalError.invalidConfig("cannot open \(url.path) for reading")
        }
        defer { try? handle.close() }
        guard let head = try handle.read(upToCount: 2), head.count == 2 else { return false }
        return Array(head) == gzipMagicBytes
    }

    // MARK: - Result

    /// JSON result shape for both `import-db` and `export-db`:
    /// `{"operation","containerId","file","compressed","bytesProcessed","exitStatus","success"}`.
    public struct Result: Codable, Equatable, Sendable {
        public var operation: String
        public var containerID: String
        /// The local file path involved. Absent for `export-db` streamed to stdout.
        public var file: String?
        /// Whether the input (import) was gzip-decompressed while streaming.
        public var compressed: Bool
        /// Bytes actually transferred: decompressed SQL bytes fed to the
        /// database client (import), or SQL bytes captured from the dump
        /// utility's stdout (export).
        public var bytesProcessed: Int
        public var exitStatus: Int32
        public var success: Bool

        enum CodingKeys: String, CodingKey {
            case operation
            case containerID = "containerId"
            case file
            case compressed
            case bytesProcessed
            case exitStatus
            case success
        }

        public init(operation: String, containerID: String, file: String?, compressed: Bool, bytesProcessed: Int, exitStatus: Int32) {
            self.operation = operation
            self.containerID = containerID
            self.file = file
            self.compressed = compressed
            self.bytesProcessed = bytesProcessed
            self.exitStatus = exitStatus
            self.success = exitStatus == 0
        }
    }

    // MARK: - Import

    /// Chunk size for both reading the local dump file and feeding stdin.
    static let chunkSize = 1 << 20  // 1 MiB

    /// Streams `fileURL` (decompressing it first if `compressed`) into the
    /// database container's SQL client via `containerService.exec`.
    public static func importDump(
        containerService: some ContainerService,
        containerID: String,
        fileURL: URL,
        compressed: Bool
    ) async throws -> Result {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw DrupalError.invalidConfig("import file not found: \(fileURL.path)")
        }

        let counter = Mutex(0)
        let (stdin, continuation) = AsyncStream<Data>.makeStream()

        let pump = Task<Void, any Error> {
            defer { continuation.finish() }
            let handle: FileHandle
            do {
                handle = try FileHandle(forReadingFrom: fileURL)
            } catch {
                throw DrupalError.invalidConfig("cannot open \(fileURL.path): \(error.localizedDescription)")
            }
            defer { try? handle.close() }

            let inflater: GzipInflateStream? = compressed ? try GzipInflateStream() : nil

            while true {
                try Task.checkCancellation()
                let chunk = try await BlockingIO.run { try handle.read(upToCount: DatabaseTransfer.chunkSize) }
                guard let chunk, !chunk.isEmpty else { break }
                let decoded = try inflater?.inflate(chunk) ?? chunk
                if !decoded.isEmpty {
                    counter.withLock { $0 += decoded.count }
                    continuation.yield(decoded)
                }
            }
            // Flush any bytes zlib is still holding once input is exhausted.
            if let tail = try inflater?.inflate(Data()), !tail.isEmpty {
                counter.withLock { $0 += tail.count }
                continuation.yield(tail)
            }
        }

        let request = ExecRequest(arguments: importClientArguments, stdin: stdin)
        let execResult: ExecResult
        do {
            execResult = try await containerService.exec(id: containerID, request)
        } catch {
            pump.cancel()
            _ = try? await pump.value
            throw error
        }
        try await pump.value

        return Result(
            operation: "import",
            containerID: containerID,
            file: fileURL.path,
            compressed: compressed,
            bytesProcessed: counter.withLock { $0 },
            exitStatus: execResult.exitCode
        )
    }

    // MARK: - Export

    /// Runs the database container's dump utility and streams its stdout to
    /// `destination`, or to `stdout` (the process's own standard output, for
    /// piping) when `destination` is nil. Never buffers the whole dump.
    public static func exportDump(
        containerService: some ContainerService,
        containerID: String,
        destination: URL?,
        stdout: FileHandle = .standardOutput
    ) async throws -> Result {
        let handle: FileHandle
        if let destination {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
                throw DrupalError.invalidConfig("cannot create \(destination.path)")
            }
            guard let created = FileHandle(forWritingAtPath: destination.path) else {
                throw DrupalError.invalidConfig("cannot open \(destination.path) for writing")
            }
            handle = created
        } else {
            handle = stdout
        }

        let sink = ExportSink(handle: handle)
        let request = ExecRequest(
            arguments: exportClientArguments,
            output: { stream, data in
                guard stream == .stdout, !data.isEmpty else { return }
                sink.write(data)
            }
        )

        let execResult = try await containerService.exec(id: containerID, request)
        // Only close a file we opened ourselves; never close the caller's stdout.
        if destination != nil { try? handle.close() }

        if let sinkError = sink.capturedError { throw sinkError }

        return Result(
            operation: "export",
            containerID: containerID,
            file: destination?.path,
            compressed: false,
            bytesProcessed: sink.bytesWritten,
            exitStatus: execResult.exitCode
        )
    }
}

/// Thread-safe sink for `export-db` output: writes each chunk to a file
/// handle as it arrives and tracks the byte count, without ever buffering
/// the whole dump.
private final class ExportSink: Sendable {
    private struct State {
        var bytes = 0
        var error: (any Error)?
    }

    private let handle: FileHandle
    private let state = Mutex(State())

    init(handle: FileHandle) {
        self.handle = handle
    }

    func write(_ data: Data) {
        state.withLock { $0.bytes += data.count }
        do {
            try handle.write(contentsOf: data)
        } catch {
            state.withLock { if $0.error == nil { $0.error = error } }
        }
    }

    var bytesWritten: Int { state.withLock { $0.bytes } }
    var capturedError: (any Error)? { state.withLock { $0.error } }
}
