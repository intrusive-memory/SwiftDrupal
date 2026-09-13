import Foundation

/// The container runtime surface `drupal` needs, expressed in our own value
/// types so callers and tests never touch `Containerization` directly.
///
/// `LiveContainerService` is the `Containerization`-backed implementation; tests
/// use `MockContainerService` (Tests/SwiftDrupalTests/Container).
///
/// Errors: implementations throw `DrupalError` — `.platformUnavailable` when the
/// runtime cannot be used at all, `.containerFailedToStart` for create/start
/// failures. Other runtime failures may surface as their underlying error.
public protocol ContainerService: Sendable {
    /// Ensures `reference` is present in the local image store, pulling if needed.
    func pullImage(_ reference: String) async throws

    /// Creates (but does not start) a container from `spec`. Persistent mount
    /// host directories are created if missing.
    func create(_ spec: ContainerSpec) async throws

    /// Starts a created container's main process.
    func start(id: String) async throws

    /// Stops a running container. Stopping a stopped container succeeds.
    func stop(id: String) async throws

    /// Deletes a container and its runtime state (not persistent mounts).
    /// Deleting an unknown container succeeds.
    func delete(id: String) async throws

    /// Current state and IP address. Returns `.notFound` state rather than throwing
    /// for unknown ids.
    func inspect(id: String) async throws -> ContainerStatus

    /// Runs a command inside a running container and waits for it to exit.
    func exec(id: String, _ request: ExecRequest) async throws -> ExecResult

    /// Streams the main process's output, line by line. Buffered lines are
    /// replayed first; with `follow` the stream stays open for new lines until the
    /// container stops or the consumer cancels.
    func logs(id: String, follow: Bool) async throws -> AsyncThrowingStream<LogLine, any Error>
}
