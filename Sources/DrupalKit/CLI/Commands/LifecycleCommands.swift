import ArgumentParser
import Foundation

// start / stop / restart / status / delete. All go through ContainerRuntime;
// idempotency is the runtime's contract, not re-checked here.

/// Compact project identity embedded in lifecycle results.
struct ProjectRef: Encodable, Sendable {
    var name: String
    var hostname: String
    var url: String
    var root: String

    init(_ p: ResolvedProject) {
        name = p.name
        hostname = p.hostname
        url = p.url
        root = p.root.filePath
    }
}

struct PostStartResult: Encodable, Sendable {
    var command: String
    var exitCode: Int32
    enum CodingKeys: String, CodingKey {
        case command
        case exitCode = "exit_code"
    }
}

struct LifecycleResult: Encodable, Sendable {
    var project: ProjectRef
    var status: ProjectStatus
    var postStart: [PostStartResult]?

    enum CodingKeys: String, CodingKey {
        case project, status
        case postStart = "post_start"
    }
}

struct StartCommand: DrupalCommand {
    static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "Start the web and db containers, then run post_start commands.",
        discussion: "Idempotent: starting a running project succeeds. Exit 7 if a container fails to start, 8 on health timeout, 13 if a post_start command fails."
    )

    @OptionGroup var global: GlobalOptions

    @Option(help: ArgumentHelp("Seconds to wait for both containers to become healthy.", valueName: "seconds"))
    var timeout: Int = 120

    func validate() throws {
        guard timeout > 0 else { throw ValidationError("--timeout must be a positive number of seconds") }
    }

    func execute(_ context: CommandContext) async throws(DrupalError) -> CommandOutput {
        let project = try context.runnableProject()
        return try await startAndHooks(project, timeout: timeout, context)
    }
}

struct StopCommand: DrupalCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Stop the containers, keeping them and the database.",
        discussion: "Idempotent: stopping a stopped project succeeds."
    )

    @OptionGroup var global: GlobalOptions

    func execute(_ context: CommandContext) async throws(DrupalError) -> CommandOutput {
        let project = try context.runnableProject()
        let status = try await context.runtime.stop(project)
        return CommandOutput(
            data: LifecycleResult(project: ProjectRef(project), status: status),
            text: "Stopped \(project.name)"
        )
    }
}

struct RestartCommand: DrupalCommand {
    static let configuration = CommandConfiguration(
        commandName: "restart",
        abstract: "Stop then start the project (re-reads the config), running post_start commands.",
        discussion: "Same exit codes as start."
    )

    @OptionGroup var global: GlobalOptions

    @Option(help: ArgumentHelp("Seconds to wait for both containers to become healthy.", valueName: "seconds"))
    var timeout: Int = 120

    func validate() throws {
        guard timeout > 0 else { throw ValidationError("--timeout must be a positive number of seconds") }
    }

    func execute(_ context: CommandContext) async throws(DrupalError) -> CommandOutput {
        let project = try context.runnableProject()
        _ = try await context.runtime.stop(project)
        return try await startAndHooks(project, timeout: timeout, context)
    }
}

struct StatusCommand: DrupalCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show the project's resolved config and container state.",
        aliases: ["describe"]
    )

    @OptionGroup var global: GlobalOptions

    struct Result: Encodable, Sendable {
        var project: ResolvedProject
        var status: ProjectStatus
    }

    func execute(_ context: CommandContext) async throws(DrupalError) -> CommandOutput {
        let project = try context.runnableProject()
        let status = try await context.runtime.status(project)
        return CommandOutput(
            data: Result(project: project, status: status),
            text: TextFormat.status(project, status),
            warnings: project.warnings
        )
    }
}

struct DeleteCommand: DrupalCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Remove the project's containers and database. Project files and config are never touched.",
        discussion: "No confirmation prompt. Idempotent: deleting an already-deleted project succeeds. Pass --keep-data to keep the database volume."
    )

    @OptionGroup var global: GlobalOptions

    @Flag(help: "Keep the database volume; remove only the containers.")
    var keepData = false

    struct Result: Encodable, Sendable {
        var project: ProjectRef
        var keptData: Bool
        enum CodingKeys: String, CodingKey {
            case project
            case keptData = "kept_data"
        }
    }

    func execute(_ context: CommandContext) async throws(DrupalError) -> CommandOutput {
        let project = try context.runnableProject()
        try await context.runtime.delete(project, keepData: keepData)
        return CommandOutput(
            data: Result(project: ProjectRef(project), keptData: keepData),
            text: "Deleted \(project.name)" + (keepData ? " (database kept)" : "")
        )
    }
}

/// Shared by start and restart: runtime start, then each post_start command
/// in order via `bash -c` in the web container, stopping at the first failure.
private func startAndHooks(_ project: ResolvedProject, timeout: Int, _ context: CommandContext) async throws(DrupalError) -> CommandOutput {
    let status = try await context.runtime.start(project, options: StartOptions(healthTimeout: .seconds(timeout)))
    var hooks: [PostStartResult] = []
    for command in project.config.postStart {
        let output: ExecRequest.Output = context.jsonMode ? .capture : .inherit
        let result = try await context.runtime.exec(
            project,
            ExecRequest(service: .web, command: ["bash", "-c", command], stdout: output, stderr: output)
        )
        hooks.append(PostStartResult(command: command, exitCode: result.exitCode))
        if result.exitCode != 0 {
            let stderr = result.stderr.map { String(decoding: $0, as: UTF8.self) } ?? ""
            throw DrupalError(
                .postStartFailed,
                "post_start command failed with exit code \(result.exitCode): \(command)",
                details: stderr.isEmpty ? [] : [.init(path: "post_start[\(hooks.count - 1)]", message: String(stderr.suffix(2000)))],
                hint: "The containers are running; fix the command and run `drupal restart`."
            )
        }
    }
    return CommandOutput(
        data: LifecycleResult(project: ProjectRef(project), status: status, postStart: hooks),
        text: "Started \(project.name): \(project.url)",
        warnings: project.warnings
    )
}
