import Foundation

// The boundary between the CLI and containers. Commands only ever talk to a
// `ContainerRuntime`; the Containerization-backed implementation will slot in
// here without touching command code. Until then `UnimplementedRuntime`
// answers every call with `not_implemented` (exit 12).
//
// Contract for implementations:
// - Every method throws `DrupalError` with the matching `ExitStatus`
//   (`platformUnavailable`, `containerStartFailed`, `healthTimeout`,
//   `projectNotRunning`, `containerOperationFailed`).
// - `start`, `stop`, and `delete` are idempotent: already running / already
//   stopped / already gone is success, not an error.
// - The project is the unit: `start` brings up both web and db, `stop` stops
//   both. There is no per-service lifecycle in v1.0.

public enum Service: String, CaseIterable, Codable, Sendable {
    case web
    case db
}

public enum ServiceState: String, Codable, Sendable {
    case running
    case stopped
    /// No container exists for this service (never started, or deleted).
    case absent
}

public struct ServiceStatus: Codable, Sendable, Equatable {
    public var service: Service
    public var state: ServiceState
    public var image: String
    /// The container's dedicated IP while running.
    public var ipAddress: String?

    enum CodingKeys: String, CodingKey {
        case service, state, image
        case ipAddress = "ip_address"
    }

    public init(service: Service, state: ServiceState, image: String, ipAddress: String? = nil) {
        self.service = service
        self.state = state
        self.image = image
        self.ipAddress = ipAddress
    }
}

public struct ProjectStatus: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        case running
        case stopped
        /// Some services running, some not.
        case partial
        case absent
    }

    public var state: State
    public var services: [ServiceStatus]

    public init(state: State, services: [ServiceStatus]) {
        self.state = state
        self.services = services
    }
}

public struct StartOptions: Sendable, Equatable {
    /// How long to wait for web and db health checks before `healthTimeout`.
    public var healthTimeout: Duration

    public init(healthTimeout: Duration = .seconds(120)) {
        self.healthTimeout = healthTimeout
    }
}

public struct ExecRequest: Sendable, Equatable {
    public enum Input: Sendable, Equatable {
        case none
        /// The caller's own stdin (interactive shells, `import-db` from a pipe).
        case inherit
        case file(URL)
    }

    public enum Output: Sendable, Equatable {
        /// Stream straight to the caller's stdout/stderr.
        case inherit
        /// Buffer and return in `ExecResult` (JSON mode).
        case capture
        case file(URL)
    }

    public var service: Service
    /// argv; not passed through a shell unless the caller wraps it in one.
    public var command: [String]
    public var workingDirectory: String?
    public var environment: [String: String]
    /// Allocate a pseudo-terminal (only for `ssh` / interactive exec).
    public var tty: Bool
    public var stdin: Input
    public var stdout: Output
    public var stderr: Output

    public init(
        service: Service,
        command: [String],
        workingDirectory: String? = nil,
        environment: [String: String] = [:],
        tty: Bool = false,
        stdin: Input = .none,
        stdout: Output = .inherit,
        stderr: Output = .inherit
    ) {
        self.service = service
        self.command = command
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.tty = tty
        self.stdin = stdin
        self.stdout = stdout
        self.stderr = stderr
    }
}

public struct ExecResult: Sendable, Equatable {
    public var exitCode: Int32
    /// Present only for `.capture` outputs.
    public var stdout: Data?
    public var stderr: Data?

    public init(exitCode: Int32, stdout: Data? = nil, stderr: Data? = nil) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public struct LogRequest: Sendable, Equatable {
    public var services: [Service]
    public var follow: Bool
    /// Last N lines per service before following; nil = everything.
    public var tail: Int?

    public init(services: [Service] = Service.allCases, follow: Bool = false, tail: Int? = nil) {
        self.services = services
        self.follow = follow
        self.tail = tail
    }
}

/// One log line, exactly the JSON record `drupal logs --json` prints.
public struct LogEntry: Codable, Sendable, Equatable {
    public enum Stream: String, Codable, Sendable {
        case stdout
        case stderr
    }

    public var timestamp: Date
    public var service: Service
    public var stream: Stream
    public var message: String

    public init(timestamp: Date, service: Service, stream: Stream, message: String) {
        self.timestamp = timestamp
        self.service = service
        self.stream = stream
        self.message = message
    }
}

public protocol ContainerRuntime: Sendable {
    /// Creates (pulling images if needed) and starts web and db, then waits
    /// up to `options.healthTimeout` for both to be healthy. Idempotent.
    func start(_ project: ResolvedProject, options: StartOptions) async throws(DrupalError) -> ProjectStatus

    /// Stops both containers, keeping them and the database volume. Idempotent.
    func stop(_ project: ResolvedProject) async throws(DrupalError) -> ProjectStatus

    /// Current state; never throws `projectNotRunning`.
    func status(_ project: ResolvedProject) async throws(DrupalError) -> ProjectStatus

    /// Stops and removes both containers, and the database volume unless
    /// `keepData`. Never touches the project directory. Idempotent.
    func delete(_ project: ResolvedProject, keepData: Bool) async throws(DrupalError)

    /// Runs a process in a running service. A non-zero exit of the process
    /// itself is returned in `ExecResult`, not thrown.
    func exec(_ project: ResolvedProject, _ request: ExecRequest) async throws(DrupalError) -> ExecResult

    /// Log lines from the requested services, merged into one stream in
    /// timestamp order (arrival order once following). Finishes after the
    /// backlog unless `follow`. Terminates by throwing `DrupalError`.
    func logs(_ project: ResolvedProject, _ request: LogRequest) -> AsyncThrowingStream<LogEntry, any Error>
}
