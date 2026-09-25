import ArgumentParser
import Darwin
import Foundation

// `drupal resolver …`: the one-time setup that makes `<name>.drupal` resolve
// (see Resolver/ResolverSetup.swift). Setup is split by privilege so neither
// half prompts: `sudo drupal resolver install` writes /etc/resolver/drupal,
// plain `drupal resolver install` installs the per-user LaunchAgent. Either
// order works; both are idempotent, and install exits 14 until both are done.

struct ResolverCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "resolver",
        abstract: "Set up and inspect the local DNS resolver that makes <name>.drupal resolve.",
        subcommands: [
            ResolverInstallCommand.self,
            ResolverUninstallCommand.self,
            ResolverStatusCommand.self,
            ResolverServeCommand.self,
        ],
        defaultSubcommand: ResolverStatusCommand.self
    )
}

struct ResolverReport: Encodable, Sendable {
    struct FileReport: Encodable, Sendable {
        var path: String
        var state: ResolverEnvironment.FileState
    }

    struct AgentReport: Encodable, Sendable {
        var path: String
        var state: ResolverEnvironment.FileState
        var loaded: Bool
    }

    struct Responder: Encodable, Sendable {
        var address: String
        var responding: Bool
    }

    struct Host: Encodable, Sendable {
        var hostname: String
        var ipAddress: String
        /// What the system resolver returns for it; nil if unresolvable or not checked.
        var systemResolvesTo: [String]?

        enum CodingKeys: String, CodingKey {
            case hostname
            case ipAddress = "ip_address"
            case systemResolvesTo = "system_resolves_to"
        }
    }

    var healthy: Bool
    var problems: [String]
    var actions: [String]?
    var systemResolver: FileReport
    var launchAgent: AgentReport
    var responder: Responder
    var hostsFile: String
    var hosts: [Host]?

    enum CodingKeys: String, CodingKey {
        case healthy, problems, actions, responder, hosts
        case systemResolver = "system_resolver"
        case launchAgent = "launch_agent"
        case hostsFile = "hosts_file"
    }

    /// Current state; `deep` also probes the responder and system resolution.
    static func gather(_ env: ResolverEnvironment, deep: Bool, actions: [String]? = nil) -> ResolverReport {
        let system = env.systemResolverState
        let agent = env.launchAgentState
        let loaded = env.services.isLoaded(ResolverEnvironment.agentLabel)
        let responding = DNSProbe.query(DNS.zone, port: env.port, timeout: 0.5) != nil
        var problems: [String] = []
        switch system {
        case .installed: break
        case .missing: problems.append("\(env.systemResolverFile.filePath) is missing; run `sudo drupal resolver install`")
        case .different: problems.append("\(env.systemResolverFile.filePath) differs from what drupal would write; run `sudo drupal resolver install`")
        }
        switch agent {
        case .installed: break
        case .missing: problems.append("the resolver LaunchAgent is not installed; run `drupal resolver install`")
        case .different: problems.append("the resolver LaunchAgent is stale (binary moved or port changed); run `drupal resolver install`")
        }
        if agent == .installed && !loaded { problems.append("the resolver LaunchAgent is installed but not loaded; run `drupal resolver install`") }
        if !responding { problems.append("nothing answers DNS on 127.0.0.1:\(env.port)") }

        var hosts: [Host]?
        if deep, let entries = try? env.hostsFile.entries() {
            hosts = entries.sorted { $0.key < $1.key }.map { name, ip in
                let checked = system == .installed && responding
                let resolved = checked ? SystemResolver.addresses(of: name) : nil
                if checked && resolved == nil {
                    problems.append("\(name) does not resolve through macOS; is another process holding 127.0.0.1:\(env.port)?")
                } else if let resolved, !resolved.contains(ip) {
                    problems.append("\(name) resolves to \(resolved.joined(separator: ", ")) instead of \(ip)")
                }
                return Host(hostname: name, ipAddress: ip, systemResolvesTo: resolved)
            }
        }
        return ResolverReport(
            healthy: problems.isEmpty,
            problems: problems,
            actions: actions,
            systemResolver: FileReport(path: env.systemResolverFile.filePath, state: system),
            launchAgent: AgentReport(path: env.launchAgentFile.filePath, state: agent, loaded: loaded),
            responder: Responder(address: "127.0.0.1:\(env.port)", responding: responding),
            hostsFile: env.hostsFile.url.filePath,
            hosts: hosts
        )
    }

    var text: String {
        var lines = [
            "System resolver:  \(systemResolver.state.rawValue) (\(systemResolver.path))",
            "LaunchAgent:      \(launchAgent.state.rawValue)\(launchAgent.loaded ? ", loaded" : "") (\(launchAgent.path))",
            "Responder:        \(responder.responding ? "responding" : "not responding") on \(responder.address)",
            "Hosts file:       \(hostsFile)",
        ]
        for h in hosts ?? [] { lines.append("  \(h.hostname) → \(h.ipAddress)") }
        for a in actions ?? [] { lines.append("done: \(a)") }
        for p in problems { lines.append("problem: \(p)") }
        return lines.joined(separator: "\n")
    }
}

struct ResolverInstallCommand: DrupalCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "One-time setup so <name>.drupal resolves. Run once with sudo and once without, in either order.",
        discussion: """
            With sudo: writes /etc/resolver/drupal, routing only *.drupal lookups to 127.0.0.1:\(DNS.defaultPort). \
            Without sudo: installs and loads a per-user LaunchAgent running `drupal resolver serve`. /etc/hosts is never touched. \
            Idempotent. Exits 14 (permission_required) while the sudo half is still missing.
            """
    )
    static var envelopeName: String { "resolver install" }

    @OptionGroup var global: GlobalOptions

    func execute(_ context: CommandContext) async throws(DrupalError) -> CommandOutput {
        let env = context.environment.resolver
        var actions: [String] = []
        var warnings: [String] = []

        if env.isRoot {
            if env.systemResolverState != .installed {
                try write(Data(env.systemResolverContents.utf8), to: env.systemResolverFile)
                actions.append("wrote \(env.systemResolverFile.filePath)")
            }
            if env.launchAgentState != .installed {
                warnings.append("now run `drupal resolver install` without sudo to install the per-user responder")
            }
            let report = ResolverReport.gather(env, deep: false, actions: actions)
            return CommandOutput(data: report, text: report.text, warnings: warnings)
        }

        let label = ResolverEnvironment.agentLabel
        let agentState = env.launchAgentState
        if agentState != .installed {
            if agentState == .different { try env.services.unload(label) }
            try write(env.launchAgentContents(), to: env.launchAgentFile)
            actions.append("wrote \(env.launchAgentFile.filePath)")
        }
        if !env.services.isLoaded(label) {
            try env.services.load(env.launchAgentFile)
            actions.append("loaded \(label)")
        }
        if env.systemResolverState != .installed {
            throw DrupalError(
                .permissionRequired,
                "the per-user responder is set up, but \(env.systemResolverFile.filePath) needs root to write",
                details: actions.map { .init(message: "done: \($0)") },
                hint: "Run once: sudo drupal resolver install"
            )
        }
        let report = ResolverReport.gather(env, deep: false, actions: actions)
        return CommandOutput(data: report, text: report.text)
    }

    private func write(_ data: Data, to file: URL) throws(DrupalError) {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        } catch {
            throw DrupalError(.ioError, "could not write \(file.filePath): \(error.localizedDescription)")
        }
    }
}

struct ResolverUninstallCommand: DrupalCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall",
        abstract: "Remove the resolver setup. Run once without sudo and once with, in either order.",
        discussion: "Idempotent. Exits 14 (permission_required) while /etc/resolver/drupal still exists and sudo was not used."
    )
    static var envelopeName: String { "resolver uninstall" }

    @OptionGroup var global: GlobalOptions

    func execute(_ context: CommandContext) async throws(DrupalError) -> CommandOutput {
        let env = context.environment.resolver
        var actions: [String] = []
        let fm = FileManager.default

        func remove(_ file: URL) throws(DrupalError) {
            guard fm.fileExists(atPath: file.filePath) else { return }
            do { try fm.removeItem(at: file) } catch {
                throw DrupalError(.ioError, "could not remove \(file.filePath): \(error.localizedDescription)")
            }
            actions.append("removed \(file.filePath)")
        }

        if env.isRoot {
            try remove(env.systemResolverFile)
        } else {
            if env.services.isLoaded(ResolverEnvironment.agentLabel) {
                try env.services.unload(ResolverEnvironment.agentLabel)
                actions.append("unloaded \(ResolverEnvironment.agentLabel)")
            }
            try remove(env.launchAgentFile)
            if fm.fileExists(atPath: env.systemResolverFile.filePath) {
                throw DrupalError(
                    .permissionRequired,
                    "the per-user responder is removed, but \(env.systemResolverFile.filePath) needs root to remove",
                    details: actions.map { .init(message: "done: \($0)") },
                    hint: "Run once: sudo drupal resolver uninstall"
                )
            }
        }
        struct Result: Encodable, Sendable { var actions: [String] }
        return CommandOutput(
            data: Result(actions: actions),
            text: actions.isEmpty ? "Nothing to remove" : actions.map { "done: \($0)" }.joined(separator: "\n")
        )
    }
}

struct ResolverStatusCommand: DrupalCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Check every piece of the resolver setup, including what each registered hostname resolves to.",
        discussion: "Always exits 0 when the check itself ran; read `healthy` and `problems`."
    )
    static var envelopeName: String { "resolver status" }

    @OptionGroup var global: GlobalOptions

    func execute(_ context: CommandContext) async throws(DrupalError) -> CommandOutput {
        let report = ResolverReport.gather(context.environment.resolver, deep: true)
        return CommandOutput(data: report, text: report.text)
    }
}

struct ResolverServeCommand: DrupalCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Run the .drupal DNS responder in the foreground (what the LaunchAgent runs).",
        discussion: "Answers *.drupal from drupal's own hosts file on 127.0.0.1 only. Runs until killed."
    )
    static var envelopeName: String { "resolver serve" }

    @OptionGroup var global: GlobalOptions

    @Option(help: ArgumentHelp("UDP port on 127.0.0.1.", valueName: "port"))
    var port: Int = Int(DNS.defaultPort)

    func validate() throws {
        guard (1...65535).contains(port) else { throw ValidationError("--port must be 1–65535") }
    }

    func execute(_ context: CommandContext) async throws(DrupalError) -> CommandOutput {
        let hosts = context.environment.resolver.hostsFile
        let responder = try DNSResponder(hostsFile: hosts, port: UInt16(port))
        context.environment.stderr.write("drupal resolver: answering *.\(DNS.zone) on 127.0.0.1:\(responder.port) from \(hosts.url.filePath)\n")
        responder.run()
        return CommandOutput(data: nil, text: "")
    }
}

/// End-to-end check through the system resolver (i.e. /etc/resolver).
enum SystemResolver {
    static func addresses(of hostname: String) -> [String]? {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(hostname, nil, &hints, &result) == 0, let first = result else { return nil }
        defer { freeaddrinfo(first) }
        var out: [String] = []
        for info in sequence(first: first, next: { $0.pointee.ai_next }) {
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let s = String(cString: host)
                if !out.contains(s) { out.append(s) }
            }
        }
        return out
    }
}
