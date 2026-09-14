import Darwin
import Foundation
import Synchronization

/// Accepts connections on the service socket and dispatches each one to the
/// `ServiceHost`.
public final class ServiceServer: Sendable {
    public let socketPath: String
    public let host: ServiceHost
    private let log: @Sendable (String) -> Void

    private struct State {
        var listener: UnixSocketListener?
        var acceptLoopExited: DispatchSemaphore?
        var connections: [UUID: SocketConnection] = [:]
    }

    private let state = Mutex(State())

    public init(socketPath: String, host: ServiceHost, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.socketPath = socketPath
        self.host = host
        self.log = log
    }

    public var isListening: Bool { state.withLock { $0.listener != nil } }

    /// Binds the socket (mode 0600) and starts accepting. Idempotent.
    public func start() throws {
        guard !isListening else { return }
        let listener = try UnixSocketListener(path: socketPath)
        let exited = DispatchSemaphore(value: 0)
        state.withLock {
            $0.listener = listener
            $0.acceptLoopExited = exited
        }
        let thread = Thread { [self] in
            self.acceptLoop(listener)
            exited.signal()
        }
        thread.name = "SwiftDrupal.ServiceServer.accept"
        thread.start()
    }

    /// Stops accepting, removes the socket file, and cancels open connections.
    /// Blocks until the accept loop exits. Idempotent.
    public func stop() {
        let (listener, exited, connections) = state.withLock { state in
            defer {
                state.listener = nil
                state.acceptLoopExited = nil
                state.connections = [:]
            }
            return (state.listener, state.acceptLoopExited, Array(state.connections.values))
        }
        // Let the accept loop observe `listener == nil` before the descriptor closes.
        exited?.wait()
        listener?.close()
        for connection in connections { connection.cancel() }
    }

    private func acceptLoop(_ listener: UnixSocketListener) {
        while state.withLock({ $0.listener === listener }) {
            do {
                guard let connection = try listener.accept() else { continue }
                let id = UUID()
                state.withLock { $0.connections[id] = connection }
                Task.detached { [self] in
                    await ServiceConnectionHandler(connection: connection, host: host, log: log).run()
                    _ = state.withLock { $0.connections.removeValue(forKey: id) }
                }
            } catch {
                if state.withLock({ $0.listener === listener }) { log("accept failed: \(error)") }
                return
            }
        }
    }
}

/// Serves one connection: one request, then its response frame(s).
struct ServiceConnectionHandler: Sendable {
    let connection: SocketConnection
    let host: ServiceHost
    let log: @Sendable (String) -> Void

    func run() async {
        defer { connection.cancel() }
        let request: ServiceRequest
        do {
            guard let received = try await BlockingIO.run({ [connection] in try connection.receive(ServiceRequest.self) })
            else { return }
            request = received
        } catch {
            try? connection.send(ServiceResponse.failure(ServiceFailure(error)))
            return
        }

        switch request {
        case .logs(let id, let follow):
            await streamLogs(id: id, follow: follow)
        case .exec(let id, let payload):
            await runExec(id: id, payload: payload)
        default:
            let response = await host.respond(to: request)
            try? connection.send(response)
        }
    }

    private func streamLogs(id: String, follow: Bool) async {
        let stream: AsyncThrowingStream<LogLine, any Error>
        do {
            stream = try await host.containers.logs(id: id, follow: follow)
        } catch {
            try? connection.send(ServiceResponse.failure(ServiceFailure(error)))
            return
        }
        guard (try? connection.send(ServiceResponse.streamOpened)) != nil else { return }

        let connection = self.connection
        let forward = Task {
            do {
                for try await line in stream {
                    try connection.send(ServiceResponse.logLine(line))
                }
                try connection.send(ServiceResponse.streamEnded)
            } catch is CancellationError {
            } catch {
                try? connection.send(ServiceResponse.failure(ServiceFailure(error)))
            }
        }
        // The client closing its end cancels the stream (a follow stream would
        // otherwise wait for the container to stop).
        let watcher = Task.detached {
            _ = try? await BlockingIO.run { try connection.receive(ServiceStreamInput.self) }
            forward.cancel()
        }
        await forward.value
        connection.cancel()
        _ = await watcher.value
    }

    private func runExec(id: String, payload: ExecRequestPayload) async {
        let connection = self.connection
        let (stdin, stdinContinuation) = AsyncStream<Data>.makeStream()

        let execTask = Task { () -> ServiceResponse in
            let request = ExecRequest(
                arguments: payload.arguments,
                environment: payload.environment,
                workingDirectory: payload.workingDirectory,
                terminal: payload.terminal,
                stdin: payload.hasStdin ? stdin : nil,
                output: { stream, data in
                    try? connection.send(ServiceResponse.output(stream: stream, data: data))
                })
            do {
                return .exited(try await host.containers.exec(id: id, request))
            } catch {
                return .failure(ServiceFailure(error))
            }
        }
        // Reads stdin frames; end of connection closes stdin and cancels the exec.
        let reader = Task.detached {
            var stdinOpen = true
            while true {
                let input = try? await BlockingIO.run { try connection.receive(ServiceStreamInput.self) }
                switch input {
                case .stdin(let data)?:
                    if stdinOpen { stdinContinuation.yield(data) }
                case .stdinClosed?:
                    stdinOpen = false
                    stdinContinuation.finish()
                case nil:
                    stdinContinuation.finish()
                    execTask.cancel()
                    return
                }
            }
        }
        let response = await execTask.value
        try? connection.send(response)
        stdinContinuation.finish()
        connection.cancel()
        _ = await reader.value
    }
}

/// The `service run` lifecycle: listen, wait for a termination trigger, then
/// shut down in order — stop accepting, stop containers, stop the responder.
public struct ServiceRunner: Sendable {
    public let server: ServiceServer

    public init(server: ServiceServer) {
        self.server = server
    }

    /// Runs until `untilTerminated` returns, then shuts down. Returns normally
    /// (exit status 0) after a clean shutdown.
    public func run(untilTerminated: @Sendable () async -> Void) async throws {
        try server.start()
        await untilTerminated()
        server.stop()
        await server.host.shutdown()
    }
}

/// Suspends until the process receives SIGTERM or SIGINT.
public enum TerminationSignal {
    public static func wait(signals: [Int32] = [SIGTERM, SIGINT]) async -> Int32 {
        await withCheckedContinuation { continuation in
            let resumed = Mutex(false)
            let queue = DispatchQueue(label: "SwiftDrupal.service.signals")
            // Retained until the process exits; `service run` waits exactly once.
            let sources = Mutex<[DispatchSourceSignal]>([])
            for signalNumber in signals {
                Darwin.signal(signalNumber, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: queue)
                source.setEventHandler {
                    let first = resumed.withLock { done in
                        defer { done = true }
                        return !done
                    }
                    if first { continuation.resume(returning: signalNumber) }
                }
                source.resume()
                sources.withLock { $0.append(source) }
            }
            TerminationSignal.retained.withLock { $0.append(contentsOf: sources.withLock { $0 }) }
        }
    }

    private static let retained = Mutex<[DispatchSourceSignal]>([])
}
