import Darwin
import Foundation

/// Filesystem locations used by the host service. Every path derives from
/// `home`, so tests point it at a temp directory.
public struct ServicePaths: Equatable, Sendable {
    /// Reverse-DNS launchd label of the per-user agent.
    public static let label = "com.intrusive-memory.swiftdrupal.service"
    /// Overrides `socketPath` (diagnostics and manual testing).
    public static let socketPathEnvironmentKey = "SWIFTDRUPAL_SERVICE_SOCKET"

    public var home: URL
    public var socketPathOverride: String?

    public init(home: URL, socketPathOverride: String? = nil) {
        self.home = home
        self.socketPathOverride = socketPathOverride
    }

    /// The current user's paths, honouring `SWIFTDRUPAL_SERVICE_SOCKET`.
    public static func current(environment: [String: String] = ProcessInfo.processInfo.environment) -> ServicePaths {
        let override = environment[socketPathEnvironmentKey].flatMap { $0.isEmpty ? nil : $0 }
        return ServicePaths(home: FileManager.default.homeDirectoryForCurrentUser, socketPathOverride: override)
    }

    /// `~/Library/Application Support/SwiftDrupal`.
    public var supportDirectory: URL {
        home.appending(path: "Library/Application Support/SwiftDrupal", directoryHint: .isDirectory)
    }

    /// `~/Library/Application Support/SwiftDrupal/service.sock`.
    public var socketPath: String {
        socketPathOverride ?? supportDirectory.appending(path: "service.sock").path(percentEncoded: false)
    }

    public var launchAgentsDirectory: URL {
        home.appending(path: "Library/LaunchAgents", directoryHint: .isDirectory)
    }

    public var plistURL: URL {
        launchAgentsDirectory.appending(path: "\(Self.label).plist")
    }

    /// stdout/stderr of the agent.
    public var logURL: URL {
        home.appending(path: "Library/Logs/SwiftDrupal/service.log")
    }
}

/// Renders the per-user LaunchAgent property list.
public enum LaunchAgentPlist {
    /// Seconds launchd waits after SIGTERM before SIGKILL; containers need time
    /// to stop gracefully (launchd's default is 20).
    public static let exitTimeOut = 60

    public static func render(label: String = ServicePaths.label, executablePath: String, logPath: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>ExitTimeOut</key>
        \t<integer>\(exitTimeOut)</integer>
        \t<key>KeepAlive</key>
        \t<true/>
        \t<key>Label</key>
        \t<string>\(escape(label))</string>
        \t<key>ProcessType</key>
        \t<string>Interactive</string>
        \t<key>ProgramArguments</key>
        \t<array>
        \t\t<string>\(escape(executablePath))</string>
        \t\t<string>service</string>
        \t\t<string>run</string>
        \t</array>
        \t<key>RunAtLoad</key>
        \t<true/>
        \t<key>StandardErrorPath</key>
        \t<string>\(escape(logPath))</string>
        \t<key>StandardOutPath</key>
        \t<string>\(escape(logPath))</string>
        </dict>
        </plist>

        """
    }

    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

/// Runs `launchctl`. Injected so tests never touch launchd.
public protocol LaunchctlRunner: Sendable {
    /// Returns the exit status and combined output.
    func run(_ arguments: [String]) throws -> (status: Int32, output: String)
}

/// Live `/bin/launchctl`. NOT exercised by tests.
public struct SystemLaunchctl: LaunchctlRunner {
    public init() {}

    public func run(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

public struct ServiceInstallError: Error, Equatable, Sendable, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

public struct ServiceInstallReport: Codable, Equatable, Sendable {
    public var label: String
    public var plistPath: String
    public var executablePath: String
    public var socketPath: String
    /// True when `/etc/resolver/drupal` was (re)written; false when already current.
    public var resolverFileWritten: Bool
    public var warnings: [String]
}

public struct ServiceUninstallReport: Codable, Equatable, Sendable {
    public var label: String
    public var plistRemoved: Bool
    public var resolverFileRemoved: Bool
}

public struct ServiceStatusReport: Codable, Equatable, Sendable {
    public var label: String
    public var plistPath: String
    public var plistInstalled: Bool
    public var agentLoaded: Bool
    public var socketPath: String
    public var socketReachable: Bool
    public var resolverRegistered: Bool
    public var service: ServiceInfo?
}

/// `drupal service install / uninstall / status`, with every side effect
/// injectable (paths, launchctl, privileged writer, socket probe).
public struct ServiceInstaller: Sendable {
    public var paths: ServicePaths
    public var executablePath: String
    public var uid: uid_t
    public var launchctl: any LaunchctlRunner
    public var registrar: ResolverFileRegistrar
    public var responderPort: UInt16

    public init(
        paths: ServicePaths,
        executablePath: String,
        uid: uid_t = getuid(),
        launchctl: any LaunchctlRunner = SystemLaunchctl(),
        registrar: ResolverFileRegistrar = ResolverFileRegistrar(writer: AdministratorFileWriter()),
        responderPort: UInt16 = LocalDNSServer.defaultPort
    ) {
        self.paths = paths
        self.executablePath = executablePath
        self.uid = uid
        self.launchctl = launchctl
        self.registrar = registrar
        self.responderPort = responderPort
    }

    var domain: String { "gui/\(uid)" }
    var serviceTarget: String { "\(domain)/\(ServicePaths.label)" }

    /// The executable launchd should run: the current binary, symlinks resolved.
    public static func currentExecutablePath() -> String {
        let url = Bundle.main.executableURL ?? URL(filePath: CommandLine.arguments[0])
        return url.resolvingSymlinksInPath().path(percentEncoded: false)
    }

    public func install() throws -> ServiceInstallReport {
        guard executablePath.hasPrefix("/") else {
            throw ServiceInstallError("executable path must be absolute: \(executablePath)")
        }
        var warnings: [String] = []
        if executablePath.contains("/.build/") || executablePath.contains("/DerivedData/") {
            warnings.append(
                "Warning: installing a build-directory binary (\(executablePath)); rebuilding or moving it requires `drupal service install` again.")
        }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: paths.launchAgentsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: paths.supportDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fileManager.createDirectory(at: paths.logURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let plist = LaunchAgentPlist.render(
            executablePath: executablePath, logPath: paths.logURL.path(percentEncoded: false))
        try plist.write(to: paths.plistURL, atomically: true, encoding: .utf8)

        // Replace any loaded copy so a moved binary or changed plist takes effect.
        _ = try? launchctl.run(["bootout", serviceTarget])
        let bootstrap = try launchctl.run(["bootstrap", domain, paths.plistURL.path(percentEncoded: false)])
        guard bootstrap.status == 0 else {
            throw ServiceInstallError(
                "launchctl bootstrap \(domain) failed (\(bootstrap.status)): \(bootstrap.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        let wrote = try registrar.register(port: responderPort)
        return ServiceInstallReport(
            label: ServicePaths.label,
            plistPath: paths.plistURL.path(percentEncoded: false),
            executablePath: executablePath,
            socketPath: paths.socketPath,
            resolverFileWritten: wrote,
            warnings: warnings)
    }

    public func uninstall() throws -> ServiceUninstallReport {
        _ = try? launchctl.run(["bootout", serviceTarget])
        let fileManager = FileManager.default
        let plistPath = paths.plistURL.path(percentEncoded: false)
        let hadPlist = fileManager.fileExists(atPath: plistPath)
        if hadPlist { try fileManager.removeItem(atPath: plistPath) }
        let hadResolver = registrar.writer.readFile(atPath: registrar.path) != nil
        try registrar.unregister()
        return ServiceUninstallReport(label: ServicePaths.label, plistRemoved: hadPlist, resolverFileRemoved: hadResolver)
    }

    public func status() async -> ServiceStatusReport {
        let loaded = ((try? launchctl.run(["print", serviceTarget]))?.status ?? 1) == 0
        let info = try? await ServiceClientContainerService(socketPath: paths.socketPath, hostsFallback: nil).ping()
        return ServiceStatusReport(
            label: ServicePaths.label,
            plistPath: paths.plistURL.path(percentEncoded: false),
            plistInstalled: FileManager.default.fileExists(atPath: paths.plistURL.path(percentEncoded: false)),
            agentLoaded: loaded,
            socketPath: paths.socketPath,
            socketReachable: info != nil,
            resolverRegistered: registrar.isRegistered(port: responderPort),
            service: info)
    }
}
