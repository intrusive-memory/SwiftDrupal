import ArgumentParser
import Foundation

// The machine-readable command manifest (`drupal --manifest` /
// `drupal describe-commands`). The command tree, names, aliases, hidden flags,
// and every option/flag/argument come from ArgumentParser's own introspection
// (its `--experimental-dump-help` document) walked alongside each command's
// `CommandConfiguration`, so a newly registered subcommand appears without
// touching this file. Value types come from reflecting each command's property
// wrappers. `ManifestAnnotated` adds contract facts ArgumentParser cannot know
// (needs the service, destructive defaults); it is optional. The emitted shape
// is described by docs/schema/manifest.json.

/// `drupal describe-commands`: prints the command manifest. Always JSON.
public struct DescribeCommandsCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "describe-commands",
        abstract: "Print every command, option, flag, and exit code as JSON (same as `drupal --manifest`).",
        discussion: "Output is always JSON, whether or not stdout is a TTY; --json is accepted and changes nothing."
    )

    @OptionGroup public var output: OutputOptions

    public init() {}

    public func run() async throws {
        LifecycleEnvironment.current.writeOutput(try CommandManifest.jsonString())
    }
}

/// Contract facts a command can publish in the manifest beyond what
/// ArgumentParser introspection provides.
public protocol ManifestAnnotated {
    /// Whether the command talks to the drupal service (and exits 14 when it is unreachable).
    static var manifestRequiresService: Bool { get }
    /// Behavior notes an agent needs (destructive defaults, output routing, signals, TTY handling).
    static var manifestNotes: [String] { get }
}

extension ManifestAnnotated {
    public static var manifestNotes: [String] { [] }
}

// MARK: - Document

public struct CommandManifest: Codable, Equatable, Sendable {
    public struct Tool: Codable, Equatable, Sendable {
        public var name: String
        public var version: String
        public var abstract: String
    }

    public struct JSONOutput: Codable, Equatable, Sendable {
        public var flag: String
        public var automaticWhenStdoutIsNotATTY: Bool
        public var description: String
        public var errorEnvelope: String
    }

    public struct ExitCodeEntry: Codable, Equatable, Sendable {
        public var code: Int32
        public var name: String
        public var meaning: String
        /// `drupal` (the `ExitCode` enum) or `argument-parser` (reserved by ArgumentParser).
        public var source: String
    }

    public struct Argument: Codable, Equatable, Sendable {
        /// `positional`, `option`, or `flag`.
        public var kind: String
        /// Spellings as typed, e.g. `["-f", "--follow"]`. Empty for positionals.
        public var names: [String]
        public var preferredName: String?
        public var valueName: String?
        /// Swift value type (`String`, `Int`, `Bool`, `[String]`, …) when derivable.
        public var type: String?
        public var isRepeating: Bool
        public var required: Bool
        public var defaultValue: String?
        public var allowedValues: [String]?
        public var help: String?
        public var discussion: String?
        public var hidden: Bool
        /// ArgumentParser parsing strategy (`default`, `postTerminator`, …).
        public var parsingStrategy: String
    }

    public struct Command: Codable, Equatable, Sendable {
        /// Full path below the tool, e.g. `service install`.
        public var name: String
        public var commandName: String
        /// Path of the parent command, or nil for top-level commands.
        public var parent: String?
        public var abstract: String
        public var discussion: String?
        public var aliases: [String]
        /// Not shown in help (e.g. `service run`, which launchd invokes).
        public var hidden: Bool
        /// Full paths of direct subcommands.
        public var subcommands: [String]
        public var arguments: [Argument]
        /// Nil when the command publishes no annotation.
        public var requiresService: Bool?
        public var notes: [String]
    }

    public var schemaVersion: Int
    public var tool: Tool
    public var invocations: [String]
    public var jsonOutput: JSONOutput
    public var exitCodes: [ExitCodeEntry]
    public var exitCodeNotes: [String]
    public var rootArguments: [Argument]
    /// Every registered command below the root, depth-first in registration order.
    public var commands: [Command]
}

extension CommandManifest {
    public static let schemaVersion = 1
    static let usageErrorName = "usageError"

    /// Builds the manifest for `root` (the `drupal` command by default).
    public static func build(root: any ParsableCommand.Type = Drupal.self) throws -> CommandManifest {
        let dump = try DumpedCommand.load(root: root)
        var commands: [Command] = []
        for subcommand in root.configuration.subcommands {
            try collect(subcommand, parent: nil, dump: dump, into: &commands)
        }

        let exitCodes =
            SwiftDrupal.ExitCode.allCases.map {
                ExitCodeEntry(code: $0.rawValue, name: $0.name, meaning: $0.meaning, source: "drupal")
            } + [
                ExitCodeEntry(
                    code: ArgumentParser.ExitCode.validationFailure.rawValue, name: usageErrorName,
                    meaning: "The command line could not be parsed or failed validation (unknown flag, missing argument, bad value).",
                    source: "argument-parser")
            ]

        return CommandManifest(
            schemaVersion: schemaVersion,
            tool: Tool(
                name: root.configuration.commandName ?? "drupal", version: root.configuration.version,
                abstract: root.configuration.abstract),
            invocations: ["drupal --manifest", "drupal describe-commands"],
            jsonOutput: JSONOutput(
                flag: "--json",
                automaticWhenStdoutIsNotATTY: true,
                description:
                    "Commands emit structured JSON on stdout when --json is passed or stdout is not a TTY, and human text otherwise. The manifest itself is always JSON.",
                errorEnvelope:
                    "On failure in JSON mode, stderr carries {\"error\":{\"code\":<exit code name>,\"exitCode\":<int>,\"message\":<string>,\"remedy\":<string, omitted when there is none>}}."
            ),
            exitCodes: exitCodes,
            exitCodeNotes: [
                "exec and ssh exit with the remote command's own exit status, which may be any value.",
                "exec and ssh interrupted by a signal restore the terminal and exit 128+signal (130 for SIGINT).",
                "logs --follow interrupted by SIGINT exits 0.",
                "A post_start command exiting non-zero makes start and restart exit 12 (containerFailedToStart) after printing the report.",
            ],
            rootArguments: try arguments(for: root, dumped: dump.arguments ?? []),
            commands: commands
        )
    }

    /// The manifest as pretty-printed JSON with sorted keys.
    public static func jsonString(root: any ParsableCommand.Type = Drupal.self) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(build(root: root)), as: UTF8.self)
    }

    private static func collect(
        _ type: any ParsableCommand.Type, parent: String?, dump: DumpedCommand, into commands: inout [Command]
    ) throws {
        let configuration = type.configuration
        let commandName = configuration.commandName ?? kebabCase(String(describing: type))
        guard let dumped = dump.subcommands?.first(where: { $0.commandName == commandName }) else { return }
        let path = parent.map { "\($0) \(commandName)" } ?? commandName
        let annotated = type as? any ManifestAnnotated.Type

        commands.append(
            Command(
                name: path,
                commandName: commandName,
                parent: parent,
                abstract: configuration.abstract,
                discussion: configuration.discussion.isEmpty ? nil : configuration.discussion,
                aliases: configuration.aliases,
                hidden: !configuration.shouldDisplay,
                subcommands: configuration.subcommands.map {
                    "\(path) \($0.configuration.commandName ?? kebabCase(String(describing: $0)))"
                },
                arguments: try arguments(for: type, dumped: dumped.arguments ?? []),
                requiresService: annotated?.manifestRequiresService,
                notes: annotated?.manifestNotes ?? []
            ))

        for subcommand in configuration.subcommands {
            try collect(subcommand, parent: path, dump: dumped, into: &commands)
        }
    }

    private static func arguments(for type: any ParsableArguments.Type, dumped: [DumpedArgument]) throws -> [Argument] {
        let types = ValueTypeReflector.valueTypes(of: type)
        return dumped.map { argument in
            let names = (argument.names ?? []).map(\.spelled)
            let key: String? =
                switch argument.kind {
                case "positional": argument.valueName
                default: argument.preferredName?.kind == "short" ? nil : argument.preferredName?.name
                }
            var valueType = key.flatMap { types[$0] }
            if valueType == nil {
                // Named arguments match on any long spelling.
                valueType = argument.names?.lazy.filter { $0.kind != "short" }.compactMap { types[$0.name] }.first
            }
            if valueType == nil, argument.kind == "flag" { valueType = "Bool" }
            return Argument(
                kind: argument.kind,
                names: names,
                preferredName: argument.preferredName?.spelled,
                valueName: argument.kind == "flag" ? nil : argument.valueName,
                type: valueType,
                isRepeating: argument.isRepeating ?? false,
                required: argument.kind != "flag" && !(argument.isOptional ?? false),
                defaultValue: argument.defaultValue ?? (valueType == "Bool" && argument.kind == "flag" ? "false" : nil),
                allowedValues: argument.allValueStrings ?? argument.allValues,
                help: argument.abstract,
                discussion: argument.discussion,
                hidden: !(argument.shouldDisplay ?? true),
                parsingStrategy: argument.parsingStrategy ?? "default"
            )
        }
    }

    /// `camelCase` → `camel-case`, ArgumentParser's default long-name spelling.
    static func kebabCase(_ name: String) -> String {
        var result = ""
        for character in name {
            if character.isUppercase {
                if !result.isEmpty { result.append("-") }
                result.append(contentsOf: character.lowercased())
            } else {
                result.append(character)
            }
        }
        return result
    }
}

// MARK: - ArgumentParser introspection document

/// The subset of ArgumentParser's `--experimental-dump-help` document
/// (ToolInfoV0) the manifest reads. Every field is optional so a newer
/// ArgumentParser that adds or omits keys still decodes.
struct DumpedCommand: Decodable {
    var commandName: String
    var subcommands: [DumpedCommand]?
    var arguments: [DumpedArgument]?

    private struct Envelope: Decodable {
        var command: DumpedCommand
    }

    static func load(root: any ParsableCommand.Type) throws -> DumpedCommand {
        let text: String
        do {
            _ = try root.parseAsRoot(["--experimental-dump-help"])
            throw DrupalError.platformUnavailable("ArgumentParser did not produce its introspection document")
        } catch let error as DrupalError {
            throw error
        } catch {
            text = root.fullMessage(for: error)
        }
        return try JSONDecoder().decode(Envelope.self, from: Data(text.utf8)).command
    }
}

struct DumpedArgument: Decodable {
    struct Name: Decodable {
        var kind: String
        var name: String

        var spelled: String {
            switch kind {
            case "short": "-\(name)"
            case "longWithSingleDash": "-\(name)"
            default: "--\(name)"
            }
        }
    }

    var kind: String
    var shouldDisplay: Bool?
    var isOptional: Bool?
    var isRepeating: Bool?
    var parsingStrategy: String?
    var names: [Name]?
    var preferredName: Name?
    var valueName: String?
    var defaultValue: String?
    var allValues: [String]?
    var allValueStrings: [String]?
    var abstract: String?
    var discussion: String?
}

// MARK: - Value types by reflection

/// Property wrappers that can report their value type.
private protocol ManifestValueTyped {
    static var manifestValueType: String { get }
}

/// `@OptionGroup`s, whose arguments are reflected recursively.
private protocol ManifestOptionGroup {
    static var manifestGroupType: any ParsableArguments.Type { get }
}

extension Option: ManifestValueTyped {
    fileprivate static var manifestValueType: String { ValueTypeReflector.typeName(Value.self) }
}

extension Flag: ManifestValueTyped {
    fileprivate static var manifestValueType: String { ValueTypeReflector.typeName(Value.self) }
}

extension Argument: ManifestValueTyped {
    fileprivate static var manifestValueType: String { ValueTypeReflector.typeName(Value.self) }
}

extension OptionGroup: ManifestOptionGroup {
    fileprivate static var manifestGroupType: any ParsableArguments.Type { Value.self }
}

enum ValueTypeReflector {
    /// Value type names keyed by the argument's default spelling (kebab-cased
    /// property name), including arguments declared in option groups.
    static func valueTypes(of type: any ParsableArguments.Type) -> [String: String] {
        var result: [String: String] = [:]
        for child in Mirror(reflecting: type.init()).children {
            guard let label = child.label else { continue }
            let key = CommandManifest.kebabCase(label.hasPrefix("_") ? String(label.dropFirst()) : label)
            let wrapperType = Swift.type(of: child.value)
            if let typed = wrapperType as? any ManifestValueTyped.Type {
                result[key] = typed.manifestValueType
            } else if let group = wrapperType as? any ManifestOptionGroup.Type {
                result.merge(valueTypes(of: group.manifestGroupType)) { existing, _ in existing }
            }
        }
        return result
    }

    /// `Optional<String>` → `String`, `Array<String>` → `[String]`.
    static func typeName(_ type: Any.Type) -> String {
        normalize(String(describing: type))
    }

    static func normalize(_ name: String) -> String {
        if name.hasPrefix("Optional<"), name.hasSuffix(">") {
            return normalize(String(name.dropFirst("Optional<".count).dropLast()))
        }
        if name.hasPrefix("Array<"), name.hasSuffix(">") {
            return "[\(normalize(String(name.dropFirst("Array<".count).dropLast())))]"
        }
        return name
    }
}
