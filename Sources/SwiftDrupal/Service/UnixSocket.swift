import Darwin
import Foundation
import Synchronization

/// Errors from the Unix-domain socket layer.
public enum UnixSocketError: Error, Equatable, Sendable, CustomStringConvertible {
    case pathTooLong(String)
    case systemCall(name: String, errno: Int32)
    case addressInUse(String)

    public var description: String {
        switch self {
        case .pathTooLong(let path): "socket path is longer than \(UnixSocket.maximumPathLength) bytes: \(path)"
        case .systemCall(let name, let code): "\(name)(): \(String(cString: strerror(code)))"
        case .addressInUse(let path): "another drupal service is already listening on \(path)"
        }
    }
}

public enum UnixSocket {
    /// Usable bytes in `sockaddr_un.sun_path` (104 on Darwin, including the NUL).
    public static let maximumPathLength = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1

    static func makeAddress(_ path: String) throws -> sockaddr_un {
        let bytes = Array(path.utf8)
        guard bytes.count <= maximumPathLength else { throw UnixSocketError.pathTooLong(path) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.initializeMemory(as: UInt8.self, repeating: 0)
            raw.copyBytes(from: bytes)
        }
        return address
    }

    static func makeSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UnixSocketError.systemCall(name: "socket", errno: errno) }
        var on: Int32 = 1
        // A peer that disappears must produce EPIPE, not kill the process.
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    /// Connects to a listening socket. Blocking (returns immediately for local sockets).
    public static func connect(path: String) throws -> SocketConnection {
        var address = try makeAddress(path)
        let fd = try makeSocket()
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(fd)
            throw UnixSocketError.systemCall(name: "connect", errno: code)
        }
        return SocketConnection(fd: fd)
    }
}

/// One connected stream socket carrying `ServiceFraming` frames.
///
/// Sends are serialized; a single reader at a time is expected. `cancel()`
/// wakes any blocked read or write; the descriptor closes on deinit, after
/// every in-flight call (which holds a reference) has returned.
public final class SocketConnection: Sendable {
    let fd: Int32
    private let writeLock = Mutex(())
    private let reader = Mutex(ServiceFrameDecoder())

    init(fd: Int32) {
        self.fd = fd
    }

    deinit { Darwin.close(fd) }

    /// Shuts the connection down in both directions, waking blocked readers.
    public func cancel() {
        Darwin.shutdown(fd, SHUT_RDWR)
    }

    /// Frames and writes `message`. Blocking.
    public func send<Message: Encodable>(_ message: Message) throws {
        let frame = try ServiceFraming.encode(message)
        try writeLock.withLock { _ in
            try frame.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw UnixSocketError.systemCall(name: "write", errno: errno)
                    }
                    offset += written
                }
            }
        }
    }

    /// Reads the next message. Returns nil on a clean end of stream between
    /// frames. Blocking.
    public func receive<Message: Decodable & Sendable>(_ type: Message.Type) throws -> Message? {
        try reader.withLock { decoder in
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                if let message = try decoder.next(type) { return message }
                let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw UnixSocketError.systemCall(name: "read", errno: errno)
                }
                if count == 0 {
                    guard decoder.bufferedByteCount == 0 else {
                        throw ServiceFailure(kind: .protocolError, message: "connection closed mid-frame")
                    }
                    return nil
                }
                decoder.append(Data(chunk[0..<count]))
            }
        }
    }
}

/// A listening Unix-domain socket (mode 0600).
public final class UnixSocketListener: Sendable {
    public let path: String
    private let fd: Int32
    private let closed = Mutex(false)

    /// Binds `path`. A stale socket file left by a crashed service is replaced;
    /// a live one (something accepts connections) throws `.addressInUse`.
    public init(path: String) throws {
        var address = try UnixSocket.makeAddress(path)
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        if FileManager.default.fileExists(atPath: path) {
            if (try? UnixSocket.connect(path: path)) != nil { throw UnixSocketError.addressInUse(path) }
            unlink(path)
        }

        let fd = try UnixSocket.makeSocket()
        // No umask juggling (it is process-global); the parent directory is
        // created 0700 and the node is chmod-ed to 0600 right after bind.
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            Darwin.close(fd)
            throw UnixSocketError.systemCall(name: "bind", errno: code)
        }
        chmod(path, 0o600)
        guard listen(fd, 64) == 0 else {
            let code = errno
            Darwin.close(fd)
            unlink(path)
            throw UnixSocketError.systemCall(name: "listen", errno: code)
        }
        self.path = path
        self.fd = fd
    }

    /// Waits up to `timeoutMilliseconds` for a connection. Returns nil on timeout
    /// or after `close()`.
    public func accept(timeoutMilliseconds: Int32 = 200) throws -> SocketConnection? {
        guard !closed.withLock({ $0 }) else { return nil }
        var pollDescriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&pollDescriptor, 1, timeoutMilliseconds)
        if ready < 0 {
            if errno == EINTR { return nil }
            throw UnixSocketError.systemCall(name: "poll", errno: errno)
        }
        guard ready > 0, !closed.withLock({ $0 }) else { return nil }
        let client = Darwin.accept(fd, nil, nil)
        guard client >= 0 else {
            if errno == EINTR || errno == EAGAIN || errno == ECONNABORTED { return nil }
            throw UnixSocketError.systemCall(name: "accept", errno: errno)
        }
        var on: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return SocketConnection(fd: client)
    }

    /// Stops listening and removes the socket file. Idempotent.
    public func close() {
        let first = closed.withLock { wasClosed in
            defer { wasClosed = true }
            return !wasClosed
        }
        guard first else { return }
        Darwin.close(fd)
        unlink(path)
    }

    deinit { close() }
}

/// Runs blocking socket calls off the Swift concurrency pool.
enum BlockingIO {
    // Custom queues are overcommit: a blocked item gets its own thread instead
    // of starving the cooperative pool.
    private static let queue = DispatchQueue(label: "SwiftDrupal.service.io", attributes: .concurrent)

    static func run<Result: Sendable>(_ body: @escaping @Sendable () throws -> Result) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Swift.Result { try body() })
            }
        }
    }
}
