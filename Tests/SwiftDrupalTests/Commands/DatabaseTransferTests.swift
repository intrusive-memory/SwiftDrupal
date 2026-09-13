import ArgumentParser
import CZlib
import Foundation
import Synchronization
import Testing

@testable import SwiftDrupal

/// Compresses `data` into a real gzip stream using libz (windowBits 31
/// selects the gzip wrapper on the encode side), so tests exercise
/// `GzipInflateStream` against a byte-for-byte real gzip fixture rather than
/// a hand-rolled one.
private func gzipCompress(_ data: Data) throws -> Data {
    var stream = z_stream()
    stream.zalloc = nil
    stream.zfree = nil
    stream.opaque = nil
    let initResult = deflateInit2_(
        &stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY,
        zlibVersion(), Int32(MemoryLayout<z_stream>.size))
    #expect(initResult == Z_OK)
    defer { deflateEnd(&stream) }

    var output = Data()
    var input = data
    var outBuffer = [UInt8](repeating: 0, count: 64 * 1024)
    input.withUnsafeMutableBytes { (rawIn: UnsafeMutableRawBufferPointer) in
        stream.next_in = rawIn.bindMemory(to: UInt8.self).baseAddress
        stream.avail_in = UInt32(rawIn.count)
        repeat {
            let produced: Int = outBuffer.withUnsafeMutableBufferPointer { outPtr in
                stream.next_out = outPtr.baseAddress
                stream.avail_out = UInt32(outPtr.count)
                let code = CZlib.deflate(&stream, Z_FINISH)
                precondition(code == Z_OK || code == Z_STREAM_END, "deflate failed: \(code)")
                return outPtr.count - Int(stream.avail_out)
            }
            if produced > 0 { output.append(contentsOf: outBuffer[0..<produced]) }
        } while stream.avail_out == 0
    }
    return output
}

private func tempFile(named name: String = UUID().uuidString, contents: Data) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
    try contents.write(to: url)
    return url
}

// MARK: - Gzip detection

@Suite struct GzipDetectionTests {
    @Test func detectsByExtension() throws {
        let url = try tempFile(named: "\(UUID().uuidString).sql.gz", contents: Data("not actually gzip".utf8))
        #expect(try DatabaseTransfer.isGzipCompressed(url))
    }

    @Test func detectsByMagicBytesRegardlessOfExtension() throws {
        let compressed = try gzipCompress(Data("SELECT 1;\n".utf8))
        let url = try tempFile(named: "\(UUID().uuidString).sql", contents: compressed)
        #expect(try DatabaseTransfer.isGzipCompressed(url))
    }

    @Test func plainSQLFileIsNotCompressed() throws {
        let url = try tempFile(named: "\(UUID().uuidString).sql", contents: Data("SELECT 1;\n".utf8))
        #expect(try DatabaseTransfer.isGzipCompressed(url) == false)
    }
}

// MARK: - GzipInflateStream round trip

@Suite struct GzipInflateStreamTests {
    @Test func roundTripsSmallPayload() throws {
        let original = Data(String(repeating: "INSERT INTO t VALUES (1);\n", count: 500).utf8)
        let compressed = try gzipCompress(original)
        let inflater = try GzipInflateStream()
        var decoded = Data()
        // Feed in small chunks to exercise multi-call streaming.
        var offset = 0
        while offset < compressed.count {
            let end = min(offset + 37, compressed.count)
            decoded.append(try inflater.inflate(compressed[offset..<end]))
            offset = end
        }
        decoded.append(try inflater.inflate(Data()))
        #expect(decoded == original)
        #expect(inflater.finished)
    }
}

// MARK: - Project/container resolution

@Suite struct ProjectResolutionTests {
    @Test func defaultsToDirectoryName() throws {
        let root = URL(fileURLWithPath: "/Users/dev/Sites/my-site", isDirectory: true)
        #expect(DatabaseTransfer.resolveProjectName(projectRoot: root) == "my-site")
        #expect(DatabaseTransfer.databaseContainerID(projectName: "my-site") == "my-site-db")
    }
}

// MARK: - Mock exec channel

/// Thread-safe byte counter usable from a `@Sendable` exec handler closure.
/// `Synchronization.Mutex` is itself noncopyable and can't be captured by
/// value into an escaping closure parameter, so it is wrapped in a class here.
private final class ByteCounter: Sendable {
    private let storage = Mutex(0)
    func add(_ n: Int) { storage.withLock { $0 += n } }
    var value: Int { storage.withLock { $0 } }
}

/// A `ContainerService` exec handler that behaves like a real `mysql`/`mysqldump`
/// process: for import, drains stdin (simulating the database consuming the
/// dump) and reports how many bytes it received; for export, emits scripted
/// stdout chunks through `request.output`.
private func drainingExecHandler(receivedBytes: ByteCounter, exitCode: Int32 = 0) -> @Sendable (String, ExecRequest) async throws -> ExecResult {
    { _, request in
        if let stdin = request.stdin {
            for await chunk in stdin {
                receivedBytes.add(chunk.count)
            }
        }
        return ExecResult(exitCode: exitCode)
    }
}

private func echoingExecHandler(chunks: [Data], exitCode: Int32 = 0) -> @Sendable (String, ExecRequest) async throws -> ExecResult {
    { _, request in
        for chunk in chunks { request.output?(.stdout, chunk) }
        request.output?(.stderr, Data("note\n".utf8))
        return ExecResult(exitCode: exitCode)
    }
}

// MARK: - importDump

@Suite struct ImportDumpTests {
    @Test func streamsPlainSQLAndReportsBytesProcessed() async throws {
        let sql = Data(String(repeating: "INSERT INTO node VALUES (1);\n", count: 1000).utf8)
        let fileURL = try tempFile(contents: sql)
        let mock = MockContainerService()
        let received = ByteCounter()
        await mock.setExecHandler(drainingExecHandler(receivedBytes: received))

        let result = try await DatabaseTransfer.importDump(
            containerService: mock, containerID: "my-site-db", fileURL: fileURL, compressed: false)

        #expect(result.operation == "import")
        #expect(result.containerID == "my-site-db")
        #expect(result.compressed == false)
        #expect(result.bytesProcessed == sql.count)
        #expect(received.value == sql.count)
        #expect(result.exitStatus == 0)
        #expect(result.success)

        let calls = await mock.calls
        #expect(calls.contains(.exec("my-site-db", DatabaseTransfer.importClientArguments)))
    }

    @Test func decompressesGzipFixtureWhileStreaming() async throws {
        let sql = Data(String(repeating: "UPDATE users SET name='x' WHERE id=1;\n", count: 2000).utf8)
        let compressed = try gzipCompress(sql)
        #expect(compressed.count < sql.count, "fixture should actually compress")
        let fileURL = try tempFile(named: "\(UUID().uuidString).sql.gz", contents: compressed)

        let mock = MockContainerService()
        let received = ByteCounter()
        await mock.setExecHandler(drainingExecHandler(receivedBytes: received))

        let result = try await DatabaseTransfer.importDump(
            containerService: mock, containerID: "my-site-db", fileURL: fileURL, compressed: true)

        #expect(result.compressed)
        // Bytes actually fed to the database client are the *decompressed* bytes.
        #expect(result.bytesProcessed == sql.count)
        #expect(received.value == sql.count)
        #expect(result.exitStatus == 0)
    }

    @Test func missingFileFailsWithInvalidConfig() async throws {
        let mock = MockContainerService()
        await #expect(throws: DrupalError.self) {
            _ = try await DatabaseTransfer.importDump(
                containerService: mock, containerID: "my-site-db",
                fileURL: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).sql"), compressed: false)
        }
    }

    @Test func nonZeroExitStatusIsReportedNotThrown() async throws {
        let sql = Data("SELECT 1;\n".utf8)
        let fileURL = try tempFile(contents: sql)
        let mock = MockContainerService()
        let received = ByteCounter()
        await mock.setExecHandler(drainingExecHandler(receivedBytes: received, exitCode: 2))

        let result = try await DatabaseTransfer.importDump(
            containerService: mock, containerID: "my-site-db", fileURL: fileURL, compressed: false)

        #expect(result.exitStatus == 2)
        #expect(result.success == false)
    }

    @Test func serviceUnavailablePropagates() async throws {
        let sql = Data("SELECT 1;\n".utf8)
        let fileURL = try tempFile(contents: sql)
        let mock = MockContainerService()
        await mock.failNext(.exec, with: .serviceUnavailable("no socket"))

        await #expect(throws: DrupalError.serviceUnavailable("no socket")) {
            _ = try await DatabaseTransfer.importDump(
                containerService: mock, containerID: "my-site-db", fileURL: fileURL, compressed: false)
        }
    }
}

// MARK: - exportDump

@Suite struct ExportDumpTests {
    @Test func streamsDumpToAFileAndReportsBytesProcessed() async throws {
        let chunks = [Data("-- dump\n".utf8), Data(String(repeating: "INSERT INTO t VALUES (1);\n", count: 500).utf8)]
        let expected = chunks.reduce(Data(), +)
        let mock = MockContainerService()
        await mock.setExecHandler(echoingExecHandler(chunks: chunks))

        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sql")
        let result = try await DatabaseTransfer.exportDump(
            containerService: mock, containerID: "my-site-db", destination: destination)

        #expect(result.operation == "export")
        #expect(result.bytesProcessed == expected.count)
        #expect(result.file == destination.path)
        #expect(result.exitStatus == 0)

        let written = try Data(contentsOf: destination)
        #expect(written == expected)

        let calls = await mock.calls
        #expect(calls.contains(.exec("my-site-db", DatabaseTransfer.exportClientArguments)))
    }

    @Test func streamsDumpToProvidedStdoutHandleWhenNoDestination() async throws {
        let chunks = [Data("SELECT 1;\n".utf8), Data("SELECT 2;\n".utf8)]
        let expected = chunks.reduce(Data(), +)
        let mock = MockContainerService()
        await mock.setExecHandler(echoingExecHandler(chunks: chunks))

        let pipe = Pipe()
        let result = try await DatabaseTransfer.exportDump(
            containerService: mock, containerID: "my-site-db", destination: nil,
            stdout: pipe.fileHandleForWriting)
        try pipe.fileHandleForWriting.close()

        #expect(result.file == nil)
        #expect(result.bytesProcessed == expected.count)
        let read = pipe.fileHandleForReading.readDataToEndOfFile()
        #expect(read == expected)
    }
}

// MARK: - Command argument parsing

@Suite struct DatabaseCommandParsingTests {
    @Test func importRequiresAFileArgument() throws {
        let command = try ImportDBCommand.parse(["dump.sql"])
        #expect(command.file == "dump.sql")
        #expect(command.projectRoot == nil)
    }

    @Test func importAcceptsProjectRootOption() throws {
        let command = try ImportDBCommand.parse(["--project-root", "/tmp/site", "dump.sql.gz"])
        #expect(command.file == "dump.sql.gz")
        #expect(command.projectRoot == "/tmp/site")
    }

    @Test func exportFileArgumentIsOptional() throws {
        let withoutFile = try ExportDBCommand.parse([])
        #expect(withoutFile.file == nil)

        let withFile = try ExportDBCommand.parse(["out.sql"])
        #expect(withFile.file == "out.sql")
    }

    @Test func bothCommandsAreRegisteredOnTheRootCommand() {
        let names = Drupal.configuration.subcommands.map { $0.configuration.commandName }
        #expect(names.contains("import-db"))
        #expect(names.contains("export-db"))
    }
}
