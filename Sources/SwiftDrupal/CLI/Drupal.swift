// The `drupal` CLI: a local Drupal development environment built on Apple's
// Containerization framework. See docs/requirements/ for the v1.0 scope.

import ArgumentParser
import Foundation

/// Root command for the `drupal` binary.
///
/// Later sorties register their subcommands by adding them to
/// `configuration.subcommands`. Invoked with no arguments, the root command
/// prints its help text and exits 0.
public struct Drupal: AsyncParsableCommand {
    public static let version = "0.1.0"

    public static let configuration = CommandConfiguration(
        commandName: "drupal",
        abstract: "Run a local Drupal development environment on Apple's container runtime.",
        version: version,
        subcommands: [
            ServiceCommand.self,
            // Sortie 4: lifecycle
            InitCommand.self, StartCommand.self, StopCommand.self, RestartCommand.self, StatusCommand.self,
            DeleteCommand.self, ConfigCommand.self, ValidateCommand.self,
            // Sortie 5: database
            ImportDBCommand.self, ExportDBCommand.self,
            // Sortie 6a: dev tools
            ExecCommand.self, SSHCommand.self,
            // Sortie 6b: logs
            LogsCommand.self,
        ]
    )

    public init() {}

    /// Entry point used by the `drupal` executable.
    ///
    /// Routes `DrupalError`s to their documented `ExitCode`; every other error
    /// (parse/validation/help/version) goes through ArgumentParser's standard
    /// handling.
    public static func main() async {
        await main(CommandLine.arguments.dropFirst().map { $0 })
    }

    public static func main(_ arguments: [String]) async {
        do {
            var command = try parseAsRoot(arguments)
            if var asyncCommand = command as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
        } catch let error as DrupalError {
            let format = OutputFormatResolver.live.resolve(jsonFlag: arguments.contains("--json"))
            FileHandle.standardError.write(Data((errorOutput(for: error, format: format) + "\n").utf8))
            Foundation.exit(error.exitCode.rawValue)
        } catch {
            exit(withError: error)
        }
    }

    /// Rendered stderr text for a `DrupalError`: the JSON `ErrorReport` in JSON
    /// mode, otherwise `Error: …` plus the remedy when there is one.
    public static func errorOutput(for error: DrupalError, format: OutputFormat) -> String {
        switch format {
        case .json:
            return error.report.jsonString()
        case .text:
            var text = "Error: \(error.description)"
            if let remedy = error.remedy { text += "\nRun `\(remedy)` to fix this." }
            return text
        }
    }

    /// Exit status the process terminates with for `error`.
    ///
    /// `DrupalError`s map to their `ExitCode`; anything else defers to
    /// ArgumentParser's own mapping (e.g. 0 for `--help`, 64 for usage errors).
    public static func exitStatus(for error: Error) -> Int32 {
        if let drupalError = error as? DrupalError {
            return drupalError.exitCode.rawValue
        }
        return exitCode(for: error).rawValue
    }
}
