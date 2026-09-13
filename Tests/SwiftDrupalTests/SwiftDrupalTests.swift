import ArgumentParser
import Foundation
import Testing
@testable import SwiftDrupal

@Suite struct ProjectConfigTests {
    static let mvpYAML = """
        docroot: web
        php_version: "8.3"
        webserver_type: nginx-fpm
        database:
          type: mariadb
          version: "10.11"
        web_environment: []
        """

    @Test func decodesMVPExample() throws {
        let config = try ProjectConfig(yaml: Self.mvpYAML)
        #expect(config == ProjectConfig.default)
        #expect(config.name == nil)
    }

    @Test func yamlRoundTripPreservesAllFields() throws {
        let original = ProjectConfig(
            name: "custom-site",
            docroot: "docroot",
            phpVersion: "8.3",
            webserverType: "apache-fpm",
            database: .init(type: "mariadb", version: "10.11"),
            webEnvironment: ["FOO=bar", "BAZ=1"]
        )
        let yaml = try original.yamlString()
        #expect(yaml.contains("php_version:"))
        #expect(yaml.contains("web_environment:"))
        #expect(!yaml.contains("nodejs_version"))
        #expect(try ProjectConfig(yaml: yaml) == original)
    }

    @Test func versionStringsSurviveRoundTripAsStrings() throws {
        // "10.10" must not collapse to the float 10.1.
        var config = ProjectConfig.default
        config.database.version = "10.10"
        config.phpVersion = "8.0"
        let decoded = try ProjectConfig(yaml: config.yamlString())
        #expect(decoded.database.version == "10.10")
        #expect(decoded.phpVersion == "8.0")
    }

    @Test func webEnvironmentDefaultsToEmptyWhenOmitted() throws {
        let yaml = Self.mvpYAML.replacingOccurrences(of: "web_environment: []", with: "")
        #expect(try ProjectConfig(yaml: yaml).webEnvironment == [])
    }

    @Test func diskRoundTripThroughLoader() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "SwiftDrupalTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        var config = ProjectConfig.default
        config.webEnvironment = ["DRUSH_OPTIONS_URI=https://example.drupal"]
        try config.write(projectRoot: root)

        let url = ProjectConfig.configFileURL(projectRoot: root)
        #expect(url.path.hasSuffix(".drupal/config.yaml"))
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(try ProjectConfig.load(projectRoot: root) == config)
    }

    @Test func missingFileThrowsInvalidConfig() {
        let root = URL(filePath: "/nonexistent-\(UUID().uuidString)")
        #expect {
            _ = try ProjectConfig.load(projectRoot: root)
        } throws: { error in
            (error as? DrupalError)?.exitCode == .invalidConfig
        }
    }

    @Test func malformedYAMLThrowsInvalidConfig() {
        #expect {
            _ = try ProjectConfig(yaml: "docroot: web\nphp_version: [unterminated")
        } throws: { error in
            (error as? DrupalError)?.exitCode == .invalidConfig
        }
    }

    @Test func missingRequiredFieldThrowsInvalidConfig() {
        #expect {
            _ = try ProjectConfig(yaml: "docroot: web\n")
        } throws: { error in
            (error as? DrupalError)?.exitCode == .invalidConfig
        }
    }
}

@Suite struct ProjectNamingTests {
    @Test func nameDefaultsToDirectoryName() {
        let root = URL(filePath: "/Users/dev/Sites/my-pantheon-site", directoryHint: .isDirectory)
        #expect(ProjectNaming.projectName(projectRoot: root, config: .default) == "my-pantheon-site")
        #expect(ProjectNaming.projectName(projectRoot: root, config: nil) == "my-pantheon-site")
    }

    @Test func explicitNameOverridesDirectoryName() {
        let root = URL(filePath: "/Users/dev/Sites/my-pantheon-site", directoryHint: .isDirectory)
        var config = ProjectConfig.default
        config.name = "other-name"
        #expect(ProjectNaming.projectName(projectRoot: root, config: config) == "other-name")
    }

    @Test func blankExplicitNameFallsBackToDirectoryName() {
        #expect(ProjectNaming.projectName(directoryName: "site", explicitName: "  ") == "site")
        #expect(ProjectNaming.projectName(directoryName: "site", explicitName: nil) == "site")
    }

    @Test func hostnameIsNameDotDrupal() {
        #expect(ProjectNaming.hostname(projectName: "my-pantheon-site") == "my-pantheon-site.drupal")
        #expect(ProjectNaming.hostname(projectName: "other-name") == "other-name.drupal")
    }
}

@Suite struct ExitCodeTests {
    @Test func failureClassesHaveDistinctDocumentedValues() {
        #expect(SwiftDrupal.ExitCode.success.rawValue == 0)
        #expect(SwiftDrupal.ExitCode.failure.rawValue == 1)
        #expect(SwiftDrupal.ExitCode.invalidConfig.rawValue == 10)
        #expect(SwiftDrupal.ExitCode.platformUnavailable.rawValue == 11)
        #expect(SwiftDrupal.ExitCode.containerFailedToStart.rawValue == 12)
        #expect(SwiftDrupal.ExitCode.healthCheckTimeout.rawValue == 13)
        let values = SwiftDrupal.ExitCode.allCases.map(\.rawValue)
        #expect(Set(values).count == values.count)
        #expect(!values.contains(ArgumentParser.ExitCode.validationFailure.rawValue))
    }

    @Test(arguments: [
        (DrupalError.invalidConfig("x"), SwiftDrupal.ExitCode.invalidConfig),
        (DrupalError.platformUnavailable("x"), .platformUnavailable),
        (DrupalError.containerFailedToStart("x"), .containerFailedToStart),
        (DrupalError.healthCheckTimeout("x"), .healthCheckTimeout),
    ])
    func drupalErrorMapsToExitCode(error: DrupalError, expected: SwiftDrupal.ExitCode) {
        #expect(error.exitCode == expected)
        #expect(Drupal.exitStatus(for: error) == expected.rawValue)
        #expect(expected.argumentParserExitCode.rawValue == expected.rawValue)
    }

    @Test func nonDrupalErrorsUseArgumentParserMapping() {
        #expect(Drupal.exitStatus(for: CleanExit.helpRequest()) == 0)
        #expect(throws: (any Error).self) { _ = try Drupal.parseAsRoot(["--no-such-flag"]) }
        do {
            _ = try Drupal.parseAsRoot(["--no-such-flag"])
        } catch {
            #expect(Drupal.exitStatus(for: error) == ArgumentParser.ExitCode.validationFailure.rawValue)
        }
    }

    @Test func rootCommandIsNamedDrupal() {
        #expect(Drupal.configuration.commandName == "drupal")
    }
}

@Suite struct OutputFormatResolverTests {
    @Test func jsonFlagForcesJSONEvenOnTTY() {
        let resolver = OutputFormatResolver { true }
        #expect(resolver.resolve(jsonFlag: true) == .json)
    }

    @Test func ttyWithoutFlagIsText() {
        let resolver = OutputFormatResolver { true }
        #expect(resolver.resolve(jsonFlag: false) == .text)
    }

    @Test func nonTTYWithoutFlagIsJSON() {
        let resolver = OutputFormatResolver { false }
        #expect(resolver.resolve(jsonFlag: false) == .json)
        #expect(resolver.resolve(jsonFlag: true) == .json)
    }

    @Test func outputOptionsParsesJSONFlag() throws {
        let tty = OutputFormatResolver { true }
        #expect(try OutputOptions.parse(["--json"]).format(using: tty) == .json)
        #expect(try OutputOptions.parse([]).format(using: tty) == .text)
        #expect(try OutputOptions.parse([]).format(using: OutputFormatResolver { false }) == .json)
    }
}
