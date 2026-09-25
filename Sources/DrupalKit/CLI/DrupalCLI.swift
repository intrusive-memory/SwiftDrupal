import ArgumentParser
import Foundation

public enum DrupalVersion {
    public static let current = "0.1.0-dev"
}

public struct RootCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "drupal",
        abstract: "Local Drupal development environments on Apple's Containerization framework.",
        discussion: """
            Every command accepts --json and prints a single JSON envelope when stdout \
            is not a TTY. Run `drupal describe-commands --json` for the machine-readable \
            command manifest. See docs/cli-contract.md.
            """,
        version: DrupalVersion.current,
        subcommands: [
            InitCommand.self,
            ConfigCommand.self,
            ValidateCommand.self,
            StartCommand.self,
            StopCommand.self,
            RestartCommand.self,
            StatusCommand.self,
            DeleteCommand.self,
            ExecCommand.self,
            SSHCommand.self,
            LogsCommand.self,
            ImportDBCommand.self,
            ExportDBCommand.self,
            ResolverCommand.self,
            DescribeCommandsCommand.self,
        ]
    )

    public init() {}
}

/// Process entry point. Owns argument parsing so that usage errors also get
/// the JSON envelope and exit code 2, instead of ArgumentParser's own
/// output and exit 64.
public enum DrupalCLI {
    public static func main() async -> Int32 {
        await run(Array(CommandLine.arguments.dropFirst()), environment: .live())
    }

    public static func run(_ arguments: [String], environment: CLIEnvironment) async -> Int32 {
        await CLIEnvironment.$current.withValue(environment) {
            await dispatch(arguments, environment)
        }
    }

    private static func dispatch(_ arguments: [String], _ env: CLIEnvironment) async -> Int32 {
        let command: any ParsableCommand
        do {
            command = try RootCommand.parseAsRoot(arguments)
        } catch {
            return reportParseFailure(error, arguments, env)
        }
        do {
            if var asyncCommand = command as? any AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                var syncCommand = command
                try syncCommand.run()
            }
            return 0
        } catch let exit as ExitCode {
            return exit.rawValue
        } catch where RootCommand.exitCode(for: error) == .success {
            // Root invoked without a subcommand: show help.
            env.stdout.write(RootCommand.fullMessage(for: error) + "\n")
            return 0
        } catch {
            let wrapped = DrupalError(.internalError, "unexpected error: \(error)")
            write(wrapped, command: commandName(in: arguments), arguments, env)
            return wrapped.status.rawValue
        }
    }

    private static func reportParseFailure(_ error: any Error, _ arguments: [String], _ env: CLIEnvironment) -> Int32 {
        // --help, --version, --experimental-dump-help: requested output, exit 0.
        if RootCommand.exitCode(for: error) == .success {
            env.stdout.write(RootCommand.fullMessage(for: error) + "\n")
            return 0
        }
        let name = commandName(in: arguments)
        let usage = DrupalError(
            .usageError,
            RootCommand.message(for: error),
            hint: name == "drupal" ? "Run `drupal --help` or `drupal describe-commands`." : "Run `drupal \(name) --help`."
        )
        if wantsJSON(arguments, env) {
            write(usage, command: name, arguments, env)
        } else {
            env.stderr.write(RootCommand.fullMessage(for: error) + "\n")
        }
        return usage.status.rawValue
    }

    private static func write(_ error: DrupalError, command: String, _ arguments: [String], _ env: CLIEnvironment) {
        if wantsJSON(arguments, env) {
            env.stdout.write(Envelope.failure(command, error).jsonLine() + "\n")
        } else {
            env.stderr.write(CommandContext.humanReadable(error))
        }
    }

    /// Output mode when parsing failed and GlobalOptions is unavailable.
    static func wantsJSON(_ arguments: [String], _ env: CLIEnvironment) -> Bool {
        if let last = arguments.last(where: { $0 == "--json" || $0 == "--no-json" }) {
            return last == "--json"
        }
        return !env.stdoutIsTTY
    }

    /// The subcommand named in `arguments`, or "drupal"; nested commands are
    /// space-joined ("resolver install").
    static func commandName(in arguments: [String]) -> String {
        var words = arguments.filter { !$0.hasPrefix("-") }[...]
        var level = RootCommand.configuration.subcommands
        var path: [String] = []
        while let word = words.popFirst(),
              let match = level.first(where: { $0._commandName == word || $0.configuration.aliases.contains(word) }) {
            path.append(match._commandName)
            level = match.configuration.subcommands
            if level.isEmpty { break }
        }
        return path.isEmpty ? "drupal" : path.joined(separator: " ")
    }
}
