// The `drupal` CLI: a local Drupal development environment built on Apple's
// Containerization framework. See docs/requirements/ for the v1.0 scope.

import ArgumentParser
import Foundation

/// Root command for the `drupal` binary.
///
/// Later sorties register their subcommands by adding them to
/// `configuration.subcommands`; the command manifest (`--manifest`,
/// `describe-commands`) picks them up automatically. Invoked with no
/// arguments, the root command prints its help text and exits 0.
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
            // Sortie 7a: agent contract
            DescribeCommandsCommand.self,
        ]
    )

    @Flag(name: .customLong("manifest"), help: "Print the machine-readable command manifest as JSON (same as `drupal describe-commands`).")
    public var manifest = false

    public init() {}

    public func run() async throws {
        guard manifest else { throw CleanExit.helpRequest(self) }
        LifecycleEnvironment.current.writeOutput(try CommandManifest.jsonString())
    }

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
        } catch {
            let format = OutputFormatResolver.live.resolve(jsonFlag: jsonFlagPresent(in: arguments))
            if let rendered = renderedError(for: error, format: format) {
                FileHandle.standardError.write(Data((rendered.text + "\n").utf8))
                Foundation.exit(rendered.status)
            }
            exit(withError: error)
        }
    }

    /// Whether `--json` appears among drupal's own arguments (before a `--`
    /// terminator, after which arguments belong to a remote command).
    public static func jsonFlagPresent(in arguments: [String]) -> Bool {
        arguments.prefix(while: { $0 != "--" }).contains("--json")
    }

    /// The stderr text and exit status for a failed command, or nil when
    /// ArgumentParser's own handling applies (help/version output, a text-mode
    /// usage error, or an `ExitCode` thrown to pass a remote status through).
    ///
    /// `DrupalError`s always render (JSON or text) with their documented code.
    /// In JSON mode every other error also renders as the `ErrorReport`
    /// envelope: `usageError` (64) for parse/validation failures, `failure` (1)
    /// for anything else, so no command prints a bare Swift error under JSON.
    public static func renderedError(for error: Error, format: OutputFormat) -> (status: Int32, text: String)? {
        if let drupalError = error as? DrupalError {
            return (drupalError.exitCode.rawValue, errorOutput(for: drupalError, format: format))
        }
        guard format == .json, !(error is ArgumentParser.ExitCode) else { return nil }
        let status = exitCode(for: error)
        guard status != .success else { return nil }
        let name = status == .validationFailure ? CommandManifest.usageErrorName : SwiftDrupal.ExitCode.failure.name
        let report = ErrorReport(
            error: .init(code: name, exitCode: status.rawValue, message: message(for: error), remedy: nil))
        return (status.rawValue, report.jsonString())
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
