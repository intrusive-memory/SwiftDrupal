import Foundation

// Placeholder runtime until the Containerization-backed one exists. Every
// operation fails with `not_implemented` — never a fake success, so an agent
// cannot mistake the skeleton for a working environment.

public struct UnimplementedRuntime: ContainerRuntime {
    public init() {}

    public func start(_ project: ResolvedProject, options: StartOptions) async throws(DrupalError) -> ProjectStatus {
        throw .notImplemented("start")
    }

    public func stop(_ project: ResolvedProject) async throws(DrupalError) -> ProjectStatus {
        throw .notImplemented("stop")
    }

    public func status(_ project: ResolvedProject) async throws(DrupalError) -> ProjectStatus {
        throw .notImplemented("status")
    }

    public func delete(_ project: ResolvedProject, keepData: Bool) async throws(DrupalError) {
        throw .notImplemented("delete")
    }

    public func exec(_ project: ResolvedProject, _ request: ExecRequest) async throws(DrupalError) -> ExecResult {
        throw .notImplemented("exec")
    }

    public func logs(_ project: ResolvedProject, _ request: LogRequest) -> AsyncThrowingStream<LogEntry, any Error> {
        AsyncThrowingStream { $0.finish(throwing: DrupalError.notImplemented("logs")) }
    }
}
