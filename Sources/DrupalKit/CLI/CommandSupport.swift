import ArgumentParser
import Foundation

// Shared plumbing for every subcommand: output-mode selection, envelope vs.
// text rendering, project lookup, and error → exit-code mapping. A command
// implements `execute` and returns a `CommandOutput`; it never prints its
// own result or error.

public struct CommandOutput: Sendable {
    /// Envelope `data` in JSON mode.
    public var data: (any Encodable & Sendable)?
    /// What a person sees on stdout in text mode.
    public var text: String
    public var warnings: [String]
    /// Process exit code override (`exec`/`ssh` propagate the child's code).
    public var exitCode: Int32

    public init(data: (any Encodable & Sendable)?, text: String, warnings: [String] = [], exitCode: Int32 = 0) {
        self.data = data
        self.text = text
        self.warnings = warnings
        self.exitCode = exitCode
    }
}

public struct CommandContext: Sendable {
    public let environment: CLIEnvironment
    public let command: String
    public let jsonMode: Bool
    /// `--project-dir` resolved against the working directory, or the working directory.
    public let directory: URL

    init(environment: CLIEnvironment, command: String, global: GlobalOptions) {
        self.environment = environment
        self.command = command
        jsonMode = global.json ?? !environment.stdoutIsTTY
        if let dir = global.projectDir {
            directory = URL(filePath: dir, directoryHint: .isDirectory, relativeTo: environment.workingDirectory).standardizedFileURL
        } else {
            directory = environment.workingDirectory.standardizedFileURL
        }
    }

    public var runtime: any ContainerRuntime { environment.runtime }

    public func project() throws(DrupalError) -> ResolvedProject {
        try ResolvedProject.locate(from: directory)
    }

    /// Resolves the project and checks the host can run containers.
    public func runnableProject() throws(DrupalError) -> ResolvedProject {
        let project = try project()
        try environment.platform.check()
        return project
    }

    // MARK: Output

    func emit(_ output: CommandOutput) {
        if jsonMode {
            environment.stdout.write(Envelope.success(command, data: output.data, warnings: output.warnings).jsonLine() + "\n")
        } else {
            for w in output.warnings { environment.stderr.write("warning: \(w)\n") }
            if !output.text.isEmpty {
                environment.stdout.write(output.text.hasSuffix("\n") ? output.text : output.text + "\n")
            }
        }
    }

    func emit(_ error: DrupalError) {
        if jsonMode {
            environment.stdout.write(Envelope.failure(command, error).jsonLine() + "\n")
        } else {
            environment.stderr.write(Self.humanReadable(error))
        }
    }

    /// One JSON line (JSON mode) or one text line, for streaming commands.
    func emitRecord(_ record: some Encodable, text: String) {
        environment.stdout.write((jsonMode ? JSONOutput.line(record) : text) + "\n")
    }

    static func humanReadable(_ error: DrupalError) -> String {
        var out = "error: \(error.message)\n"
        if error.details.count > 1 || (error.details.count == 1 && !error.message.contains(error.details[0].message)) {
            for d in error.details {
                let loc = [d.line.map { "line \($0)" }, d.path].compactMap { $0 }.joined(separator: ", ")
                out += loc.isEmpty ? "  - \(d.message)\n" : "  - \(loc): \(d.message)\n"
            }
        }
        if let hint = error.hint { out += "hint: \(hint)\n" }
        return out
    }
}

/// Conformed to by every subcommand; supplies `run()`.
public protocol DrupalCommand: AsyncParsableCommand {
    var global: GlobalOptions { get }
    func execute(_ context: CommandContext) async throws(DrupalError) -> CommandOutput
}

extension DrupalCommand {
    public mutating func run() async throws {
        let context = CommandContext(environment: CLIEnvironment.current, command: Self._commandName, global: global)
        let code: Int32
        do {
            let output = try await execute(context)
            context.emit(output)
            code = output.exitCode
        } catch {
            context.emit(error)
            code = error.status.rawValue
        }
        if code != 0 { throw ExitCode(code) }
    }
}
