import Foundation

/// Wall-clock access `LogMerger` needs: the current time (to stamp arrivals
/// and drain the reorder buffer) and a way to wait until a deadline. Injected
/// so tests can advance virtual time instantly instead of sleeping for real
/// (mirrors `HealthCheckClock`/`TestHealthCheckClock` in
/// Container/HealthCheck.swift).
public protocol LogMergeClock: Sendable {
    func now() -> Date
    /// Suspends until `deadline`. Returns immediately if `deadline` is
    /// already in the past.
    func sleep(until deadline: Date) async throws
}

/// The live clock: real time, real (cancellable) sleeps.
public struct SystemLogMergeClock: LogMergeClock, Sendable {
    public init() {}

    public func now() -> Date { Date() }

    public func sleep(until deadline: Date) async throws {
        let interval = deadline.timeIntervalSinceNow
        guard interval > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64((interval * 1_000_000_000).rounded(.up)))
    }
}
