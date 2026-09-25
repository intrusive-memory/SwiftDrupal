import ArgumentParser
import Foundation

// The machine-readable command manifest (`drupal describe-commands`).
// Generated, not hand-maintained: the command tree, flags, help text, and
// allowed values come from ArgumentParser's own `--experimental-dump-help`
// JSON; value types come from reflecting each command's property wrappers
// (the dump carries no types). Adding a command or flag updates it for free.

public struct CommandManifest: Encodable, Sendable {
    public static let manifestVersion = 1

    public struct Argument: Encodable, Sendable, Equatable {
        public enum Kind: String, Encodable, Sendable { case flag, option, positional }
        /// Long flag (`--php-version`) or, for positionals, the value name.
        public var name: String
        public var kind: Kind
        /// Every spelling, e.g. ["--follow", "-f"] or ["--json", "--no-json"].
        public var flags: [String]
        /// boolean | integer | number | string | enum
        public var type: String
        public var allowedValues: [String]?
        public var repeating: Bool
        public var required: Bool
        public var defaultValue: String?
        public var valueName: String?
        public var description: String

        enum CodingKeys: String, CodingKey {
            case name, kind, flags, type, repeating, required, description
            case allowedValues = "allowed_values"
            case defaultValue = "default"
            case valueName = "value_name"
        }
    }

    public struct Command: Encodable, Sendable {
        public var name: String
        public var aliases: [String]
        public var abstract: String
        public var discussion: String?
        /// Command-specific arguments; `global_options` apply as well.
        public var arguments: [Argument]
    }

    public struct ExitCodeEntry: Encodable, Sendable {
        public var code: Int32
        public var name: String
        public var description: String
    }

    public var manifestVersion = Self.manifestVersion
    public var envelopeSchemaVersion = Envelope.schemaVersion
    public var tool = "drupal"
    public var version = DrupalVersion.current
    public var outputDefault = "JSON envelope when stdout is not a TTY, text otherwise; override with --json / --no-json"
    public var globalOptions: [Argument]
    public var commands: [Command]
    public var exitCodes: [ExitCodeEntry]

    enum CodingKeys: String, CodingKey {
        case tool, version, commands
        case manifestVersion = "manifest_version"
        case envelopeSchemaVersion = "envelope_schema_version"
        case outputDefault = "output_default"
        case globalOptions = "global_options"
        case exitCodes = "exit_codes"
    }

    public static func generate() throws(DrupalError) -> CommandManifest {
        let dump: DumpRoot
        do {
            dump = try JSONDecoder().decode(DumpRoot.self, from: Data(dumpHelpJSON().utf8))
        } catch {
            throw DrupalError(.internalError, "could not read ArgumentParser's command dump: \(error)")
        }
        let globalNames = Set(Reflection.types(of: GlobalOptions()).keys)
        var globals: [Argument] = []
        var commands: [Command] = []

        for sub in dump.command.subcommands ?? [] where sub.commandName != "help" {
            guard let type = RootCommand.configuration.subcommands.first(where: { $0._commandName == sub.commandName }) else { continue }
            let types = Reflection.types(of: type.init())
            var args: [Argument] = []
            for info in sub.arguments ?? [] where info.isPublic {
                let arg = Argument(info, swiftType: types[info.key])
                let base = info.key.hasPrefix("no-") ? String(info.key.dropFirst(3)) : info.key
                if globalNames.contains(base) {
                    if !globals.contains(where: { $0.name == arg.name }) { globals.append(arg) }
                } else {
                    args.append(arg)
                }
            }
            mergeInversions(&args)
            commands.append(Command(
                name: sub.commandName,
                aliases: sub.aliases ?? [],
                abstract: sub.abstract ?? "",
                discussion: sub.discussion?.isEmpty == false ? sub.discussion : nil,
                arguments: args
            ))
        }

        mergeInversions(&globals)
        return CommandManifest(
            globalOptions: globals,
            commands: commands,
            exitCodes: ExitStatus.allCases.map { ExitCodeEntry(code: $0.rawValue, name: $0.identifier, description: $0.summary) }
        )
    }

    /// ArgumentParser dumps `--x/--no-x` as two flags; fold `--no-x` into
    /// `--x`'s spellings so the manifest has one boolean per setting.
    static func mergeInversions(_ args: inout [Argument]) {
        for (i, arg) in args.enumerated().reversed() where arg.kind == .flag && arg.name.hasPrefix("--no-") {
            let positive = "--" + arg.name.dropFirst("--no-".count)
            guard let j = args.firstIndex(where: { $0.name == positive }) else { continue }
            args[j].flags += arg.flags.filter { !args[j].flags.contains($0) }
            args.remove(at: i)
        }
    }

    /// ArgumentParser renders the dump as the "help" message of the error
    /// thrown for `--experimental-dump-help`.
    static func dumpHelpJSON() -> String {
        do {
            _ = try RootCommand.parseAsRoot(["--experimental-dump-help"])
            return ""
        } catch {
            return RootCommand.fullMessage(for: error)
        }
    }
}

extension CommandManifest.Argument {
    init(_ info: DumpArgument, swiftType: String?) {
        let flags = (info.names ?? []).map { $0.kind == "short" ? "-\($0.name)" : ($0.kind == "long" ? "--\($0.name)" : "-\($0.name)") }
        let allowed = info.allValues?.isEmpty == false ? info.allValues : nil
        self.init(
            name: info.kind == "positional" ? (info.valueName ?? info.key) : "--\(info.key)",
            kind: Kind(rawValue: info.kind) ?? .option,
            flags: flags,
            type: allowed != nil ? "enum" : Reflection.jsonType(swiftType, kind: info.kind),
            allowedValues: allowed,
            repeating: info.isRepeating,
            required: !info.isOptional,
            defaultValue: info.defaultValue,
            valueName: info.kind == "flag" ? nil : info.valueName,
            description: info.abstract ?? ""
        )
    }
}

// MARK: - ArgumentParser dump (subset of ArgumentParserToolInfo's ToolInfoV0,
// which is not a public product).

struct DumpRoot: Decodable {
    var command: DumpCommand
}

struct DumpCommand: Decodable {
    var commandName: String
    var aliases: [String]?
    var abstract: String?
    var discussion: String?
    var subcommands: [DumpCommand]?
    var arguments: [DumpArgument]?
}

struct DumpArgument: Decodable {
    struct Name: Decodable {
        var kind: String
        var name: String
    }

    var kind: String
    var shouldDisplay: Bool
    var isOptional: Bool
    var isRepeating: Bool
    var names: [Name]?
    var preferredName: Name?
    var valueName: String?
    var defaultValue: String?
    var allValues: [String]?
    var abstract: String?

    /// Kebab-case identity shared with `Reflection`: the long name for
    /// options/flags, the value name for positionals.
    var key: String {
        if kind == "positional" { return valueName ?? "" }
        return (names ?? []).first { $0.kind == "long" }?.name ?? preferredName?.name ?? ""
    }

    /// Hides ArgumentParser's built-ins (--help, --version) and hidden flags.
    var isPublic: Bool {
        shouldDisplay && !["help", "version"].contains(key)
    }
}

// MARK: - Reflection of Swift value types

enum Reflection {
    static let groups: [String: any ParsableArguments.Type] = [
        "GlobalOptions": GlobalOptions.self,
        "ConfigFieldOptions": ConfigFieldOptions.self,
    ]

    /// Kebab-case argument key → wrapper type description (`Option<Optional<Int>>`).
    static func types(of value: any ParsableArguments) -> [String: String] {
        var out: [String: String] = [:]
        for child in Mirror(reflecting: value).children {
            guard let label = child.label, label.hasPrefix("_") else { continue }
            let type = String(describing: Swift.type(of: child.value))
            if type.hasPrefix("OptionGroup<") {
                let inner = String(type.dropFirst("OptionGroup<".count).dropLast())
                if let group = groups[inner] {
                    out.merge(types(of: group.init())) { a, _ in a }
                }
                continue
            }
            out[kebab(String(label.dropFirst()))] = type
        }
        return out
    }

    static func kebab(_ camel: String) -> String {
        var out = ""
        for ch in camel {
            if ch.isUppercase {
                if !out.isEmpty { out.append("-") }
                out.append(Character(ch.lowercased()))
            } else {
                out.append(ch)
            }
        }
        return out
    }

    static func jsonType(_ swiftType: String?, kind: String) -> String {
        if kind == "flag" { return "boolean" }
        guard var t = swiftType else { return "string" }
        if let open = t.firstIndex(of: "<") { t = String(t[t.index(after: open)...].dropLast()) }  // strip Option<…>
        for wrapper in ["Optional<", "Array<"] where t.hasPrefix(wrapper) {
            t = String(t.dropFirst(wrapper.count).dropLast())
        }
        switch t {
        case "Int", "Int32", "Int64", "UInt": return "integer"
        case "Double", "Float": return "number"
        case "Bool": return "boolean"
        default: return "string"
        }
    }
}

struct DescribeCommandsCommand: DrupalCommand {
    static let configuration = CommandConfiguration(
        commandName: "describe-commands",
        abstract: "Print the machine-readable manifest of every command, flag, type, and exit code."
    )

    @OptionGroup var global: GlobalOptions

    func execute(_ context: CommandContext) async throws(DrupalError) -> CommandOutput {
        let manifest = try CommandManifest.generate()
        let width = (manifest.commands.map(\.name.count).max() ?? 0) + 2
        let text = manifest.commands.map { c in
            c.name.padding(toLength: width, withPad: " ", startingAt: 0) + c.abstract
        }.joined(separator: "\n") + "\n\nRun with --json for the full manifest."
        return CommandOutput(data: manifest, text: text)
    }
}
