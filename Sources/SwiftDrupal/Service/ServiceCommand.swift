import ArgumentParser
import Foundation

/// `drupal service …`: the launchd-managed host process and its management.
public struct ServiceCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "service",
        abstract: "Manage the background service that owns project containers and *.drupal DNS.",
        subcommands: [
            ServiceRunCommand.self, ServiceInstallCommand.self, ServiceUninstallCommand.self,
            ServiceStatusCommand.self,
        ]
    )

    public init() {}
}

func writeJSON<Value: Encodable>(_ value: Value) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    FileHandle.standardOutput.write(try encoder.encode(value))
    FileHandle.standardOutput.write(Data("\n".utf8))
}

func serviceLog(_ message: String) {
    let stamp = Date().formatted(.iso8601)
    FileHandle.standardError.write(Data("[\(stamp)] drupal service: \(message)\n".utf8))
}

/// The long-lived host process run by launchd. The ONLY code path that
/// constructs `LiveContainerService` and `LocalDNSServer` (OQ-4).
public struct ServiceRunCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run the host service in the foreground (launchd runs this; not for direct use).",
        shouldDisplay: false
    )

    @Option(help: "UDP port of the *.drupal DNS responder on 127.0.0.1.")
    public var dnsPort: UInt16 = LocalDNSServer.defaultPort

    /// Reserved name the responder always answers (127.0.0.1) for health probes.
    public static let probeHostname = "probe.\(ProjectNaming.hostnameSuffix)"

    public init() {}

    public func run() async throws {
        let paths = ServicePaths.current()

        let store = DNSRecordStore()
        store.set(IPv4(octets: (127, 0, 0, 1)), for: Self.probeHostname)
        let responder = LocalDNSServer(handler: DNSQueryHandler(store: store), port: dnsPort)
        let boundPort = try responder.start()

        let strategy = LocalResolverStrategy(
            server: responder,
            registrar: ResolverFileRegistrar(writer: ReadOnlyPrivilegedFileWriter()))
        let host = ServiceHost(
            containers: LiveContainerService(),
            hostnames: ResolverHostnameController(strategy: strategy, verifier: SystemResolverVerifier()),
            log: serviceLog)
        let server = ServiceServer(socketPath: paths.socketPath, host: host, log: serviceLog)

        serviceLog("listening on \(paths.socketPath); DNS responder on \(LocalDNSServer.loopbackAddress):\(boundPort)")
        do {
            try await ServiceRunner(server: server).run {
                let signal = await TerminationSignal.wait()
                serviceLog("received signal \(signal); stopping containers, then the DNS responder")
            }
        } catch {
            responder.stop()
            throw error
        }
        serviceLog("stopped")
    }
}

public struct ServiceInstallCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Install and start the per-user LaunchAgent, and register /etc/resolver/drupal (prompts for admin rights once)."
    )

    @OptionGroup public var output: OutputOptions

    @Option(help: "Absolute path of the drupal binary launchd should run (defaults to this binary).")
    public var executablePath: String?

    public init() {}

    public func run() async throws {
        let installer = ServiceInstaller(
            paths: .current(), executablePath: executablePath ?? ServiceInstaller.currentExecutablePath())
        let report = try installer.install()
        switch output.format() {
        case .json:
            try writeJSON(report)
        case .text:
            for warning in report.warnings { print(warning) }
            print("Installed \(report.label) running \(report.executablePath) service run")
            print("LaunchAgent: \(report.plistPath)")
            print("Socket: \(report.socketPath)")
        }
    }
}

public struct ServiceUninstallCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "uninstall",
        abstract: "Stop and remove the LaunchAgent and the /etc/resolver/drupal registration."
    )

    @OptionGroup public var output: OutputOptions

    public init() {}

    public func run() async throws {
        let installer = ServiceInstaller(paths: .current(), executablePath: ServiceInstaller.currentExecutablePath())
        let report = try installer.uninstall()
        switch output.format() {
        case .json: try writeJSON(report)
        case .text: print("Uninstalled \(report.label)")
        }
    }
}

public struct ServiceStatusCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Report whether the LaunchAgent is installed and loaded and the service socket is reachable."
    )

    @OptionGroup public var output: OutputOptions

    public init() {}

    public func run() async throws {
        let installer = ServiceInstaller(
            paths: .current(), executablePath: ServiceInstaller.currentExecutablePath(),
            registrar: ResolverFileRegistrar(writer: ReadOnlyPrivilegedFileWriter()))
        let report = await installer.status()
        switch output.format() {
        case .json:
            try writeJSON(report)
        case .text:
            print("Label: \(report.label)")
            print("LaunchAgent installed: \(report.plistInstalled) (\(report.plistPath))")
            print("Agent loaded: \(report.agentLoaded)")
            print("Socket reachable: \(report.socketReachable) (\(report.socketPath))")
            print("Resolver registered: \(report.resolverRegistered)")
        }
    }
}
