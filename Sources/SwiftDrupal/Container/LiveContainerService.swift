import Containerization
import Foundation

/// `ContainerService` backed by Apple's `Containerization` package.
///
/// IMPORTANT lifetime caveat: `Containerization` runs each container as a
/// lightweight VM owned by *this process*. Containers created here live only as
/// long as the `LiveContainerService` instance's process; `inspect` only knows
/// containers this instance created. It is therefore constructed only by
/// `drupal service run` (the launchd-managed host, OQ-4); CLI commands use
/// `ServiceClientContainerService`.
public actor LiveContainerService: ContainerService {
    public struct Configuration: Sendable {
        /// Linux kernel image booted in each container VM.
        public var kernelURL: URL
        /// OCI reference of the `vminitd` init filesystem image.
        public var initfsReference: String
        /// Root for Containerization's image store and per-container state.
        public var stateRoot: URL

        public init(kernelURL: URL, initfsReference: String, stateRoot: URL) {
            self.kernelURL = kernelURL
            self.initfsReference = initfsReference
            self.stateRoot = stateRoot
        }

        /// Defaults that reuse the kernel installed by Apple's `container` CLI.
        /// TODO(verify): kernel path and the published vminit reference/tag have not
        /// been exercised against a live runtime yet.
        public static var `default`: Configuration {
            Configuration(
                kernelURL: URL.applicationSupportDirectory
                    .appending(path: "com.apple.container/kernels/default.kernel-arm64", directoryHint: .notDirectory),
                initfsReference: "ghcr.io/apple/containerization/vminit:0.45.0",
                stateRoot: DatabaseContainerSpecBuilder.defaultStateRoot
                    .appending(path: "containerization", directoryHint: .isDirectory)
            )
        }
    }

    private enum TrackedState {
        case created, running, stopped
    }

    private struct Entry {
        let container: LinuxContainer
        let spec: ContainerSpec
        let logs: LogBuffer
        var state: TrackedState
        var message: String?
    }

    private let configuration: Configuration
    private var manager: ContainerManager?
    private var entries: [String: Entry] = [:]

    public init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    // MARK: - Platform

    private func ensureManager() async throws -> ContainerManager {
        if let manager { return manager }
        #if !arch(arm64)
        throw DrupalError.platformUnavailable("Containerization requires Apple Silicon")
        #else
        guard FileManager.default.fileExists(atPath: configuration.kernelURL.path(percentEncoded: false)) else {
            throw DrupalError.platformUnavailable(
                "Linux kernel not found at \(configuration.kernelURL.path(percentEncoded: false))"
            )
        }
        do {
            let kernel = Kernel(path: configuration.kernelURL, platform: .linuxArm)
            let created = try await ContainerManager(
                kernel: kernel,
                initfsReference: configuration.initfsReference,
                root: configuration.stateRoot,
                network: try VmnetNetwork()
            )
            manager = created
            return created
        } catch let error as DrupalError {
            throw error
        } catch {
            throw DrupalError.platformUnavailable("cannot initialize Containerization: \(error)")
        }
        #endif
    }

    private func entry(_ id: String) throws -> Entry {
        guard let entry = entries[id] else {
            throw DrupalError.containerFailedToStart("unknown container \(id)")
        }
        return entry
    }

    // MARK: - ContainerService

    public func pullImage(_ reference: String) async throws {
        let manager = try await ensureManager()
        do {
            _ = try await manager.imageStore.get(reference: reference, pull: true)
        } catch {
            throw DrupalError.containerFailedToStart("failed to pull \(reference): \(error)")
        }
    }

    public func create(_ spec: ContainerSpec) async throws {
        if entries[spec.id] != nil { return }
        var manager = try await ensureManager()

        for mount in spec.mounts where mount.persistent {
            try FileManager.default.createDirectory(
                at: URL(filePath: mount.hostPath, directoryHint: .isDirectory),
                withIntermediateDirectories: true
            )
        }

        let logs = LogBuffer()
        let stdout = CallbackWriter { logs.append($0, stream: .stdout) }
        let stderr = CallbackWriter { logs.append($0, stream: .stderr) }

        do {
            let container = try await manager.create(spec.id, reference: spec.imageReference) { config in
                config.cpus = spec.cpus
                config.memoryInBytes = spec.memoryInBytes
                config.hostname = spec.hostname
                config.process.environmentVariables = EnvironmentList.merge(
                    config.process.environmentVariables, spec.environment
                )
                if let command = spec.command { config.process.arguments = command }
                if let workingDirectory = spec.workingDirectory { config.process.workingDirectory = workingDirectory }
                config.process.stdout = stdout
                config.process.stderr = stderr
                for mount in spec.mounts {
                    switch mount.kind {
                    case .virtiofs:
                        config.mounts.append(
                            .share(
                                source: mount.hostPath,
                                destination: mount.containerPath,
                                options: mount.readOnly ? ["ro"] : []
                            )
                        )
                    }
                }
            }
            self.manager = manager
            try await container.create()
            entries[spec.id] = Entry(container: container, spec: spec, logs: logs, state: .created)
        } catch {
            self.manager = manager
            try? manager.delete(spec.id)
            self.manager = manager
            throw DrupalError.containerFailedToStart("failed to create \(spec.id): \(error)")
        }
    }

    public func start(id: String) async throws {
        var current = try entry(id)
        if current.state == .running { return }
        do {
            if current.state == .stopped {
                // A stopped LinuxContainer may be re-created in place.
                try await current.container.create()
                current.logs.reopen()
            }
            try await current.container.start()
            current.state = .running
            current.message = nil
            entries[id] = current
        } catch {
            current.message = String(describing: error)
            entries[id] = current
            throw DrupalError.containerFailedToStart("failed to start \(id): \(error)")
        }
    }

    public func stop(id: String) async throws {
        guard var current = entries[id], current.state != .stopped else { return }
        try await current.container.stop()
        current.logs.finish()
        current.state = .stopped
        entries[id] = current
    }

    public func delete(id: String) async throws {
        guard let current = entries[id] else { return }
        if current.state != .stopped {
            try? await current.container.stop()
            current.logs.finish()
        }
        entries[id] = nil
        if var manager {
            try manager.delete(id)
            self.manager = manager
        }
    }

    public func inspect(id: String) async throws -> ContainerStatus {
        guard let current = entries[id] else { return .notFound(id) }
        let state: ContainerState =
            switch current.state {
            case .created: .created
            case .running: .running
            case .stopped: .stopped
            }
        let ip = current.container.interfaces.first.map { $0.ipv4Address.address.description }
        return ContainerStatus(
            id: id,
            state: state,
            ipAddress: ip,
            imageReference: current.spec.imageReference,
            message: current.message
        )
    }

    public func exec(id: String, _ request: ExecRequest) async throws -> ExecResult {
        let current = try entry(id)
        let base = current.container.config.process

        var process = LinuxProcessConfiguration()
        process.arguments = request.arguments
        process.environmentVariables = EnvironmentList.merge(base.environmentVariables, request.environment)
        process.workingDirectory = request.workingDirectory ?? base.workingDirectory
        process.user = base.user
        process.terminal = request.terminal
        if let stdin = request.stdin {
            process.stdin = AsyncStreamReader(source: stdin)
        }
        if let output = request.output {
            process.stdout = CallbackWriter { output(.stdout, $0) }
            if !request.terminal {
                process.stderr = CallbackWriter { output(.stderr, $0) }
            }
        }

        let linuxProcess = try await current.container.exec("exec-\(UUID().uuidString.lowercased())", configuration: process)
        do {
            try await linuxProcess.start()
            let status = try await linuxProcess.wait()
            try? await linuxProcess.delete()
            return ExecResult(exitCode: status.exitCode)
        } catch {
            try? await linuxProcess.delete()
            throw error
        }
    }

    public func logs(id: String, follow: Bool) async throws -> AsyncThrowingStream<LogLine, any Error> {
        try entry(id).logs.stream(follow: follow)
    }
}

// MARK: - IO adapters

private struct CallbackWriter: Writer {
    let onWrite: @Sendable (Data) -> Void

    init(_ onWrite: @escaping @Sendable (Data) -> Void) {
        self.onWrite = onWrite
    }

    func write(_ data: Data) throws { onWrite(data) }
    func close() throws {}
}

private struct AsyncStreamReader: ReaderStream {
    let source: AsyncStream<Data>
    func stream() -> AsyncStream<Data> { source }
}
