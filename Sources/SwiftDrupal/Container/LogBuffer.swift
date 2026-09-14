import Foundation
import Synchronization

/// Splits raw output chunks into lines, keeps a bounded backlog, and fans lines
/// out to live subscribers. Runtime-agnostic so it is unit-testable.
public final class LogBuffer: Sendable {
    public static let defaultCapacity = 10_000

    private struct State {
        var lines: [LogLine] = []
        var partial: [StdioStream: Data] = [:]
        var subscribers: [UUID: AsyncThrowingStream<LogLine, any Error>.Continuation] = [:]
        var finished = false
    }

    private let capacity: Int
    private let now: @Sendable () -> Date
    private let state = Mutex(State())

    public init(capacity: Int = LogBuffer.defaultCapacity, now: @escaping @Sendable () -> Date = { Date() }) {
        self.capacity = max(1, capacity)
        self.now = now
    }

    /// Appends a chunk of output; complete lines are recorded and broadcast.
    public func append(_ data: Data, stream: StdioStream) {
        let timestamp = now()
        state.withLock { state in
            var pending = (state.partial[stream] ?? Data()) + data
            while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                var lineData = pending[pending.startIndex..<newline]
                if lineData.last == UInt8(ascii: "\r") { lineData = lineData.dropLast() }
                let line = LogLine(
                    timestamp: timestamp,
                    stream: stream,
                    message: String(decoding: lineData, as: UTF8.self)
                )
                Self.record(line, in: &state, capacity: capacity)
                pending = Data(pending[pending.index(after: newline)...])
            }
            state.partial[stream] = pending
        }
    }

    /// Flushes partial lines and ends every follow stream.
    public func finish() {
        let timestamp = now()
        let followers = state.withLock { state in
            for stream in [StdioStream.stdout, .stderr] {
                if let rest = state.partial[stream], !rest.isEmpty {
                    let line = LogLine(timestamp: timestamp, stream: stream, message: String(decoding: rest, as: UTF8.self))
                    Self.record(line, in: &state, capacity: capacity)
                }
            }
            state.partial = [:]
            state.finished = true
            let followers = Array(state.subscribers.values)
            state.subscribers = [:]
            return followers
        }
        // Finish outside the lock: `onTermination` re-enters the (non-recursive) mutex.
        for continuation in followers { continuation.finish() }
    }

    /// Re-opens the buffer after `finish()` (container restarted). Backlog is kept.
    public func reopen() {
        state.withLock { $0.finished = false }
    }

    /// Buffered lines, then (with `follow`) new lines until `finish()`.
    public func stream(follow: Bool) -> AsyncThrowingStream<LogLine, any Error> {
        let (stream, continuation) = AsyncThrowingStream<LogLine, any Error>.makeStream()
        let id = UUID()
        state.withLock { state in
            for line in state.lines { continuation.yield(line) }
            if follow && !state.finished {
                state.subscribers[id] = continuation
            } else {
                continuation.finish()
            }
        }
        continuation.onTermination = { [weak self] _ in
            _ = self?.state.withLock { $0.subscribers.removeValue(forKey: id) }
        }
        return stream
    }

    private static func record(_ line: LogLine, in state: inout State, capacity: Int) {
        state.lines.append(line)
        if state.lines.count > capacity { state.lines.removeFirst(state.lines.count - capacity) }
        for continuation in state.subscribers.values { continuation.yield(line) }
    }
}
