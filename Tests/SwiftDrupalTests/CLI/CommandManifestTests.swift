import ArgumentParser
import Foundation
import Synchronization
import Testing
@testable import SwiftDrupal

// MARK: - Minimal JSON Schema checker

/// A deliberately small JSON Schema validator covering the keywords
/// docs/schema/manifest.json uses: `type`, `required`, `properties`,
/// `additionalProperties: false`, `items`, `enum`, and local `$ref`s into
/// `$defs`. Returns one message per violation (empty when valid).
enum MiniSchemaValidator {
    static func validate(_ value: Any, schema: [String: Any], root: [String: Any], path: String = "$") -> [String] {
        if let ref = schema["$ref"] as? String {
            let prefix = "#/$defs/"
            guard ref.hasPrefix(prefix), let defs = root["$defs"] as? [String: Any],
                let target = defs[String(ref.dropFirst(prefix.count))] as? [String: Any]
            else { return ["\(path): unresolvable $ref \(ref)"] }
            return validate(value, schema: target, root: root, path: path)
        }

        var errors: [String] = []
        if let type = schema["type"] as? String, !matches(value, type: type) {
            return ["\(path): expected \(type), got \(Swift.type(of: value))"]
        }
        if let allowed = schema["enum"] as? [Any], !allowed.contains(where: { equal($0, value) }) {
            errors.append("\(path): \(value) not in enum")
        }
        if let object = value as? [String: Any] {
            for key in schema["required"] as? [String] ?? [] where object[key] == nil {
                errors.append("\(path): missing required key \"\(key)\"")
            }
            let properties = schema["properties"] as? [String: Any] ?? [:]
            for (key, child) in object {
                if let childSchema = properties[key] as? [String: Any] {
                    errors += validate(child, schema: childSchema, root: root, path: "\(path).\(key)")
                } else if (schema["additionalProperties"] as? Bool) == false {
                    errors.append("\(path): unexpected key \"\(key)\"")
                }
            }
        }
        if let array = value as? [Any], let items = schema["items"] as? [String: Any] {
            for (index, element) in array.enumerated() {
                errors += validate(element, schema: items, root: root, path: "\(path)[\(index)]")
            }
        }
        return errors
    }

    private static func matches(_ value: Any, type: String) -> Bool {
        let number = value as? NSNumber
        let isBool = number.map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
        switch type {
        case "object": return value is [String: Any]
        case "array": return value is [Any]
        case "string": return value is String
        case "boolean": return isBool
        case "integer":
            guard let number, !isBool else { return false }
            return number.doubleValue.rounded() == number.doubleValue
        case "number": return number != nil && !isBool
        case "null": return value is NSNull
        default: return false
        }
    }

    private static func equal(_ lhs: Any, _ rhs: Any) -> Bool {
        (lhs as? NSObject)?.isEqual(rhs) ?? false
    }
}

// MARK: - Helpers

/// Thread-safe capture of stdout documents.
final class ManifestOutputCapture: Sendable {
    private let storage = Mutex<[String]>([])
    func append(_ text: String) { storage.withLock { $0.append(text) } }
    var last: String { storage.withLock { $0.last ?? "" } }
}

private func manifestEnvironment(tty: Bool, capture: ManifestOutputCapture) -> LifecycleEnvironment {
    LifecycleEnvironment(
        makeClient: { ServiceClientContainerService(socketPath: "/tmp/sd-unused.sock", hostsFallback: nil) },
        hostsFile: HostsFileStrategy(writer: ReadOnlyPrivilegedFileWriter()),
        outputResolver: OutputFormatResolver { tty },
        writeOutput: { capture.append($0) },
        writeError: { _ in }
    )
}

/// Runs `arguments` through the root command with stdout captured and returns the output.
private func manifestOutput(_ arguments: [String], tty: Bool = true) async throws -> String {
    let capture = ManifestOutputCapture()
    try await LifecycleEnvironment.$current.withValue(manifestEnvironment(tty: tty, capture: capture)) {
        var command = try Drupal.parseAsRoot(arguments)
        if var asyncCommand = command as? AsyncParsableCommand {
            try await asyncCommand.run()
        } else {
            try command.run()
        }
    }
    return capture.last
}

private func schemaDocument() throws -> [String: Any] {
    let packageRoot = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let url = packageRoot.appending(path: "docs/schema/manifest.json")
    return try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
}

/// Every command path reachable from `type` through `CommandConfiguration`.
private func registeredPaths(_ type: any ParsableCommand.Type, prefix: String? = nil) -> [String] {
    type.configuration.subcommands.flatMap { sub -> [String] in
        let name = sub.configuration.commandName ?? ""
        let path = prefix.map { "\($0) \(name)" } ?? name
        return [path] + registeredPaths(sub, prefix: path)
    }
}

// MARK: - Tests

@Suite struct CommandManifestTests {
    @Test func manifestFlagAndDescribeCommandsEmitTheSameDocument() async throws {
        let flag = try await manifestOutput(["--manifest"])
        let subcommand = try await manifestOutput(["describe-commands"])
        #expect(!flag.isEmpty)
        #expect(flag == subcommand)
        #expect(try await manifestOutput(["describe-commands", "--json"]) == flag)
    }

    @Test func manifestIsJSONOnATTYAndOffOne() async throws {
        for tty in [true, false] {
            let text = try await manifestOutput(["--manifest"], tty: tty)
            #expect(throws: Never.self) { _ = try JSONDecoder().decode(CommandManifest.self, from: Data(text.utf8)) }
        }
    }

    @Test func manifestValidatesAgainstTheCommittedSchema() async throws {
        let schema = try schemaDocument()
        let text = try await manifestOutput(["--manifest"])
        let document = try JSONSerialization.jsonObject(with: Data(text.utf8))
        let errors = MiniSchemaValidator.validate(document, schema: schema, root: schema)
        #expect(errors.isEmpty, "\(errors)")
    }

    @Test func schemaCheckerRejectsMalformedManifests() async throws {
        let schema = try schemaDocument()
        let text = try await manifestOutput(["--manifest"])
        var document = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        document.removeValue(forKey: "commands")
        document["exitCodes"] = [["code": "ten", "name": "x", "meaning": "y", "source": "drupal"]]
        document["surprise"] = true
        let errors = MiniSchemaValidator.validate(document, schema: schema, root: schema)
        #expect(errors.contains { $0.contains("missing required key \"commands\"") })
        #expect(errors.contains { $0.contains("$.exitCodes[0].code") })
        #expect(errors.contains { $0.contains("unexpected key \"surprise\"") })
    }

    @Test func listsEveryRegisteredSubcommandIncludingServiceChildren() throws {
        let manifest = try CommandManifest.build()
        let names = manifest.commands.map(\.name)
        let expected = [
            "service", "service run", "service install", "service uninstall", "service status",
            "init", "start", "stop", "restart", "status", "delete", "config", "validate",
            "import-db", "export-db", "exec", "ssh", "logs", "describe-commands",
        ]
        for name in expected { #expect(names.contains(name), "\(name) missing") }
        // Introspected, not hand-listed: exactly the registered command tree.
        #expect(names == registeredPaths(Drupal.self))
        #expect(manifest.commands.first { $0.name == "status" }?.aliases == ["describe"])
        #expect(manifest.commands.first { $0.name == "service" }?.subcommands
            == ["service run", "service install", "service uninstall", "service status"])
        #expect(manifest.commands.first { $0.name == "service install" }?.parent == "service")
    }

    @Test func topLevelCarriesToolVersionExitCodesAndJSONNote() throws {
        let manifest = try CommandManifest.build()
        #expect(manifest.tool.name == "drupal")
        #expect(manifest.tool.version == Drupal.version)
        #expect(manifest.jsonOutput.flag == "--json")
        #expect(manifest.jsonOutput.automaticWhenStdoutIsNotATTY)
        let codes = Dictionary(uniqueKeysWithValues: manifest.exitCodes.map { ($0.code, $0.name) })
        #expect(codes[0] == "success")
        #expect(codes[1] == "failure")
        #expect(codes[10] == "invalidConfig")
        #expect(codes[11] == "platformUnavailable")
        #expect(codes[12] == "containerFailedToStart")
        #expect(codes[13] == "healthCheckTimeout")
        #expect(codes[14] == "serviceUnavailable")
        #expect(codes[64] == "usageError")
        #expect(manifest.rootArguments.contains { $0.names == ["--manifest"] })
    }

    @Test func argumentsCarryKindTypeDefaultRequiredAndHelp() throws {
        let manifest = try CommandManifest.build()
        func argument(_ command: String, _ name: String) -> CommandManifest.Argument? {
            manifest.commands.first { $0.name == command }?.arguments.first {
                $0.names.contains(name) || $0.valueName == name
            }
        }

        let timeout = try #require(argument("start", "--timeout"))
        #expect(timeout.kind == "option")
        #expect(timeout.type == "Int")
        #expect(timeout.defaultValue == "120")
        #expect(!timeout.required)
        #expect(timeout.help?.isEmpty == false)

        let keepData = try #require(argument("delete", "--keep-data"))
        #expect(keepData.kind == "flag")
        #expect(keepData.type == "Bool")
        #expect(keepData.defaultValue == "false")

        let service = try #require(argument("exec", "service"))
        #expect(service.kind == "positional")
        #expect(service.required)
        #expect(service.type == "String")
        let command = try #require(argument("exec", "command"))
        #expect(command.parsingStrategy == "postTerminator")
        #expect(command.type == "[String]")
        #expect(command.isRepeating)

        #expect(argument("init", "--web-environment")?.type == "[String]")
        #expect(argument("service run", "--dns-port")?.type == "UInt16")
        #expect(argument("logs", "--follow")?.names.sorted() == ["--follow", "-f"])
        #expect(argument("import-db", "file")?.required == true)
        #expect(argument("export-db", "file")?.required == false)
    }

    @Test func contractNotesStateTheIntentionalBehaviors() throws {
        let manifest = try CommandManifest.build()
        func command(_ name: String) -> CommandManifest.Command? { manifest.commands.first { $0.name == name } }

        #expect(command("service run")?.hidden == true)
        #expect(command("start")?.hidden == false)
        let delete = try #require(command("delete"))
        #expect(delete.notes.contains { $0.contains("DESTRUCTIVE BY DEFAULT") && $0.contains("--keep-data") })
        #expect(command("export-db")?.notes.contains { $0.contains("stdout") && $0.contains("stderr") } == true)
        #expect(command("exec")?.notes.contains { $0.contains("no -i/-t flags") } == true)
        #expect(command("ssh")?.notes.contains { $0.contains("no -i/-t flags") } == true)
        #expect(command("logs")?.notes.contains { $0.contains("SIGINT exits 0") } == true)
        #expect(command("start")?.notes.contains { $0.contains("post_start") } == true)

        for name in ["init", "config", "validate", "describe-commands"] {
            #expect(command(name)?.requiresService == false, "\(name)")
        }
        for name in ["start", "stop", "restart", "status", "delete", "import-db", "export-db", "exec", "ssh", "logs"] {
            #expect(command(name)?.requiresService == true, "\(name)")
        }
    }

    /// Wiring audit guard: every visible leaf command accepts `--json`.
    @Test func everyVisibleLeafCommandAcceptsJSON() throws {
        let manifest = try CommandManifest.build()
        let leaves = manifest.commands.filter { !$0.hidden && $0.subcommands.isEmpty }
        #expect(leaves.count >= 17)
        for leaf in leaves {
            #expect(leaf.arguments.contains { $0.names == ["--json"] }, "\(leaf.name) has no --json")
        }
    }
}
