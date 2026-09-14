import ArgumentParser
import Foundation

/// How a command renders its results.
public enum OutputFormat: String, Sendable, Codable, CaseIterable {
    /// Human-oriented text for an interactive terminal.
    case text
    /// Structured JSON for agents and pipelines.
    case json
}

/// Decides between text and JSON output: JSON when `--json` is passed OR when
/// stdout is not attached to a TTY.
///
/// TTY detection is injectable so tests can exercise both paths.
public struct OutputFormatResolver: Sendable {
    public let isTTY: @Sendable () -> Bool

    public init(isTTY: @escaping @Sendable () -> Bool) {
        self.isTTY = isTTY
    }

    /// Resolver backed by `isatty(STDOUT_FILENO)`.
    public static let live = OutputFormatResolver { isatty(STDOUT_FILENO) != 0 }

    public func resolve(jsonFlag: Bool) -> OutputFormat {
        if jsonFlag { return .json }
        return isTTY() ? .text : .json
    }
}

/// Shared `--json` flag. Subcommands include it with
/// `@OptionGroup var output: OutputOptions` and call `format()`.
public struct OutputOptions: ParsableArguments, Sendable {
    @Flag(name: .long, help: "Emit structured JSON output (default when stdout is not a TTY).")
    public var json = false

    public init() {}

    public func format(using resolver: OutputFormatResolver = .live) -> OutputFormat {
        resolver.resolve(jsonFlag: json)
    }
}
