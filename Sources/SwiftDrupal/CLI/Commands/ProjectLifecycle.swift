import Foundation
import Synchronization

/// Aggregate state of a project's containers.
public enum ProjectState: String, Codable, Sendable {
    /// Every container is running.
    case running
    /// No container is running (includes containers the service does not know,
    /// e.g. after a service restart).
    case stopped
    /// Some but not all containers are running.
    case partial
    /// At least one container reports an error.
    case errored

    public init(_ states: [ContainerState]) {
        if states.contains(.errored) {
            self = .errored
        } else if !states.isEmpty, states.allSatisfy({ $0 == .running }) {
            self = .running
        } else if states.contains(.running) {
            self = .partial
        } else {
            self = .stopped
        }
    }
}

/// One container's state after a lifecycle command, plus what the command did to it.
public struct ContainerReport: Codable, Equatable, Sendable {
    public var role: ContainerRole
    public var id: String
    /// Image the project config selects.
    public var image: String
    public var state: ContainerState
    public var ipAddress: String?
    public var message: String?
    /// The command created the container (it did not exist in the service).
    public var created: Bool
    /// The container was running before the command.
    public var wasRunning: Bool
    /// The command changed the container's state (created, started, stopped, or deleted).
    public var changed: Bool
    /// `start` only: the health probe passed. Nil when not checked.
    public var healthy: Bool?

    init(spec: ContainerSpec, status: ContainerStatus, created: Bool = false, wasRunning: Bool, changed: Bool, healthy: Bool? = nil) {
        role = spec.role
        id = spec.id
        image = spec.imageReference
        state = status.state
        ipAddress = status.ipAddress
        message = status.message
        self.created = created
        self.wasRunning = wasRunning
        self.changed = changed
        self.healthy = healthy
    }
}

/// Result of `start`, `stop`, and `delete`.
public struct LifecycleReport: Codable, Equatable, Sendable {
    public var command: String
    public var project: String
    public var projectRoot: String
    public var hostname: String
    public var url: String
    public var state: ProjectState
    /// False when the command was a no-op (idempotent repeat).
    public var changed: Bool
    /// Start order for `start`, stop order for `stop`/`delete`.
    public var containers: [ContainerReport]
    /// `start` only: how `hostname` was pointed at the web container.
    public var hostnameActivation: HostnameActivationReport?
    /// `delete` only: persistent data directories removed from the host.
    public var removedDataDirectories: [String]?
    public var warnings: [String]
    /// `start` only, and only when the config lists `post_start` commands.
    public var postStart: PostStartReport?

    /// The error `start`/`restart` exit with after emitting this report, when a
    /// `post_start` command failed.
    public var postStartError: DrupalError? {
        guard let postStart, let failed = postStart.commands.last, !failed.succeeded else { return nil }
        return .containerFailedToStart(
            "post_start command \(failed.index + 1) of \(postStart.commands.count + postStart.skipped.count) (`\(failed.command)`) exited \(failed.exitCode) in \(postStart.containerId)")
    }
}

/// Outcome of the config's `post_start` commands.
public struct PostStartReport: Codable, Equatable, Sendable {
    /// One command's run.
    public struct CommandResult: Codable, Equatable, Sendable {
        /// Zero-based position in `post_start`.
        public var index: Int
        public var command: String
        public var exitCode: Int32
        public var succeeded: Bool
        /// Combined stdout and stderr, truncated to the last `PostStartReport.outputLimit` bytes.
        public var output: String
        public var outputTruncated: Bool
    }

    /// The web container the commands ran in.
    public var containerId: String
    /// Commands that ran, in order. The last entry is the failure when `failed` is true.
    public var commands: [CommandResult]
    /// Commands not run because an earlier one failed.
    public var skipped: [String]
    public var failed: Bool

    /// Bytes of output kept per command.
    public static let outputLimit = 64 * 1024
}

/// Result of `restart`.
public struct RestartReport: Codable, Equatable, Sendable {
    public var command = "restart"
    public var stop: LifecycleReport
    public var start: LifecycleReport
    public var warnings: [String]
}

/// Result of `status` / `describe`.
public struct StatusReport: Codable, Equatable, Sendable {
    public var project: String
    public var projectRoot: String
    public var hostname: String
    public var url: String
    public var state: ProjectState
    public var containers: [ContainerReport]
    /// The web container's IP, which `hostname` should resolve to while running.
    public var webIPAddress: String?
    /// Address of a `/etc/hosts` fallback line for `hostname`, if one exists.
    public var hostsFileAddress: String?
    public var service: ServiceInfo
    public var config: ResolvedConfigReport
    public var warnings: [String]
}

/// The lifecycle operations, written against the service client so they are
/// testable without a socket. Every operation is idempotent.
public struct ProjectLifecycle: Sendable {
    public let project: LifecycleProject
    public let client: any LifecycleServiceClient
    public let environment: LifecycleEnvironment

    public init(project: LifecycleProject, client: any LifecycleServiceClient, environment: LifecycleEnvironment) {
        self.project = project
        self.client = client
        self.environment = environment
    }

    // MARK: start

    /// Creates missing containers (pulling their images), starts them database
    /// first, waits for each to be healthy, and returns promptly: the containers
    /// keep running in the service. Safe to repeat, including after a service
    /// restart has forgotten every container.
    public func start(waitForHealth: Bool = true) async throws -> LifecycleReport {
        var reports: [ContainerReport] = []
        var warnings: [String] = []
        var activation: HostnameActivationReport?

        for spec in project.specsInStartOrder {
            var status = try await client.inspect(id: spec.id)

            // An existing container built from a different image (config edited
            // since it was created) is recreated from the current spec.
            if status.state != .notFound, let existing = status.imageReference, existing != spec.imageReference {
                if status.state == .running { try await client.stop(id: spec.id) }
                try await client.delete(id: spec.id)
                warnings.append("Recreated \(spec.id): its image changed from \(existing) to \(spec.imageReference).")
                status = .notFound(spec.id)
            }

            var created = false
            if status.state == .notFound {
                try await client.pullImage(spec.imageReference)
                try await client.create(spec)
                created = true
            }

            let wasRunning = status.state == .running
            // Always call through the service: for the web container it
            // (re)activates the hostname with the current IP, even when running.
            let outcome = try await client.startContainer(id: spec.id)
            warnings.append(contentsOf: outcome.warnings)
            if let report = outcome.hostnameActivation { activation = report }

            let final: ContainerStatus
            var healthy: Bool?
            if waitForHealth {
                final = try await environment.healthChecker.waitUntilHealthy(
                    service: client, id: spec.id, probe: environment.healthProbe)
                healthy = true
            } else {
                final = try await client.inspect(id: spec.id)
            }
            reports.append(
                ContainerReport(
                    spec: spec, status: final, created: created, wasRunning: wasRunning,
                    changed: created || !wasRunning, healthy: healthy))
        }

        if activation == nil {
            warnings.append("The service did not activate \(project.hostname) (the web container reported no IP address).")
        }

        return LifecycleReport(
            command: "start", project: project.name, projectRoot: project.root.path(percentEncoded: false),
            hostname: project.hostname, url: project.url, state: ProjectState(reports.map(\.state)),
            changed: reports.contains(where: \.changed) || warnings.contains(where: { $0.hasPrefix("Recreated ") }),
            containers: reports, hostnameActivation: activation, removedDataDirectories: nil, warnings: warnings,
            postStart: try await runPostStart())
    }

    /// Runs `post_start` in the web container, in order, stopping at the first
    /// non-zero exit. Returns nil when the config lists no commands. A thrown
    /// error (e.g. the service became unreachable) propagates unchanged.
    func runPostStart() async throws -> PostStartReport? {
        let commands = project.config.postStart
        guard !commands.isEmpty else { return nil }
        let id = project.webSpec.id
        var results: [PostStartReport.CommandResult] = []
        for (index, command) in commands.enumerated() {
            let buffer = PostStartOutputBuffer(limit: PostStartReport.outputLimit)
            let request = ExecRequest(
                arguments: Self.postStartArguments(for: command),
                workingDirectory: WebContainerSpecBuilder.projectMountPath,
                output: { _, data in buffer.append(data) })
            let result = try await client.exec(id: id, request)
            let (output, truncated) = buffer.contents
            results.append(
                .init(
                    index: index, command: command, exitCode: result.exitCode, succeeded: result.succeeded,
                    output: output, outputTruncated: truncated))
            if !result.succeeded {
                return PostStartReport(
                    containerId: id, commands: results, skipped: Array(commands[(index + 1)...]), failed: true)
            }
        }
        return PostStartReport(containerId: id, commands: results, skipped: [], failed: false)
    }

    /// The exec argument vector for one `post_start` entry.
    public static func postStartArguments(for command: String) -> [String] { ["/bin/sh", "-c", command] }

    // MARK: stop

    /// Stops running containers, web first. Stopping a stopped (or unknown)
    /// project succeeds without changes.
    public func stop() async throws -> LifecycleReport {
        var reports: [ContainerReport] = []
        for spec in project.specsInStopOrder {
            let status = try await client.inspect(id: spec.id)
            let wasRunning = status.state == .running
            if wasRunning { try await client.stop(id: spec.id) }
            let final = wasRunning ? try await client.inspect(id: spec.id) : status
            reports.append(ContainerReport(spec: spec, status: final, wasRunning: wasRunning, changed: wasRunning))
        }
        let warnings = try await deactivateHostname()
        return LifecycleReport(
            command: "stop", project: project.name, projectRoot: project.root.path(percentEncoded: false),
            hostname: project.hostname, url: project.url, state: ProjectState(reports.map(\.state)),
            changed: reports.contains(where: \.changed), containers: reports, hostnameActivation: nil,
            removedDataDirectories: nil, warnings: warnings, postStart: nil)
    }

    // MARK: delete

    /// Stops and removes both containers and (unless `keepData`) the database
    /// data directory. Project source files are never touched. Safe to repeat.
    public func delete(keepData: Bool = false) async throws -> LifecycleReport {
        var reports: [ContainerReport] = []
        for spec in project.specsInStopOrder {
            let status = try await client.inspect(id: spec.id)
            let exists = status.state != .notFound
            if status.state == .running { try await client.stop(id: spec.id) }
            if exists { try await client.delete(id: spec.id) }
            reports.append(
                ContainerReport(
                    spec: spec, status: .notFound(spec.id), wasRunning: status.state == .running, changed: exists))
        }
        var warnings = try await deactivateHostname()

        var removed: [String] = []
        if !keepData {
            for directory in persistentDataDirectories() {
                do {
                    if try removeDataDirectory(directory) { removed.append(directory.path(percentEncoded: false)) }
                } catch {
                    warnings.append("Warning: could not remove \(directory.path(percentEncoded: false)): \(error.localizedDescription)")
                }
            }
        }

        return LifecycleReport(
            command: "delete", project: project.name, projectRoot: project.root.path(percentEncoded: false),
            hostname: project.hostname, url: project.url, state: .stopped,
            changed: reports.contains(where: \.changed) || !removed.isEmpty, containers: reports,
            hostnameActivation: nil, removedDataDirectories: removed, warnings: warnings, postStart: nil)
    }

    /// Host directories of persistent mounts that live under the state root.
    /// Anything else (including the project directory) is never removed.
    func persistentDataDirectories() -> [URL] {
        let stateRoot = environment.stateRoot.standardizedFileURL.path(percentEncoded: false)
        let rootPrefix = stateRoot.hasSuffix("/") ? stateRoot : stateRoot + "/"
        let projectPath = project.root.path(percentEncoded: false)
        return project.specsInStartOrder.flatMap(\.mounts).filter(\.persistent).compactMap { mount in
            let path = URL(filePath: mount.hostPath).standardizedFileURL.path(percentEncoded: false)
            guard path.hasPrefix(rootPrefix), !path.hasPrefix(projectPath), !projectPath.hasPrefix(path) else {
                return nil
            }
            return URL(filePath: path, directoryHint: .isDirectory)
        }
    }

    /// Removes `directory` and then its parent if that is left empty. Returns
    /// whether `directory` existed.
    private func removeDataDirectory(_ directory: URL) throws -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path(percentEncoded: false)) else { return false }
        try fileManager.removeItem(at: directory)
        let parent = directory.deletingLastPathComponent()
        if (try? fileManager.contentsOfDirectory(atPath: parent.path(percentEncoded: false)))?.isEmpty == true {
            try? fileManager.removeItem(at: parent)
        }
        return true
    }

    /// Removes the hostname from the service responder and any `/etc/hosts`
    /// fallback line (the service does not remove that line itself). An
    /// unreachable service is an error; a failed hosts-file cleanup is a warning.
    private func deactivateHostname() async throws -> [String] {
        do {
            try await client.deactivateHostname(hostname: project.hostname)
            return []
        } catch let error as DrupalError {
            if case .serviceUnavailable = error { throw error }
            return ["Warning: could not remove the hostname mapping for \(project.hostname): \(error)"]
        } catch {
            return ["Warning: could not remove the hostname mapping for \(project.hostname): \(error)"]
        }
    }

    // MARK: status

    public func status() async throws -> StatusReport {
        let service = try await client.ping()
        var reports: [ContainerReport] = []
        for spec in project.specsInStartOrder {
            let status = try await client.inspect(id: spec.id)
            reports.append(
                ContainerReport(spec: spec, status: status, wasRunning: status.state == .running, changed: false))
        }
        let state = ProjectState(reports.map(\.state))
        let webIP = reports.first(where: { $0.role == .web && $0.state == .running })?.ipAddress
        let hostsAddress = environment.hostsFile.currentAddress(for: project.hostname)?.description

        var warnings: [String] = []
        if service.protocolVersion != ServiceProtocol.version {
            warnings.append(
                "Warning: the service speaks protocol \(service.protocolVersion), this drupal speaks \(ServiceProtocol.version); run `drupal service install` again.")
        }
        if let hostsAddress, hostsAddress != webIP {
            warnings.append("Warning: /etc/hosts maps \(project.hostname) to \(hostsAddress), not the running web container.")
        }

        return StatusReport(
            project: project.name, projectRoot: project.root.path(percentEncoded: false), hostname: project.hostname,
            url: project.url, state: state, containers: reports, webIPAddress: webIP, hostsFileAddress: hostsAddress,
            service: service, config: try ResolvedConfigReport(project: project), warnings: warnings)
    }
}

/// Keeps the tail of a `post_start` command's combined output.
final class PostStartOutputBuffer: Sendable {
    private let limit: Int
    private let state = Mutex<(data: Data, truncated: Bool)>((Data(), false))

    init(limit: Int) { self.limit = limit }

    func append(_ chunk: Data) {
        state.withLock { state in
            state.data.append(chunk)
            if state.data.count > limit {
                state.data = Data(state.data.suffix(limit))
                state.truncated = true
            }
        }
    }

    var contents: (String, Bool) {
        state.withLock { (String(decoding: $0.data, as: UTF8.self), $0.truncated) }
    }
}
