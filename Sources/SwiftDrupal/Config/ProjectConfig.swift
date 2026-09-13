import Foundation
import Yams

/// The v1.0 MVP project config file (`.drupal/config.yaml` in the project root).
///
/// Keys use DDEV's snake_case spelling. `nodejs_version` is intentionally
/// excluded from v1.0 (see EXECUTION_PLAN.md, Resolved OQ-2).
public struct ProjectConfig: Codable, Equatable, Sendable {
    public struct DatabaseConfig: Codable, Equatable, Sendable {
        public var type: String
        public var version: String

        public init(type: String, version: String) {
            self.type = type
            self.version = version
        }
    }

    /// Optional explicit project name; defaults to the project directory's name.
    public var name: String?
    public var docroot: String
    public var phpVersion: String
    public var webserverType: String
    public var database: DatabaseConfig
    /// `KEY=value` entries injected into the web container. Defaults to `[]` when omitted.
    public var webEnvironment: [String]

    enum CodingKeys: String, CodingKey {
        case name
        case docroot
        case phpVersion = "php_version"
        case webserverType = "webserver_type"
        case database
        case webEnvironment = "web_environment"
    }

    public init(
        name: String? = nil,
        docroot: String,
        phpVersion: String,
        webserverType: String,
        database: DatabaseConfig,
        webEnvironment: [String] = []
    ) {
        self.name = name
        self.docroot = docroot
        self.phpVersion = phpVersion
        self.webserverType = webserverType
        self.database = database
        self.webEnvironment = webEnvironment
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        docroot = try container.decode(String.self, forKey: .docroot)
        phpVersion = try container.decode(String.self, forKey: .phpVersion)
        webserverType = try container.decode(String.self, forKey: .webserverType)
        database = try container.decode(DatabaseConfig.self, forKey: .database)
        webEnvironment = try container.decodeIfPresent([String].self, forKey: .webEnvironment) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encode(docroot, forKey: .docroot)
        try container.encode(phpVersion, forKey: .phpVersion)
        try container.encode(webserverType, forKey: .webserverType)
        try container.encode(database, forKey: .database)
        try container.encode(webEnvironment, forKey: .webEnvironment)
    }

    /// MVP defaults, matching the example in the v1.0 requirements.
    public static let `default` = ProjectConfig(
        docroot: "web",
        phpVersion: "8.3",
        webserverType: "nginx-fpm",
        database: DatabaseConfig(type: "mariadb", version: "10.11"),
        webEnvironment: []
    )
}

// MARK: - YAML

extension ProjectConfig {
    /// Directory (relative to the project root) holding the config file.
    public static let configDirectoryName = ".drupal"
    /// Config file name inside `configDirectoryName`.
    public static let configFileName = "config.yaml"

    /// Location of the config file for the project rooted at `projectRoot`.
    public static func configFileURL(projectRoot: URL) -> URL {
        projectRoot
            .appending(path: configDirectoryName, directoryHint: .isDirectory)
            .appending(path: configFileName, directoryHint: .notDirectory)
    }

    /// Decodes a config from YAML text. Throws `DrupalError.invalidConfig`.
    public init(yaml: String) throws {
        do {
            self = try YAMLDecoder().decode(ProjectConfig.self, from: yaml)
        } catch {
            throw DrupalError.invalidConfig(String(describing: error))
        }
    }

    /// Encodes the config as YAML text.
    public func yamlString() throws -> String {
        try YAMLEncoder().encode(self)
    }

    /// Reads and decodes the config file at `url`. Throws `DrupalError.invalidConfig`.
    public static func load(from url: URL) throws -> ProjectConfig {
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw DrupalError.invalidConfig("cannot read \(url.path): \(error.localizedDescription)")
        }
        return try ProjectConfig(yaml: text)
    }

    /// Reads the config file for the project rooted at `projectRoot`.
    public static func load(projectRoot: URL) throws -> ProjectConfig {
        try load(from: configFileURL(projectRoot: projectRoot))
    }

    /// Writes the config as YAML to `url`, creating intermediate directories.
    public func write(to url: URL) throws {
        let yaml = try yamlString()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(yaml.utf8).write(to: url, options: .atomic)
    }

    /// Writes the config file for the project rooted at `projectRoot`.
    public func write(projectRoot: URL) throws {
        try write(to: Self.configFileURL(projectRoot: projectRoot))
    }
}
