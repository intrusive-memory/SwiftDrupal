import ArgumentParser
import Foundation

// exec / ssh / logs / import-db / export-db: commands that run inside the
// containers. All go through ContainerRuntime.exec or .logs.

struct ExecCommand: DrupalCommand {
    static let configuration = CommandConfiguration(
        commandName: "exec",
        abstract: "Run a command in the web or db container.",
        discussion: """
            Everything after the first non-option argument is the command, e.g. \
            `drupal exec drush status` or `drupal exec --service db -- mysql -e 'SHOW TABLES'`. \
            The process exits with the command's own exit code. In JSON mode the command's \
            output is captured into data.stdout/data.stderr and data.exit_code; `ok` reports \
            whether the command could be run, not whether it succeeded.
            """
    )

    @OptionGroup var global: GlobalOptions

    @Option(help: "Container to run in.")
    var service: Service = .web

    @Argument(parsing: .captureForPassthrough, help: ArgumentHelp("The command and its arguments.", valueName: "command"))
    var command: [String]

    func validate() throws {
        guard !command.isEmpty else { throw ValidationError("missing the command to run, e.g. `drupal exec drush status`") }
    }

    struct Result: Encodable, Sendable {
        var service: Service
        var command: [String]
        var exitCode: Int32
        var stdout: String?
        var stderr: String?
        enum CodingKeys: String, CodingKey {
            case service, command, stdout, stderr
            case exitCode = "exit_code"
        }
    }

    func execute(_ context: CommandContext) async throws(DrupalError) -> CommandOutput {
        let project = try context.runnableProject()
        let env = context.environment
        let interactive = !context.jsonMode && env.stdinIsTTY && env.stdoutIsTTY
        let output: ExecRequest.Output = context.jsonMode ? .capture : .inherit
        let result = try await context.runtime.exec(
            project,
            ExecRequest(service: service, command: command, tty: interactive, stdin: context.jsonMode ? .none : .inherit, stdout: output, stderr: output)
        )
        return CommandOutput(
            data: Result(
                service: service,
                command: command,
                exitCode: result.exitCode,
                stdout: result.stdout.map { String(decoding: $0, as: UTF8.self) },
                stderr: result.stderr.map { String(decoding: $0, as: UTF8.self) }
            ),
            text: "",
            exitCode: result.exitCode
        )
    }
}

struct SSHCommand: DrupalCommand {
    static let configuration = CommandConfiguration(
        commandName: "ssh",
        abstract: "Open an interactive shell in the web or db container.",
        discussion: "Requires a TTY on stdin and stdout; in JSON mode or without a TTY it fails with exit 2 (use `exec` instead). Exits with the shell's exit code."
    )

    @OptionGroup var global: GlobalOptions

    @Option(help: "Container to open the shell in.")
    var service: Service = .web

    func execute(_ context: CommandContext) async throws(DrupalError) -> CommandOutput {
        let env = context.environment
        guard !context.jsonMode, env.stdinIsTTY, env.stdoutIsTTY else {
            throw DrupalError(.usageError, "ssh needs an interactive terminal", hint: "Use `drupal exec <command>` for non-interactive use.")
        }
        let project = try context.runnableProject()
        let result = try await context.runtime.exec(
            project,
            ExecRequest(service: service, command: ["bash", "-l"], tty: true, stdin: .inherit)
        )
        return CommandOutput(data: nil, text: "", exitCode: result.exitCode)
    }
}

struct LogsCommand: DrupalCommand {
    static let configuration = CommandConfiguration(
        commandName: "logs",
        abstract: "Show web and db logs merged into one timestamp-ordered stream.",
        discussion: """
            JSON mode prints one object per line, {"timestamp","service","stream","message"}, \
            then a final envelope line (the only line with an "ok" key) with data.lines. \
            With --follow the stream runs until interrupted and has no final envelope. \
            Text mode prints `[service] time message`, colorized by service on a TTY.
            """
    )

    @OptionGroup var global: GlobalOptions

    @Option(help: "Only this service. Repeatable. Default: web and db.")
    var service: [Service] = []

    @Flag(name: [.short, .long], help: "Keep streaming new lines.")
    var follow = false

    @Option(help: ArgumentHelp("Show only the last N lines per service before streaming.", valueName: "lines"))
    var tail: Int?

    func validate() throws {
        if let tail, tail < 0 { throw ValidationError("--tail must be zero or more") }
    }

    struct Summary: Encodable, Sendable {
        var lines: Int
    }

    func execute(_ context: CommandContext) async throws(DrupalError) -> CommandOutput {
        let project = try context.runnableProject()
        let request = LogRequest(services: service.isEmpty ? Service.allCases : service, follow: follow, tail: tail)
        let color = !context.jsonMode && context.environment.stdoutIsTTY
        let time = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        var count = 0
        do {
            for try await entry in context.runtime.logs(project, request) {
                count += 1
                let tag = color ? Self.colored(entry.service) : "[\(entry.service.rawValue)]"
                context.emitRecord(LogRecord(entry), text: "\(tag) \(entry.timestamp.formatted(time)) \(entry.message)")
            }
        } catch let error as DrupalError {
            throw error
        } catch {
            throw DrupalError(.containerOperationFailed, "log stream failed: \(error)")
        }
        return CommandOutput(data: Summary(lines: count), text: "")
    }

    static func colored(_ service: Service) -> String {
        let code = service == .web ? "36" : "35"  // cyan, magenta
        return "\u{1B}[\(code)m[\(service.rawValue)]\u{1B}[0m"
    }
}

/// `LogEntry` with an ISO 8601 timestamp string, for JSON lines.
struct LogRecord: Encodable, Sendable {
    var timestamp: String
    var service: Service
    var stream: LogEntry.Stream
    var message: String

    init(_ e: LogEntry) {
        timestamp = e.timestamp.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        service = e.service
        stream = e.stream
        message = e.message
    }
}

/// Credentials and database name baked into ddev-dbserver.
enum DatabaseCommands {
    static let database = "db"
    static let importSQL = [
        "bash", "-c",
        "mysql -uroot -proot -e 'DROP DATABASE IF EXISTS db; CREATE DATABASE db;' && mysql -uroot -proot db",
    ]
    static let exportSQL = ["mysqldump", "-uroot", "-proot", "--single-transaction", "--routines", "db"]
}

struct DBTransferResult: Encodable, Sendable {
    var database: String
    /// File path, or "stdin"/"stdout".
    var source: String?
    var destination: String?
}

struct ImportDBCommand: DrupalCommand {
    static let configuration = CommandConfiguration(
        commandName: "import-db",
        abstract: "Replace the project database with a plain SQL dump.",
        discussion: "Reads --file, or stdin when it is piped. Drops and recreates the database first. Compressed dumps are not supported in v1.0; decompress first."
    )

    @OptionGroup var global: GlobalOptions

    @Option(help: ArgumentHelp("Path to a plain .sql dump. Default: stdin (must be piped).", valueName: "path"))
    var file: String?

    func execute(_ context: CommandContext) async throws(DrupalError) -> CommandOutput {
        let project = try context.project()
        let input: ExecRequest.Input
        let source: String
        if let file {
            let url = URL(filePath: file, relativeTo: context.environment.workingDirectory).standardizedFileURL
            if ["gz", "zip", "bz2", "xz", "zst", "tgz"].contains(url.pathExtension.lowercased()) {
                throw DrupalError(.usageError, "compressed dumps are not supported in v1.0: \(file)", hint: "Decompress it and pass the .sql file.")
            }
            guard FileManager.default.isReadableFile(atPath: url.filePath) else {
                throw DrupalError(.ioError, "cannot read \(url.filePath)")
            }
            input = .file(url)
            source = url.filePath
        } else {
            guard !context.environment.stdinIsTTY else {
                throw DrupalError(.usageError, "no SQL input: pass --file or pipe a dump on stdin")
            }
            input = .inherit
            source = "stdin"
        }
        try context.environment.platform.check()
        let result = try await context.runtime.exec(
            project,
            ExecRequest(service: .db, command: DatabaseCommands.importSQL, stdin: input, stdout: .capture, stderr: .capture)
        )
        guard result.exitCode == 0 else {
            throw DrupalError(
                .containerOperationFailed,
                "database import failed (mysql exit code \(result.exitCode))",
                details: result.stderr.map { [.init(message: String(String(decoding: $0, as: UTF8.self).suffix(2000)))] } ?? []
            )
        }
        return CommandOutput(
            data: DBTransferResult(database: DatabaseCommands.database, source: source),
            text: "Imported \(source) into database '\(DatabaseCommands.database)'"
        )
    }
}

struct ExportDBCommand: DrupalCommand {
    static let configuration = CommandConfiguration(
        commandName: "export-db",
        abstract: "Write the project database as a plain SQL dump.",
        discussion: "Writes --file, or stdout in text mode. JSON mode requires --file. Refuses to overwrite an existing file (exit 5) unless --force."
    )

    @OptionGroup var global: GlobalOptions

    @Option(help: ArgumentHelp("Destination .sql path. Default: stdout (text mode only).", valueName: "path"))
    var file: String?

    @Flag(help: "Overwrite --file if it exists.")
    var force = false

    func execute(_ context: CommandContext) async throws(DrupalError) -> CommandOutput {
        let project = try context.project()
        let output: ExecRequest.Output
        let destination: String
        if let file {
            let url = URL(filePath: file, relativeTo: context.environment.workingDirectory).standardizedFileURL
            if FileManager.default.fileExists(atPath: url.filePath), !force {
                throw DrupalError(.alreadyExists, "\(url.filePath) already exists", hint: "Pass --force to overwrite it.")
            }
            output = .file(url)
            destination = url.filePath
        } else {
            guard !context.jsonMode else {
                throw DrupalError(.usageError, "export-db needs --file in JSON mode (stdout carries the envelope)")
            }
            output = .inherit
            destination = "stdout"
        }
        try context.environment.platform.check()
        let result = try await context.runtime.exec(
            project,
            ExecRequest(service: .db, command: DatabaseCommands.exportSQL, stdout: output, stderr: .capture)
        )
        guard result.exitCode == 0 else {
            throw DrupalError(
                .containerOperationFailed,
                "database export failed (mysqldump exit code \(result.exitCode))",
                details: result.stderr.map { [.init(message: String(String(decoding: $0, as: UTF8.self).suffix(2000)))] } ?? []
            )
        }
        return CommandOutput(
            data: DBTransferResult(database: DatabaseCommands.database, destination: destination),
            text: destination == "stdout" ? "" : "Exported database '\(DatabaseCommands.database)' to \(destination)"
        )
    }
}
