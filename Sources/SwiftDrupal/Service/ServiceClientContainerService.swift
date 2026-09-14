import Foundation

/// Outcome of `ServiceClientContainerService.startContainer(id:)`.
public struct ServiceStartOutcome: Codable, Equatable, Sendable {
    /// Present when the started container is a web container with an IP.
    public var hostnameActivation: HostnameActivationReport?
    /// Warnings to surface in the command's output (e.g. hosts-file fallback).
    public var warnings: [String]

    public init(hostnameActivation: HostnameActivationReport?, warnings: [String]) {
        self.hostnameActivation = hostnameActivation
        self.warnings = warnings
    }
}

/// The `ContainerService` every short-lived `drupal` command uses: forwards each
/// call over the service socket to `drupal service run`, which owns the VMs.
///
/// There is deliberately no in-process fallback (OQ-4): an unreachable socket
/// throws `DrupalError.serviceUnavailable`.
public struct ServiceClientContainerService: ContainerService {
    public let socketPath: String
    /// Performs the privileged `/etc/hosts` fallback write in the CLI process
    /// when the service reports resolver verification failed. `nil` skips the
    /// write (with a warning).
    public let hostsFallback: (any HostnameStrategy)?

    public init(
        socketPath: String = ServicePaths.current().socketPath,
        hostsFallback: (any HostnameStrategy)? = HostsFileStrategy(writer: AdministratorFileWriter())
    ) {
        self.socketPath = socketPath
        self.hostsFallback = hostsFallback
    }

    // MARK: - Transport

    private func connect() async throws -> SocketConnection {
        let path = socketPath
        do {
            return try await BlockingIO.run { try UnixSocket.connect(path: path) }
        } catch {
            throw Self.unavailable(path: path, reason: "\(error)")
        }
    }

    static func unavailable(path: String, reason: String) -> DrupalError {
        .serviceUnavailable(
            "cannot reach the drupal service at \(path) (\(reason)). Run `drupal service install` to install and start it.")
    }

    private func receive(_ connection: SocketConnection) async throws -> ServiceResponse {
        let path = socketPath
        let response: ServiceResponse?
        do {
            response = try await BlockingIO.run { try connection.receive(ServiceResponse.self) }
        } catch let failure as ServiceFailure {
            throw failure
        } catch {
            throw Self.unavailable(path: path, reason: "connection lost: \(error)")
        }
        guard let response else { throw Self.unavailable(path: path, reason: "connection closed by the service") }
        if case .failure(let failure) = response { throw failure.error }
        return response
    }

    private func send(_ request: ServiceRequest, on connection: SocketConnection) async throws {
        let path = socketPath
        do {
            try await BlockingIO.run { try connection.send(request) }
        } catch {
            throw Self.unavailable(path: path, reason: "send failed: \(error)")
        }
    }

    /// One request, one response.
    func call(_ request: ServiceRequest) async throws -> ServiceResponse {
        let connection = try await connect()
        defer { connection.cancel() }
        try await send(request, on: connection)
        return try await receive(connection)
    }

    private func unexpected(_ response: ServiceResponse, for request: String) -> ServiceFailure {
        ServiceFailure(kind: .protocolError, message: "unexpected response to \(request): \(response)")
    }

    private func expectOK(_ request: ServiceRequest, name: String) async throws {
        let response = try await call(request)
        guard response == .ok else { throw unexpected(response, for: name) }
    }

    // MARK: - Service-level calls

    /// Identity of the running service; throws `serviceUnavailable` when unreachable.
    public func ping() async throws -> ServiceInfo {
        let response = try await call(.ping)
        guard case .pong(let info) = response else { throw unexpected(response, for: "ping") }
        return info
    }

    /// Starts a container. For a web container the service activates its
    /// hostname; if resolver verification failed, this process writes the
    /// `/etc/hosts` fallback and the warning is returned.
    public func startContainer(id: String) async throws -> ServiceStartOutcome {
        let response = try await call(.start(id: id))
        guard case .started(let report) = response else { throw unexpected(response, for: "start") }
        guard let report else { return ServiceStartOutcome(hostnameActivation: nil, warnings: []) }
        let warnings = try await applyHostsFallback(report)
        return ServiceStartOutcome(hostnameActivation: report, warnings: warnings)
    }

    /// Points `hostname` at `ip` through the service, applying the CLI-side
    /// hosts-file fallback when required. Returns the report and all warnings.
    public func activateHostname(hostname: String, ip: String) async throws -> ServiceStartOutcome {
        let response = try await call(.activateHostname(hostname: hostname, ip: ip))
        guard case .hostnameActivation(let report) = response else {
            throw unexpected(response, for: "activateHostname")
        }
        let warnings = try await applyHostsFallback(report)
        return ServiceStartOutcome(hostnameActivation: report, warnings: warnings)
    }

    /// Removes `hostname` from the service responder and any CLI-owned hosts line.
    public func deactivateHostname(hostname: String) async throws {
        try await expectOK(.deactivateHostname(hostname: hostname), name: "deactivateHostname")
        try await hostsFallback?.deactivate(hostname: hostname)
    }

    private func applyHostsFallback(_ report: HostnameActivationReport) async throws -> [String] {
        var warnings = report.warnings
        if report.hostsFileWriteRequired {
            if let hostsFallback {
                try await hostsFallback.activate(hostname: report.hostname, ip: report.ip)
            } else {
                warnings.append("Warning: /etc/hosts fallback for \(report.hostname) was required but not written.")
            }
        } else {
            // A line left by an earlier fallback would shadow the resolver.
            // `HostsFileStrategy` skips the privileged write when no line exists.
            try? await hostsFallback?.deactivate(hostname: report.hostname)
        }
        return warnings
    }

    // MARK: - ContainerService

    public func pullImage(_ reference: String) async throws {
        try await expectOK(.pullImage(reference: reference), name: "pullImage")
    }

    public func create(_ spec: ContainerSpec) async throws {
        try await expectOK(.create(spec: spec), name: "create")
    }

    /// Protocol conformance; hostname warnings are dropped. Commands that need
    /// them (Sortie 4 `start`) call `startContainer(id:)`.
    public func start(id: String) async throws {
        _ = try await startContainer(id: id)
    }

    public func stop(id: String) async throws {
        try await expectOK(.stop(id: id), name: "stop")
    }

    public func delete(id: String) async throws {
        try await expectOK(.delete(id: id), name: "delete")
    }

    public func inspect(id: String) async throws -> ContainerStatus {
        let response = try await call(.inspect(id: id))
        guard case .status(let status) = response else { throw unexpected(response, for: "inspect") }
        return status
    }

    public func exec(id: String, _ request: ExecRequest) async throws -> ExecResult {
        let connection = try await connect()
        defer { connection.cancel() }
        try await send(.exec(id: id, request: ExecRequestPayload(request)), on: connection)

        let stdinTask = request.stdin.map { stdin in
            Task.detached {
                for await chunk in stdin {
                    guard (try? await BlockingIO.run({ try connection.send(ServiceStreamInput.stdin(data: chunk)) }))
                        != nil
                    else { return }
                }
                _ = try? await BlockingIO.run { try connection.send(ServiceStreamInput.stdinClosed) }
            }
        }
        defer { stdinTask?.cancel() }

        return try await withTaskCancellationHandler {
            while true {
                let response = try await receive(connection)
                switch response {
                case .output(let stream, let data):
                    request.output?(stream, data)
                case .exited(let result):
                    return result
                default:
                    throw unexpected(response, for: "exec")
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }

    public func logs(id: String, follow: Bool) async throws -> AsyncThrowingStream<LogLine, any Error> {
        let connection = try await connect()
        try await send(.logs(id: id, follow: follow), on: connection)
        let opened: ServiceResponse
        do {
            opened = try await receive(connection)
        } catch {
            connection.cancel()
            throw error
        }
        guard opened == .streamOpened else {
            connection.cancel()
            throw unexpected(opened, for: "logs")
        }

        let (stream, continuation) = AsyncThrowingStream<LogLine, any Error>.makeStream()
        let reader = Task.detached { [self] in
            do {
                while true {
                    let response = try await receive(connection)
                    switch response {
                    case .logLine(let line):
                        continuation.yield(line)
                    case .streamEnded:
                        continuation.finish()
                        return
                    default:
                        continuation.finish(throwing: unexpected(response, for: "logs"))
                        return
                    }
                }
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in
            reader.cancel()
            connection.cancel()
        }
        return stream
    }
}
