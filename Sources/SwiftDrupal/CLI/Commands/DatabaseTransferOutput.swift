import Foundation

/// Renders a `DatabaseTransfer.Result` for `import-db`/`export-db`.
enum DatabaseTransferOutput {
    enum Destination {
        case standardOutput
        case standardError
    }

    static func emit(_ result: DatabaseTransfer.Result, format: OutputFormat, to destination: Destination = .standardOutput) {
        let text: String
        switch format {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = (try? encoder.encode(result)) ?? Data("{}".utf8)
            text = String(decoding: data, as: UTF8.self) + "\n"
        case .text:
            let verb = result.operation == "import" ? "Imported" : "Exported"
            let target = result.file.map { " \(result.operation == "import" ? "from" : "to") \($0)" } ?? ""
            let status = result.success ? "ok" : "failed (exit \(result.exitStatus))"
            text = "\(verb)\(target): \(result.bytesProcessed) bytes, container \(result.containerID) — \(status)\n"
        }
        write(text, to: destination)
    }

    private static func write(_ text: String, to destination: Destination) {
        let data = Data(text.utf8)
        switch destination {
        case .standardOutput: FileHandle.standardOutput.write(data)
        case .standardError: FileHandle.standardError.write(data)
        }
    }
}
