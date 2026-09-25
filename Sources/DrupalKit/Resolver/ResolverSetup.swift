import Darwin
import Foundation

// How `<name>.drupal` resolves, and the one-time setup behind it:
//
//   /etc/resolver/drupal          nameserver 127.0.0.1 / port 15353 — macOS
//                                 sends only *.drupal queries here (root,
//                                 written once by `sudo drupal resolver install`)
//   ~/Library/LaunchAgents/…plist keeps `drupal resolver serve` running
//                                 (per-user, no root)
//   ~/Library/Application Support/drupal/hosts
//                                 name → IP, rewritten by every start/stop
//                                 (per-user, no root)
//
// /etc/hosts is never read or written. After setup, `start` needs no
// privileges no matter how often the container IP changes.

/// Every path and host service the resolver touches, injectable for tests.
public struct ResolverEnvironment: Sendable {
    public var hostsFile: HostsFile
    /// /etc/resolver/drupal
    public var systemResolverFile: URL
    public var launchAgentFile: URL
    /// The `drupal` binary the LaunchAgent runs.
    public var executable: URL
    public var port: UInt16
    public var isRoot: Bool
    public var services: any ServiceControl

    public static let agentLabel = "dev.swiftdrupal.resolver"

    public init(
        hostsFile: HostsFile, systemResolverFile: URL, launchAgentFile: URL, executable: URL,
        port: UInt16 = DNS.defaultPort, isRoot: Bool, services: any ServiceControl
    ) {
        self.hostsFile = hostsFile
        self.systemResolverFile = systemResolverFile
        self.launchAgentFile = launchAgentFile
        self.executable = executable
        self.port = port
        self.isRoot = isRoot
        self.services = services
    }

    public static func live() -> ResolverEnvironment {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let support = home.appending(path: "Library/Application Support/drupal", directoryHint: .isDirectory)
        let exe = Bundle.main.executableURL?.resolvingSymlinksInPath()
            ?? URL(filePath: CommandLine.arguments[0]).standardizedFileURL
        return ResolverEnvironment(
            hostsFile: HostsFile(url: support.appending(path: "hosts")),
            systemResolverFile: URL(filePath: "/etc/resolver/\(DNS.zone)"),
            launchAgentFile: home.appending(path: "Library/LaunchAgents/\(agentLabel).plist"),
            executable: exe,
            isRoot: getuid() == 0,
            services: LaunchControl()
        )
    }

    // MARK: File contents

    public var systemResolverContents: String {
        """
        # Managed by drupal (`sudo drupal resolver install`): routes *.\(DNS.zone)
        # lookups to drupal's local responder. Remove with `sudo drupal resolver uninstall`.
        nameserver 127.0.0.1
        port \(port)

        """
    }

    public func launchAgentContents() -> Data {
        let logs = hostsFile.url.deletingLastPathComponent().appending(path: "resolver.log").filePath
        let plist: [String: Any] = [
            "Label": Self.agentLabel,
            "ProgramArguments": [executable.filePath, "resolver", "serve", "--port", String(port)],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Background",
            "StandardOutPath": logs,
            "StandardErrorPath": logs,
        ]
        // Serializing a literal dictionary of plist types cannot fail.
        return try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    // MARK: State

    public enum FileState: String, Encodable, Sendable {
        case installed
        case missing
        /// Present but not what `install` would write (stale port/binary, or hand-edited).
        case different
    }

    /// Compared by directive (nameserver, port), not bytes: comments and
    /// hand-made files with the same routing count as installed.
    public var systemResolverState: FileState {
        guard let data = FileManager.default.contents(atPath: systemResolverFile.filePath) else { return .missing }
        return Self.directives(String(decoding: data, as: UTF8.self)) == Self.directives(systemResolverContents) ? .installed : .different
    }

    static func directives(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first?
                .split(whereSeparator: \.isWhitespace) ?? []
            return fields.isEmpty ? nil : fields.joined(separator: " ")
        }.sorted()
    }

    public var launchAgentState: FileState {
        Self.state(of: launchAgentFile, expected: launchAgentContents())
    }

    static func state(of file: URL, expected: Data) -> FileState {
        guard let data = FileManager.default.contents(atPath: file.filePath) else { return .missing }
        return data == expected ? .installed : .different
    }

    /// Both halves are in place (the responder itself may still be down).
    public var isInstalled: Bool {
        systemResolverState == .installed && launchAgentState == .installed
    }
}

/// launchd, behind a protocol so tests never touch the real one.
public protocol ServiceControl: Sendable {
    func isLoaded(_ label: String) -> Bool
    func load(_ plist: URL) throws(DrupalError)
    func unload(_ label: String) throws(DrupalError)
}

public struct LaunchControl: ServiceControl {
    public init() {}

    private var domain: String { "gui/\(getuid())" }

    public func isLoaded(_ label: String) -> Bool {
        run(["print", "\(domain)/\(label)"]).status == 0
    }

    public func load(_ plist: URL) throws(DrupalError) {
        let r = run(["bootstrap", domain, plist.filePath])
        guard r.status == 0 else {
            throw DrupalError(.ioError, "launchctl bootstrap failed (\(r.status)): \(r.output)")
        }
    }

    public func unload(_ label: String) throws(DrupalError) {
        guard isLoaded(label) else { return }
        let r = run(["bootout", "\(domain)/\(label)"])
        guard r.status == 0 else {
            throw DrupalError(.ioError, "launchctl bootout failed (\(r.status)): \(r.output)")
        }
    }

    private func run(_ args: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/launchctl")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
