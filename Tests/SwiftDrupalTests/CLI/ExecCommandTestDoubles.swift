import Foundation
import Synchronization
@testable import SwiftDrupal

// Test doubles for `ExecCommandTests` / `SSHCommandTests`: scriptable stand-ins
// for the terminal, stdin, and stdout/stderr `ExecSessionRunner` talks to, so
// tests never touch a real TTY or process stdio.

/// Records raw-mode enable/restore calls instead of touching a real terminal.
final class RecordingTerminalController: TerminalController, @unchecked Sendable {
    private let lock = NSLock()
    let isInteractiveTTY: Bool
    private var _enableCallCount = 0
    private var _restoreCallCount = 0
    var enableError: DrupalError?

    init(isInteractiveTTY: Bool) {
        self.isInteractiveTTY = isInteractiveTTY
    }

    var enableCallCount: Int { lock.withLock { _enableCallCount } }
    var restoreCallCount: Int { lock.withLock { _restoreCallCount } }

    func enableRawMode() throws {
        lock.withLock { _enableCallCount += 1 }
        if let enableError { throw enableError }
    }

    func restore() {
        lock.withLock { _restoreCallCount += 1 }
    }
}

/// Yields a fixed, pre-scripted sequence of stdin chunks.
struct ScriptedInputSource: ExecInputSource {
    let chunks: [Data]

    init(chunks: [Data] = []) {
        self.chunks = chunks
    }

    func makeStream() -> AsyncStream<Data> {
        AsyncStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
    }
}

/// Hands back one already-constructed stream (so a test can feed it live,
/// the way `ServiceStreamingOrderTests.execOutputAndStdinAreOrdered` does).
struct SingleUseInputSource: ExecInputSource {
    let stream: AsyncStream<Data>

    func makeStream() -> AsyncStream<Data> { stream }
}

/// Records every stdout/stderr chunk `ExecSessionRunner` delivers, in order.
final class RecordingExecOutputSink: ExecOutputSink, @unchecked Sendable {
    private let storage = Mutex<[(StdioStream, Data)]>([])

    func write(_ stream: StdioStream, _ data: Data) {
        storage.withLock { $0.append((stream, data)) }
    }

    var chunks: [(StdioStream, Data)] { storage.withLock { $0 } }
    var chunksAsStrings: [(StdioStream, String)] {
        chunks.map { ($0.0, String(decoding: $0.1, as: UTF8.self)) }
    }
}
