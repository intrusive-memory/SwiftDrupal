import ArgumentParser
import Foundation

/// `drupal logs [service] [--follow|-f] [--json]`: reads the web and db
/// containers' log streams from the host service (Sortie 8) and merges them
/// into one timestamp-ordered, source-tagged stream (`LogMerger`) — printed
/// as colorized scrolling text on a TTY, or one JSON object per line
/// otherwise (`--json` forces JSON even on a TTY, via `OutputOptions`).
///
/// Without `--follow`, prints whatever is buffered and exits 0. With it,
/// streams live until the container(s) stop or the process is interrupted.
public struct LogsCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "logs",
        abstract: "Show container logs, merged by timestamp and tagged by source.",
        discussion: """
            On a TTY: colorized [web]/[db]-prefixed text (NO_COLOR disables color). With --json or a non-TTY \
            stdout: one compact JSON object per line with keys timestamp, service, stream, message. Without \
            --follow, prints the buffered lines and exits 0. With --follow, SIGINT stops streaming and exits 0.
            """
    )

    @Argument(help: "Limit to one container: \"web\" or \"db\" (default: both, merged).")
    public var service: String?

    @Flag(name: [.customLong("follow"), .customShort("f")], help: "Keep streaming new lines as they arrive.")
    public var follow = false

    @OptionGroup public var output: OutputOptions

    public init() {}

    public func run() async throws {
        try await execute(environment: LifecycleEnvironment.current)
    }

    public func execute(environment: LifecycleEnvironment) async throws {
        let projectRoot = environment.currentDirectory()
        let roles = try Self.resolveRoles(service)

        let containerService = environment.makeClient()
        var sources: [ContainerRole: AsyncThrowingStream<LogLine, Error>] = [:]
        for role in roles {
            let id = try ServiceTarget.containerID(role: role, projectRoot: projectRoot)
            // No in-process fallback (OQ-4): an unreachable service throws
            // `DrupalError.serviceUnavailable` (exit 14) straight out of here.
            sources[role] = try await containerService.logs(id: id, follow: follow)
        }

        let noColor = ProcessInfo.processInfo.environment["NO_COLOR"] != nil
        let sink: any LogLineSink =
            output.format(using: environment.outputResolver) == .json
            ? JSONLogLineSink(writeLine: environment.writeOutput)
            : TUILogLineSink(colorEnabled: !noColor, writeLine: environment.writeOutput)

        // Only needed in follow mode: without `--follow` the merge finishes
        // on its own once every source's buffered backlog is drained, well
        // within a command invocation's normal lifetime.
        var cancelGuard: (@Sendable () -> Void)?
        if follow {
            // Exit 0, unlike exec/ssh's 128+signal: `logs` isn't relaying a
            // remote process whose death-by-signal status should propagate,
            // it's a local viewer being asked to stop. There is nothing to
            // restore locally (no raw terminal mode here), so cleanup is a
            // no-op; `exit()` itself closes this process's sockets, which is
            // what tells the service to cancel the still-running server-side
            // log stream(s).
            cancelGuard = environment.installInterruptGuard({}, { _ in Foundation.exit(0) })
        }
        defer { cancelGuard?() }

        let merged = LogMerger.merge(sources: sources)
        for try await entry in merged {
            sink.write(entry)
        }
    }

    /// `nil`/empty selects both containers, merged; otherwise the one named
    /// role. Unlike `ServiceTarget.role(for:)`'s own "empty means web" default
    /// (`ssh`'s convention), an absent argument here means "both", so this
    /// checks for that before delegating.
    static func resolveRoles(_ service: String?) throws -> [ContainerRole] {
        guard let service, !service.trimmingCharacters(in: .whitespaces).isEmpty else {
            return ContainerRole.allCases
        }
        return [try ServiceTarget.role(for: service)]
    }
}
