import Foundation

/// The host-service surface the lifecycle commands need: every
/// `ContainerService` call plus the service-level calls that carry hostname
/// warnings and cleanup.
///
/// `ServiceClientContainerService` is the only live conformance (OQ-4); tests
/// inject doubles. There is deliberately no in-process implementation.
public protocol LifecycleServiceClient: ContainerService {
    /// Identity of the running service; throws `serviceUnavailable` when unreachable.
    func ping() async throws -> ServiceInfo
    /// Starts a container and returns hostname activation and fallback warnings.
    func startContainer(id: String) async throws -> ServiceStartOutcome
    /// Removes the hostname from the service responder and any CLI-owned `/etc/hosts` line.
    func deactivateHostname(hostname: String) async throws
}

extension ServiceClientContainerService: LifecycleServiceClient {}

/// Everything a lifecycle command touches outside its own arguments, injectable
/// through `LifecycleEnvironment.current` so tests never reach a real service
/// socket, real containers, or a privileged file writer.
public struct LifecycleEnvironment: Sendable {
    /// Builds the service client. Only called by commands that need the service
    /// (`init`, `config`, and `validate` never call it).
    public var makeClient: @Sendable () -> any LifecycleServiceClient
    /// Read-only view of the `/etc/hosts` fallback, used by `status`.
    public var hostsFile: any HostnameStrategy
    public var outputResolver: OutputFormatResolver
    /// Receives each complete stdout document (a trailing newline is added by the sink).
    public var writeOutput: @Sendable (String) -> Void
    public var currentDirectory: @Sendable () -> URL
    /// Root for per-project runtime state (database data directories).
    public var stateRoot: URL
    public var healthChecker: HealthChecker
    public var healthProbe: HealthProbe

    public init(
        makeClient: @escaping @Sendable () -> any LifecycleServiceClient,
        hostsFile: any HostnameStrategy,
        outputResolver: OutputFormatResolver = .live,
        writeOutput: @escaping @Sendable (String) -> Void = LifecycleEnvironment.standardOutput,
        currentDirectory: @escaping @Sendable () -> URL = { URL.currentDirectory() },
        stateRoot: URL = DatabaseContainerSpecBuilder.defaultStateRoot,
        healthChecker: HealthChecker = HealthChecker(),
        healthProbe: HealthProbe = .ddevHealthcheck
    ) {
        self.makeClient = makeClient
        self.hostsFile = hostsFile
        self.outputResolver = outputResolver
        self.writeOutput = writeOutput
        self.currentDirectory = currentDirectory
        self.stateRoot = stateRoot
        self.healthChecker = healthChecker
        self.healthProbe = healthProbe
    }

    public static let standardOutput: @Sendable (String) -> Void = { text in
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }

    /// The live environment. `hostsWriter` performs the CLI-side privileged
    /// `/etc/hosts` fallback write; it is a parameter so no test ever builds the
    /// `AdministratorFileWriter` path.
    public static func live(hostsWriter: any PrivilegedFileWriter = AdministratorFileWriter()) -> LifecycleEnvironment {
        let hostsFallback = HostsFileStrategy(writer: hostsWriter)
        return LifecycleEnvironment(
            makeClient: {
                ServiceClientContainerService(
                    socketPath: ServicePaths.current().socketPath, hostsFallback: hostsFallback)
            },
            hostsFile: hostsFallback
        )
    }

    /// The environment commands run in. Tests bind it with `$current.withValue`.
    @TaskLocal public static var current: LifecycleEnvironment = .live()
}

// MARK: - Output

enum LifecycleOutput {
    static func json<Value: Encodable>(_ value: Value) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    /// Writes `value` as JSON, or `text()` in text mode.
    static func emit<Value: Encodable>(
        _ value: Value, options: OutputOptions, environment: LifecycleEnvironment, text: () -> String
    ) throws {
        switch options.format(using: environment.outputResolver) {
        case .json: environment.writeOutput(try json(value))
        case .text: environment.writeOutput(text())
        }
    }
}
