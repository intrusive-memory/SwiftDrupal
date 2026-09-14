import Darwin
import Foundation
import Synchronization

// Abstractions `ExecCommand` and `SSHCommand` use for the local end of a
// streaming exec session: reading stdin, writing stdout/stderr, and putting
// the controlling terminal into raw mode. Each is a protocol with a `Posix`/
// `FileHandle`-backed live implementation and a scriptable test double
// (Tests/SwiftDrupalTests/CLI/ExecSessionTests.swift), so tests never touch a
// real TTY or the process's real stdio.

/// Controls raw-mode on the local controlling terminal. `isInteractiveTTY`
/// says whether there is one to control at all.
public protocol TerminalController: Sendable {
    var isInteractiveTTY: Bool { get }

    /// Switches the terminal to raw mode (no line buffering, no echo, signal
    /// characters passed through as raw bytes). Throws `DrupalError
    /// .platformUnavailable` if the underlying `tcsetattr` call fails.
    func enableRawMode() throws

    /// Restores whatever mode was in effect before `enableRawMode()`. Safe to
    /// call multiple times, or without a prior `enableRawMode()` (a no-op).
    func restore()
}

/// `TerminalController` backed by a real POSIX terminal file descriptor
/// (`STDIN_FILENO` by default).
public final class PosixTerminalController: TerminalController, Sendable {
    private let fileDescriptor: Int32
    public let isInteractiveTTY: Bool
    private let savedAttributes = Mutex<termios?>(nil)

    public init(fileDescriptor: Int32 = STDIN_FILENO) {
        self.fileDescriptor = fileDescriptor
        self.isInteractiveTTY = isatty(fileDescriptor) != 0
    }

    public func enableRawMode() throws {
        var attributes = termios()
        guard tcgetattr(fileDescriptor, &attributes) == 0 else {
            throw DrupalError.platformUnavailable(
                "cannot read terminal attributes: \(String(cString: strerror(errno)))")
        }
        savedAttributes.withLock { $0 = attributes }
        cfmakeraw(&attributes)
        guard tcsetattr(fileDescriptor, TCSANOW, &attributes) == 0 else {
            throw DrupalError.platformUnavailable(
                "cannot set terminal to raw mode: \(String(cString: strerror(errno)))")
        }
    }

    public func restore() {
        savedAttributes.withLock { saved in
            guard var attributes = saved else { return }
            _ = tcsetattr(fileDescriptor, TCSANOW, &attributes)
            saved = nil
        }
    }
}

/// Supplies the bytes forwarded as the remote process's stdin.
public protocol ExecInputSource: Sendable {
    /// A fresh stream of stdin chunks; finishes at EOF.
    func makeStream() -> AsyncStream<Data>
}

/// `ExecInputSource` backed by a real `FileHandle` (`.standardInput` in
/// production). Reads happen off the calling task so `makeStream()` never
/// blocks its caller.
public struct FileHandleInputSource: ExecInputSource {
    public let handle: FileHandle

    public init(handle: FileHandle = .standardInput) {
        self.handle = handle
    }

    public func makeStream() -> AsyncStream<Data> {
        let handle = self.handle
        return AsyncStream { continuation in
            let task = Task.detached {
                while !Task.isCancelled {
                    let data = handle.availableData
                    if data.isEmpty {
                        continuation.finish()
                        return
                    }
                    continuation.yield(data)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Receives stdout/stderr chunks streamed back from the remote process.
public protocol ExecOutputSink: Sendable {
    func write(_ stream: StdioStream, _ data: Data)
}

/// `ExecOutputSink` that writes straight to the process's real stdio.
public struct LiveExecOutputSink: ExecOutputSink {
    public init() {}

    public func write(_ stream: StdioStream, _ data: Data) {
        switch stream {
        case .stdout: FileHandle.standardOutput.write(data)
        case .stderr: FileHandle.standardError.write(data)
        }
    }
}
