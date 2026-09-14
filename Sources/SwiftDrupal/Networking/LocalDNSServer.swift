import Darwin
import Foundation
import Synchronization

/// A minimal UDP DNS responder bound to `127.0.0.1` on a non-privileged port.
///
/// All answering logic lives in `DNSQueryHandler`; this type only moves
/// datagrams. It never binds port 53 — `/etc/resolver/drupal` uses the
/// resolver(5) `port` directive to point macOS at `port` instead.
public final class LocalDNSServer: Sendable {
    public static let defaultPort: UInt16 = 1053
    public static let loopbackAddress = "127.0.0.1"

    public let handler: DNSQueryHandler
    public let requestedPort: UInt16

    private struct State {
        var fd: Int32 = -1
        var boundPort: UInt16?
        var running = false
        var loopExited: DispatchSemaphore?
    }

    private let state = Mutex(State())

    /// - Parameter port: The port to bind on `127.0.0.1`. Pass `0` for an
    ///   ephemeral port (tests); read the result from `start()` or `port`.
    public init(handler: DNSQueryHandler, port: UInt16 = LocalDNSServer.defaultPort) {
        self.handler = handler
        self.requestedPort = port
    }

    /// The bound port while running, otherwise `nil`.
    public var port: UInt16? { state.withLock { $0.running ? $0.boundPort : nil } }

    public var isRunning: Bool { state.withLock { $0.running } }

    /// Binds the socket and starts the receive loop. Idempotent: returns the
    /// already-bound port if running.
    @discardableResult
    public func start() throws -> UInt16 {
        if let port = port { return port }

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw HostnameError.responderFailed("socket(): \(Self.errnoString())") }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        // Short receive timeout so the loop can notice `stop()` promptly.
        var timeout = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = requestedPort.bigEndian
        inet_pton(AF_INET, Self.loopbackAddress, &address.sin_addr)

        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let message = Self.errnoString()
            close(fd)
            throw HostnameError.responderFailed(
                "bind(\(Self.loopbackAddress):\(requestedPort)): \(message)")
        }

        var bound = sockaddr_in()
        var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &boundLength) }
        }
        let boundPort = UInt16(bigEndian: bound.sin_port)
        let exited = DispatchSemaphore(value: 0)

        state.withLock {
            $0.fd = fd
            $0.boundPort = boundPort
            $0.running = true
            $0.loopExited = exited
        }

        let thread = Thread { [self] in
            self.receiveLoop(fd: fd)
            close(fd)
            exited.signal()
        }
        thread.name = "SwiftDrupal.LocalDNSServer"
        thread.start()
        return boundPort
    }

    /// Stops the receive loop and closes the socket. Blocks until the port is
    /// released. Idempotent.
    public func stop() {
        let exited: DispatchSemaphore? = state.withLock {
            guard $0.running else { return nil }
            $0.running = false
            let semaphore = $0.loopExited
            $0.fd = -1
            $0.boundPort = nil
            $0.loopExited = nil
            return semaphore
        }
        exited?.wait()
    }

    deinit { stop() }

    private func receiveLoop(fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 1500)
        while state.withLock({ $0.running }) {
            var peer = sockaddr_storage()
            var peerLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let received = buffer.withUnsafeMutableBytes { raw in
                withUnsafeMutablePointer(to: &peer) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(fd, raw.baseAddress, raw.count, 0, $0, &peerLength)
                    }
                }
            }
            guard received > 0 else { continue }  // timeout (EAGAIN) or transient error
            guard let reply = handler.response(to: Array(buffer[0..<received])) else { continue }
            _ = reply.withUnsafeBytes { raw in
                withUnsafePointer(to: &peer) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, raw.baseAddress, raw.count, 0, $0, peerLength)
                    }
                }
            }
        }
    }

    static func errnoString() -> String { String(cString: strerror(errno)) }
}
