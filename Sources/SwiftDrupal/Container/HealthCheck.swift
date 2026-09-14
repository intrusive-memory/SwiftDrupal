import Foundation

/// A readiness test run against a started container.
public struct HealthProbe: Sendable {
    public var name: String
    /// Returns true when the service is ready. Thrown errors count as "not ready yet".
    public var isReady: @Sendable (_ service: any ContainerService, _ id: String) async throws -> Bool

    public init(name: String, isReady: @escaping @Sendable (any ContainerService, String) async throws -> Bool) {
        self.name = name
        self.isReady = isReady
    }

    /// Ready as soon as the container reports `running`.
    public static let running = HealthProbe(name: "running") { _, _ in true }

    /// Ready when `arguments` exits 0 inside the container.
    public static func exec(_ arguments: [String]) -> HealthProbe {
        HealthProbe(name: "exec \(arguments.joined(separator: " "))") { service, id in
            try await service.exec(id: id, ExecRequest(arguments: arguments)).succeeded
        }
    }

    /// DDEV's own container health script, present in both `ddev-webserver` and
    /// `ddev-dbserver` (it backs their Docker HEALTHCHECK).
    public static let ddevHealthcheck = exec(["/healthcheck.sh"])
}

/// Monotonic time source for `HealthChecker`, injectable for tests.
public protocol HealthCheckClock: Sendable {
    /// Elapsed time since an arbitrary, fixed origin.
    func now() -> Duration
    func sleep(for duration: Duration) async throws
}

/// `HealthCheckClock` backed by `ContinuousClock`.
public struct SystemHealthCheckClock: HealthCheckClock {
    private let origin = ContinuousClock.now

    public init() {}

    public func now() -> Duration { origin.duration(to: .now) }

    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

/// Polls a started container until a `HealthProbe` passes.
///
/// Poll interval, timeout, and clock are injectable so tests run instantly.
public struct HealthChecker: Sendable {
    public var timeout: Duration
    public var pollInterval: Duration
    public var clock: any HealthCheckClock

    public static let defaultTimeout: Duration = .seconds(120)
    public static let defaultPollInterval: Duration = .milliseconds(500)

    public init(
        timeout: Duration = HealthChecker.defaultTimeout,
        pollInterval: Duration = HealthChecker.defaultPollInterval,
        clock: any HealthCheckClock = SystemHealthCheckClock()
    ) {
        self.timeout = timeout
        self.pollInterval = pollInterval
        self.clock = clock
    }

    /// Waits until `id` is running and `probe` passes; returns the final status.
    ///
    /// - Throws: `DrupalError.healthCheckTimeout` when `timeout` elapses first;
    ///   `DrupalError.containerFailedToStart` when the container is missing,
    ///   stopped, or errored while waiting (it will never become healthy).
    ///   `CancellationError` if the task is cancelled.
    @discardableResult
    public func waitUntilHealthy(
        service: any ContainerService,
        id: String,
        probe: HealthProbe = .ddevHealthcheck
    ) async throws -> ContainerStatus {
        let deadline = clock.now() + timeout
        var attempts = 0
        var lastObservation = "no probe attempted"

        while true {
            try Task.checkCancellation()
            attempts += 1

            let status = try await service.inspect(id: id)
            switch status.state {
            case .running:
                do {
                    if try await probe.isReady(service, id) {
                        return status
                    }
                    lastObservation = "probe \"\(probe.name)\" not ready"
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    lastObservation = "probe \"\(probe.name)\" failed: \(error)"
                }
            case .created:
                lastObservation = "container not yet running"
            case .notFound, .stopped, .errored:
                let detail = status.message.map { ": \($0)" } ?? ""
                throw DrupalError.containerFailedToStart(
                    "container \(id) is \(status.state.rawValue) while waiting for health\(detail)"
                )
            }

            let now = clock.now()
            if now >= deadline {
                throw DrupalError.healthCheckTimeout(
                    "container \(id) not healthy after \(timeout) (\(attempts) attempts; last: \(lastObservation))"
                )
            }
            let remaining = deadline - now
            try await clock.sleep(for: min(pollInterval, remaining))
        }
    }
}
