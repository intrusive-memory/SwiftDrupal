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

/// Installs an interrupt handler for a streaming command and returns the
/// function that cancels it. Live: `InterruptGuard.install` on SIGINT.
public typealias InterruptGuardInstaller =
    @Sendable (_ cleanup: @escaping @Sendable () -> Void, _ exit: @escaping @Sendable (Int32) -> Void) -> @Sendable () -> Void

/// Everything a command touches outside its own arguments, injectable through
/// `LifecycleEnvironment.current` so tests never reach a real service socket,
/// real containers, a real terminal, or a privileged file writer.
///
/// Despite the name (it was introduced for the Sortie 4 lifecycle commands),
/// every project command reads it: `init`/`config`/`validate`, the lifecycle
/// commands, `import-db`/`export-db`, `exec`/`ssh`, and `logs`.
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
    /// Receives each complete stderr document (a trailing newline is added by the sink).
    /// `export-db` writes its status here when the dump itself goes to stdout.
    public var writeError: @Sendable (String) -> Void
    /// The local terminal `exec`/`ssh` put into raw mode.
    public var makeTerminal: @Sendable () -> any TerminalController
    /// stdin forwarded by `exec`/`ssh`.
    public var execInput: any ExecInputSource
    /// Receives remote stdout/stderr for `exec`/`ssh`.
    public var execOutput: any ExecOutputSink
    public var installInterruptGuard: InterruptGuardInstaller

    public init(
        makeClient: @escaping @Sendable () -> any LifecycleServiceClient,
        hostsFile: any HostnameStrategy,
        outputResolver: OutputFormatResolver = .live,
        writeOutput: @escaping @Sendable (String) -> Void = LifecycleEnvironment.standardOutput,
        currentDirectory: @escaping @Sendable () -> URL = { URL.currentDirectory() },
        stateRoot: URL = DatabaseContainerSpecBuilder.defaultStateRoot,
        healthChecker: HealthChecker = HealthChecker(),
        healthProbe: HealthProbe = .ddevHealthcheck,
        writeError: @escaping @Sendable (String) -> Void = LifecycleEnvironment.standardError,
        makeTerminal: @escaping @Sendable () -> any TerminalController = { PosixTerminalController() },
        execInput: any ExecInputSource = FileHandleInputSource(),
        execOutput: any ExecOutputSink = LiveExecOutputSink(),
        installInterruptGuard: @escaping InterruptGuardInstaller = LifecycleEnvironment.liveInterruptGuard
    ) {
        self.makeClient = makeClient
        self.hostsFile = hostsFile
        self.outputResolver = outputResolver
        self.writeOutput = writeOutput
        self.currentDirectory = currentDirectory
        self.stateRoot = stateRoot
        self.healthChecker = healthChecker
        self.healthProbe = healthProbe
        self.writeError = writeError
        self.makeTerminal = makeTerminal
        self.execInput = execInput
        self.execOutput = execOutput
        self.installInterruptGuard = installInterruptGuard
    }

    public static let standardError: @Sendable (String) -> Void = { text in
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    public static let liveInterruptGuard: InterruptGuardInstaller = { cleanup, exit in
        let token = InterruptGuard.install(cleanup: cleanup, exit: exit)
        return { token.cancel() }
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
