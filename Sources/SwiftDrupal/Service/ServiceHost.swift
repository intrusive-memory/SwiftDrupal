import Foundation
import Synchronization

// MARK: - Hostname ownership inside the service

/// The service's control over `*.drupal` resolution.
public protocol ServiceHostnameController: Sendable {
    /// Points `hostname` at `ip`. When the resolver strategy cannot be verified,
    /// the report asks the CLI to write the `/etc/hosts` fallback itself.
    func activate(hostname: String, ip: String) async throws -> HostnameActivationReport
    func deactivate(hostname: String) async
    /// Stops the DNS responder. Called last during service shutdown.
    func shutdown()
}

/// Stand-in fallback used inside the service: the hosts-file write needs
/// privileges a LaunchAgent does not have, so "activating" it only marks that
/// the CLI must do the write (`HostnameActivationReport.hostsFileWriteRequired`).
public struct ClientDeferredHostsFileStrategy: HostnameStrategy {
    public var kind: HostnameStrategyKind { .hostsFile }
    public init() {}
    public func activate(hostname: String, ip: String) async throws {}
    public func deactivate(hostname: String) async throws {}
    public func currentAddress(for hostname: String) -> IPv4? { nil }
}

/// Live controller: the service-owned `LocalResolverStrategy` (and its
/// responder), verified through the system resolver, with the hosts-file
/// fallback deferred to the CLI.
public struct ResolverHostnameController: ServiceHostnameController {
    public let strategy: LocalResolverStrategy
    public let coordinator: HostnameResolutionCoordinator

    public init(strategy: LocalResolverStrategy, verifier: any HostnameResolverVerifier) {
        self.strategy = strategy
        self.coordinator = HostnameResolutionCoordinator(
            primary: strategy, fallback: ClientDeferredHostsFileStrategy(), verifier: verifier)
    }

    public func activate(hostname: String, ip: String) async throws -> HostnameActivationReport {
        let activation = try await coordinator.activate(hostname: hostname, ip: ip)
        return HostnameActivationReport(
            hostname: hostname, ip: ip, strategy: activation.kind,
            hostsFileWriteRequired: activation.usedFallback, warnings: activation.warnings)
    }

    public func deactivate(hostname: String) async {
        await coordinator.deactivate(hostname: hostname)
    }

    public func shutdown() {
        strategy.shutdown()
    }
}

/// `PrivilegedFileWriter` for the service process: reads work, writes refuse.
/// The one-time `/etc/resolver` registration belongs to `drupal service install`.
public struct ReadOnlyPrivilegedFileWriter: PrivilegedFileWriter {
    public init() {}

    public func writeFile(_ contents: String, atPath path: String) throws {
        throw HostnameError.privilegedWriteFailed(
            "\(path) is not writable from the drupal service; run `drupal service install`")
    }

    public func removeFile(atPath path: String) throws {
        throw HostnameError.privilegedWriteFailed(
            "\(path) is not writable from the drupal service; run `drupal service uninstall`")
    }
}

// MARK: - Host

/// Everything the long-lived service owns: the single `ContainerService` and
/// the hostname controller. Transport-independent, so the socket server and
/// tests drive the same logic.
///
/// Not an actor: container calls must not queue behind each other (a long
/// image pull would block `inspect`). Only bookkeeping is locked.
public final class ServiceHost: Sendable {
    public let containers: any ContainerService
    public let hostnames: any ServiceHostnameController
    private let log: @Sendable (String) -> Void

    private struct State {
        /// Specs of containers created through this service, in creation order.
        var specs: [(id: String, spec: ContainerSpec)] = []
        var shuttingDown = false
    }

    private let state = Mutex(State())

    public init(
        containers: any ContainerService,
        hostnames: any ServiceHostnameController,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.containers = containers
        self.hostnames = hostnames
        self.log = log
    }

    private func spec(for id: String) -> ContainerSpec? {
        state.withLock { $0.specs.first(where: { $0.id == id })?.spec }
    }

    /// Container ids created through this service, in creation order.
    public var trackedContainerIDs: [String] { state.withLock { $0.specs.map(\.id) } }

    /// Handles a unary request. Streaming requests (`exec`, `logs`) are handled
    /// by the connection layer against `containers` directly.
    public func respond(to request: ServiceRequest) async -> ServiceResponse {
        do {
            return try await perform(request)
        } catch {
            return .failure(ServiceFailure(error))
        }
    }

    private func perform(_ request: ServiceRequest) async throws -> ServiceResponse {
        if state.withLock({ $0.shuttingDown }), request != .ping {
            throw DrupalError.serviceUnavailable("the drupal service is shutting down")
        }
        switch request {
        case .ping:
            return .pong(info: ServiceInfo(pid: ProcessInfo.processInfo.processIdentifier))
        case .pullImage(let reference):
            try await containers.pullImage(reference)
            return .ok
        case .create(let spec):
            try await containers.create(spec)
            state.withLock { state in
                if let index = state.specs.firstIndex(where: { $0.id == spec.id }) {
                    state.specs[index].spec = spec
                } else {
                    state.specs.append((spec.id, spec))
                }
            }
            return .ok
        case .start(let id):
            try await containers.start(id: id)
            return .started(hostnameActivation: try await activateHostnameIfWeb(id: id))
        case .stop(let id):
            try await containers.stop(id: id)
            if let spec = spec(for: id), spec.role == .web { await hostnames.deactivate(hostname: spec.hostname) }
            return .ok
        case .delete(let id):
            try await containers.delete(id: id)
            let removed = state.withLock { state -> ContainerSpec? in
                guard let index = state.specs.firstIndex(where: { $0.id == id }) else { return nil }
                return state.specs.remove(at: index).spec
            }
            if let removed, removed.role == .web { await hostnames.deactivate(hostname: removed.hostname) }
            return .ok
        case .inspect(let id):
            return .status(try await containers.inspect(id: id))
        case .activateHostname(let hostname, let ip):
            return .hostnameActivation(try await hostnames.activate(hostname: hostname, ip: ip))
        case .deactivateHostname(let hostname):
            await hostnames.deactivate(hostname: hostname)
            return .ok
        case .exec, .logs:
            throw ServiceFailure(kind: .protocolError, message: "streaming request sent to the unary handler")
        }
    }

    /// Sortie 3's open item: after a web container starts, the service reads
    /// its IP and updates the responder record itself.
    private func activateHostnameIfWeb(id: String) async throws -> HostnameActivationReport? {
        guard let spec = spec(for: id), spec.role == .web else { return nil }
        let status = try await containers.inspect(id: id)
        guard let ip = status.ipAddress else {
            log("web container \(id) started without an IP address; hostname \(spec.hostname) not activated")
            return nil
        }
        let report = try await hostnames.activate(hostname: spec.hostname, ip: ip)
        for warning in report.warnings { log(warning) }
        return report
    }

    /// Graceful shutdown: refuse new work, stop every tracked container (in
    /// reverse creation order), then stop the DNS responder. Errors are logged,
    /// never thrown, so the responder always stops.
    public func shutdown() async {
        let ids = state.withLock { state -> [String] in
            state.shuttingDown = true
            return state.specs.map(\.id)
        }
        for id in ids.reversed() {
            do {
                try await containers.stop(id: id)
            } catch {
                log("failed to stop \(id) during shutdown: \(error)")
            }
        }
        hostnames.shutdown()
    }
}
