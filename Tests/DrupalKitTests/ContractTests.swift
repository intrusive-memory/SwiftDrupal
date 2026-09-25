import Foundation
import Testing
@testable import DrupalKit

// The agent-facing contract: envelope shape, exit codes, manifest.

@Suite struct EnvelopeTests {
    func decode(_ e: Envelope) throws -> [String: Any] {
        let line = e.jsonLine()
        #expect(!line.contains("\n"))
        return try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }

    @Test func successShape() throws {
        struct D: Encodable, Sendable { var value = 1 }
        let obj = try decode(.success("validate", data: D(), warnings: ["w"]))
        #expect(Set(obj.keys) == ["schema_version", "ok", "command", "data", "warnings", "error"])
        #expect(obj["schema_version"] as? Int == 1)
        #expect(obj["ok"] as? Bool == true)
        #expect(obj["command"] as? String == "validate")
        #expect((obj["data"] as? [String: Any])?["value"] as? Int == 1)
        #expect(obj["warnings"] as? [String] == ["w"])
        #expect(obj["error"] is NSNull)
    }

    @Test func successWithoutDataHasExplicitNull() throws {
        let obj = try decode(.success("ssh", data: nil))
        #expect(obj["data"] is NSNull)
        #expect(obj["error"] is NSNull)
    }

    @Test func failureShape() throws {
        let error = DrupalError(.configInvalid, "bad", details: [.init(path: "php_version", line: 2, message: "nope")], hint: "fix it")
        let obj = try decode(.failure("start", error))
        #expect(obj["ok"] as? Bool == false)
        #expect(obj["data"] is NSNull)
        let body = try #require(obj["error"] as? [String: Any])
        #expect(Set(body.keys) == ["code", "exit_code", "message", "details", "hint"])
        #expect(body["code"] as? String == "config_invalid")
        #expect(body["exit_code"] as? Int == 3)
        #expect(body["message"] as? String == "bad")
        #expect(body["hint"] as? String == "fix it")
        let detail = try #require((body["details"] as? [[String: Any]])?.first)
        #expect(detail["path"] as? String == "php_version")
        #expect(detail["line"] as? Int == 2)
        #expect(detail["message"] as? String == "nope")
    }

    @Test func missingHintIsExplicitNull() throws {
        let obj = try decode(.failure("x", DrupalError(.ioError, "m")))
        #expect((obj["error"] as? [String: Any])?["hint"] is NSNull)
    }
}

@Suite struct ExitStatusTests {
    /// The published table. Changing a number is a breaking change.
    @Test func codesAreStable() {
        let expected: [String: Int32] = [
            "success": 0, "internal_error": 1, "usage_error": 2, "config_invalid": 3,
            "project_not_found": 4, "already_exists": 5, "platform_unavailable": 6,
            "container_start_failed": 7, "health_timeout": 8, "project_not_running": 9,
            "container_operation_failed": 10, "io_error": 11, "not_implemented": 12,
            "post_start_failed": 13,
        ]
        let actual = Dictionary(uniqueKeysWithValues: ExitStatus.allCases.map { ($0.identifier, $0.rawValue) })
        #expect(actual == expected)
    }

    @Test func codesAndIdentifiersAreDistinct() {
        #expect(Set(ExitStatus.allCases.map(\.rawValue)).count == ExitStatus.allCases.count)
        #expect(Set(ExitStatus.allCases.map(\.identifier)).count == ExitStatus.allCases.count)
        #expect(ExitStatus.allCases.allSatisfy { !$0.summary.isEmpty })
    }

    @Test func errorsMapToTheirExitCode() async throws {
        let dir = try tempProject()
        #expect(await drupal("validate", in: dir).code == ExitStatus.projectNotFound.rawValue)
        try writeConfig("php_version: \"5.6\"\n", in: dir)
        #expect(await drupal("start", in: dir).code == ExitStatus.configInvalid.rawValue)
        try writeConfig("", in: dir)
        #expect(await drupal("start", in: dir).code == ExitStatus.notImplemented.rawValue)
        #expect(await drupal("start", in: dir, platform: FailingPlatform()).code == ExitStatus.platformUnavailable.rawValue)
        #expect(await drupal("start", "--timeout", "0", in: dir).code == ExitStatus.usageError.rawValue)
        #expect(await drupal("nonsense", in: dir).code == ExitStatus.usageError.rawValue)
    }
}

@Suite struct ManifestTests {
    let manifest: CommandManifest

    init() throws {
        manifest = try CommandManifest.generate()
    }

    func command(_ name: String) throws -> CommandManifest.Command {
        try #require(manifest.commands.first { $0.name == name })
    }

    @Test func listsEveryV1Command() {
        let names = Set(manifest.commands.map(\.name))
        let expected: Set = [
            "init", "config", "validate", "start", "stop", "restart", "status", "delete",
            "exec", "ssh", "logs", "import-db", "export-db", "describe-commands",
        ]
        #expect(names == expected)
        #expect(manifest.commands.allSatisfy { !$0.abstract.isEmpty })
    }

    @Test func matchesTheRegisteredCommandTree() {
        #expect(manifest.commands.map(\.name) == RootCommand.configuration.subcommands.map { $0._commandName })
    }

    @Test func statusHasDescribeAlias() throws {
        #expect(try command("status").aliases == ["describe"])
    }

    @Test func globalOptionsAreFactoredOut() throws {
        #expect(manifest.globalOptions.map(\.name) == ["--json", "--project-dir"])
        #expect(manifest.globalOptions[0].flags == ["--json", "--no-json"])
        #expect(manifest.globalOptions[0].type == "boolean")
        for c in manifest.commands {
            #expect(!c.arguments.contains { ["--json", "--no-json", "--project-dir", "--help"].contains($0.name) }, "\(c.name)")
        }
    }

    @Test func typesComeFromSwiftTypes() throws {
        let start = try command("start")
        let timeout = try #require(start.arguments.first { $0.name == "--timeout" })
        #expect(timeout.type == "integer")
        #expect(timeout.defaultValue == "120")

        let initArgs = try command("init").arguments
        let php = try #require(initArgs.first { $0.name == "--php-version" })
        #expect(php.type == "enum")
        #expect(php.allowedValues == ProjectConfig.Supported.phpVersions)
        #expect(initArgs.first { $0.name == "--web-environment" }?.repeating == true)
        #expect(initArgs.first { $0.name == "--force" }?.type == "boolean")

        let exec = try command("exec")
        #expect(exec.arguments.first { $0.kind == .positional }?.required == true)
        #expect(exec.arguments.first { $0.name == "--service" }?.allowedValues == ["web", "db"])
    }

    /// Guards the reflection match: every option must resolve to a Swift type,
    /// which fails if someone adds a `.customLong` name.
    @Test func everyOptionHasAReflectedType() throws {
        let dump = try JSONDecoder().decode(DumpRoot.self, from: Data(CommandManifest.dumpHelpJSON().utf8))
        for sub in dump.command.subcommands ?? [] where sub.commandName != "help" {
            let type = try #require(RootCommand.configuration.subcommands.first { $0._commandName == sub.commandName })
            let types = Reflection.types(of: type.init())
            for arg in sub.arguments ?? [] where arg.isPublic && arg.kind != "flag" {
                #expect(types[arg.key] != nil, "\(sub.commandName) \(arg.key)")
            }
        }
    }

    @Test func exitCodesMatchTheEnum() {
        #expect(manifest.exitCodes.map(\.code) == ExitStatus.allCases.map(\.rawValue))
        #expect(manifest.exitCodes.map(\.name) == ExitStatus.allCases.map(\.identifier))
    }

    @Test func servedAsAnEnvelope() async throws {
        let r = await drupal("describe-commands", in: try tempProject())
        #expect(r.code == 0)
        #expect(r.envelope["ok"] as? Bool == true)
        #expect(r.data["manifest_version"] as? Int == 1)
        #expect((r.data["commands"] as? [[String: Any]])?.count == manifest.commands.count)
    }
}
