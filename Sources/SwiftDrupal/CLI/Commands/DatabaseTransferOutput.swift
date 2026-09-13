import Foundation

/// Renders a `DatabaseTransfer.Result` for `import-db`/`export-db`.
enum DatabaseTransferOutput {
    /// Renders `result` and hands the document (without a trailing newline) to `write`.
    static func emit(_ result: DatabaseTransfer.Result, format: OutputFormat, write: (String) -> Void) {
        switch format {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = (try? encoder.encode(result)) ?? Data("{}".utf8)
            write(String(decoding: data, as: UTF8.self))
        case .text:
            let verb = result.operation == "import" ? "Imported" : "Exported"
            let target = result.file.map { " \(result.operation == "import" ? "from" : "to") \($0)" } ?? ""
            let status = result.success ? "ok" : "failed (exit \(result.exitStatus))"
            write("\(verb)\(target): \(result.bytesProcessed) bytes, container \(result.containerID) — \(status)")
        }
    }
}
