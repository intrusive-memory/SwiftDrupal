import Foundation
import Synchronization
@testable import SwiftDrupal

/// In-memory `ContainerService` for tests. Records every call, simulates the
/// lifecycle state machine, and lets tests script inspect states, exec results,
/// log output, and injected failures.
actor MockContainerService: ContainerService {
    enum Call: Equatable, Sendable {
        case pullImage(String)
        case create(String)
        case start(String)
        case stop(String)
        case delete(String)
        case inspect(String)
        case exec(String, [String])
        case logs(String, follow: Bool)
    }

    enum Operation: Hashable, Sendable {
        case pullImage, create, start, stop, delete, inspect, exec, logs
    }

    private(set) var calls: [Call] = []
    private(set) var pulledImages: [String] = []
    private(set) var specs: [String: ContainerSpec] = [:]
    private(set) var execRequests: [(id: String, arguments: [String], environment: [String])] = []
    private var states: [String: ContainerState] = [:]
    private var ipAddresses: [String: String] = [:]
    private var nextHostOctet = 2

    /// Per-id queue of states returned by successive `inspect` calls before
    /// falling back to the simulated state. Lets tests script "created, created, running".
    private var scriptedStates: [String: [ContainerState]] = [:]
    private var failures: [Operation: DrupalError] = [:]
    private var execHandler: @Sendable (String, ExecRequest) async throws -> ExecResult = { _, _ in
        ExecResult(exitCode: 0)
    }
    private var logLines: [String: [LogLine]] = [:]

    init() {}

    // MARK: Scripting

    func failNext(_ operation: Operation, with error: DrupalError) { failures[operation] = error }
    func scriptInspectStates(_ id: String, _ sequence: [ContainerState]) { scriptedStates[id] = sequence }
    func setExecHandler(_ handler: @escaping @Sendable (String, ExecRequest) async throws -> ExecResult) {
        execHandler = handler
    }
    func setLogLines(_ id: String, _ lines: [LogLine]) { logLines[id] = lines }
    /// Places a container directly into `state` without going through create/start.
    func seed(_ spec: ContainerSpec, state: ContainerState) {
        specs[spec.id] = spec
        states[spec.id] = state
    }

    private func consumeFailure(_ operation: Operation) throws {
        if let error = failures.removeValue(forKey: operation) { throw error }
    }

    // MARK: ContainerService

    func pullImage(_ reference: String) async throws {
        calls.append(.pullImage(reference))
        try consumeFailure(.pullImage)
        pulledImages.append(reference)
    }

    func create(_ spec: ContainerSpec) async throws {
        calls.append(.create(spec.id))
        try consumeFailure(.create)
        guard specs[spec.id] == nil else { return }
        specs[spec.id] = spec
        states[spec.id] = .created
    }

    func start(id: String) async throws {
        calls.append(.start(id))
        try consumeFailure(.start)
        guard let state = states[id] else {
            throw DrupalError.containerFailedToStart("unknown container \(id)")
        }
        if state == .running { return }
        states[id] = .running
        if ipAddresses[id] == nil {
            ipAddresses[id] = "192.168.64.\(nextHostOctet)"
            nextHostOctet += 1
        }
    }

    func stop(id: String) async throws {
        calls.append(.stop(id))
        try consumeFailure(.stop)
        if states[id] != nil { states[id] = .stopped }
    }

    func delete(id: String) async throws {
        calls.append(.delete(id))
        try consumeFailure(.delete)
        specs[id] = nil
        states[id] = nil
        ipAddresses[id] = nil
    }

    func inspect(id: String) async throws -> ContainerStatus {
        calls.append(.inspect(id))
        try consumeFailure(.inspect)
        let state: ContainerState
        if var queue = scriptedStates[id], !queue.isEmpty {
            state = queue.removeFirst()
            scriptedStates[id] = queue
        } else {
            state = states[id] ?? .notFound
        }
        guard state != .notFound else { return .notFound(id) }
        return ContainerStatus(
            id: id,
            state: state,
            ipAddress: state == .running ? (ipAddresses[id] ?? "192.168.64.254") : nil,
            imageReference: specs[id]?.imageReference
        )
    }

    func exec(id: String, _ request: ExecRequest) async throws -> ExecResult {
        calls.append(.exec(id, request.arguments))
        try consumeFailure(.exec)
        execRequests.append((id, request.arguments, request.environment))
        return try await execHandler(id, request)
    }

    func logs(id: String, follow: Bool) async throws -> AsyncThrowingStream<LogLine, any Error> {
        calls.append(.logs(id, follow: follow))
        try consumeFailure(.logs)
        let lines = logLines[id] ?? []
        return AsyncThrowingStream { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        }
    }
}

/// Deterministic `HealthCheckClock`: `sleep` advances virtual time instantly.
final class TestHealthCheckClock: HealthCheckClock {
    private let state = Mutex<(now: Duration, sleeps: [Duration])>((.zero, []))

    init() {}

    func now() -> Duration { state.withLock { $0.now } }

    var sleeps: [Duration] { state.withLock { $0.sleeps } }

    /// Advances virtual time without recording a sleep (simulates slow probes).
    func advance(by duration: Duration) {
        state.withLock { $0.now += duration }
    }

    func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        state.withLock {
            $0.now += duration
            $0.sleeps.append(duration)
        }
        await Task.yield()
    }
}

/// Thread-safe counter usable from `@Sendable` closures.
final class Counter: Sendable {
    private let storage = Mutex(0)

    init() {}

    @discardableResult
    func increment() -> Int { storage.withLock { $0 += 1; return $0 } }

    var value: Int { storage.withLock { $0 } }
}
