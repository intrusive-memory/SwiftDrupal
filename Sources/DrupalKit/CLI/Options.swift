import ArgumentParser
import Foundation

// Option groups and argument types shared across commands.
//
// Manifest note: `describe-commands` derives each option's type from its
// Swift property type by reflection, matching properties to flags by the
// default kebab-case name. Keep default long names (no `.customLong`) so the
// match holds; ManifestTests enforces it.

/// Accepted by every command.
public struct GlobalOptions: ParsableArguments {
    @Flag(inversion: .prefixedNo, help: "Force (--json) or suppress (--no-json) the JSON envelope. Default: JSON when stdout is not a TTY.")
    public var json: Bool?

    @Option(help: ArgumentHelp("Project directory. Default: the nearest directory at or above the current one containing .drupal/config.yaml (for init: the current directory).", valueName: "path"))
    public var projectDir: String?

    public init() {}
}

/// One flag per config field, shared by `init` (create) and `config` (update).
public struct ConfigFieldOptions: ParsableArguments {
    @Option(help: ArgumentHelp("Explicit project name (a DNS label). Default: derived from the directory name.", valueName: "name"))
    public var name: String?

    @Option(help: ArgumentHelp("Document root relative to the project root (\"\" = the root itself). Default: web.", valueName: "path"))
    public var docroot: String?

    @Option(help: ArgumentHelp("PHP version. Default: \(ProjectConfig.Defaults.phpVersion).", valueName: "version"))
    public var phpVersion: PHPVersionArgument?

    @Option(help: ArgumentHelp("Web server. Default: \(ProjectConfig.Defaults.webserverType.rawValue).", valueName: "type"))
    public var webserverType: WebserverType?

    @Option(help: ArgumentHelp("Database engine (v1.0: mariadb only).", valueName: "type"))
    public var databaseType: DatabaseType?

    @Option(help: ArgumentHelp("MariaDB version. Default: \(ProjectConfig.Defaults.databaseVersion).", valueName: "version"))
    public var databaseVersion: MariaDBVersionArgument?

    @Option(help: ArgumentHelp("KEY=value exported into the web container. Repeatable; replaces the whole list.", valueName: "KEY=value"))
    public var webEnvironment: [String] = []

    @Option(help: ArgumentHelp("Shell command run in the web container after start. Repeatable, in order; replaces the whole list.", valueName: "command"))
    public var postStart: [String] = []

    @Option(help: ArgumentHelp("Node.js version, e.g. 22. Default: the web image's own.", valueName: "version"))
    public var nodejsVersion: String?

    public init() {}

    /// True when at least one field flag was passed.
    var isEmpty: Bool {
        name == nil && docroot == nil && phpVersion == nil && webserverType == nil && databaseType == nil
            && databaseVersion == nil && webEnvironment.isEmpty && postStart.isEmpty && nodejsVersion == nil
    }

    /// Applies the given flags on top of `config`; returns the keys set.
    func apply(to config: inout ProjectConfig) -> Set<String> {
        var set: Set<String> = []
        if let name { config.name = name; set.insert("name") }
        if let docroot { config.docroot = docroot; set.insert("docroot") }
        if let phpVersion { config.phpVersion = phpVersion.value; set.insert("php_version") }
        if let webserverType { config.webserverType = webserverType; set.insert("webserver_type") }
        if let databaseType { config.database.type = databaseType; set.insert("database.type") }
        if let databaseVersion { config.database.version = databaseVersion.value; set.insert("database.version") }
        if !webEnvironment.isEmpty { config.webEnvironment = webEnvironment; set.insert("web_environment") }
        if !postStart.isEmpty { config.postStart = postStart; set.insert("post_start") }
        if let nodejsVersion { config.nodejsVersion = nodejsVersion; set.insert("nodejs_version") }
        return set
    }
}

/// Validates against `ProjectConfig.Supported` at parse time, so the manifest
/// and `--help` list the accepted values.
public struct PHPVersionArgument: ExpressibleByArgument, Sendable {
    public let value: String
    public init?(argument: String) {
        guard ProjectConfig.Supported.phpVersions.contains(argument) else { return nil }
        value = argument
    }
    public static var allValueStrings: [String] { ProjectConfig.Supported.phpVersions }
}

public struct MariaDBVersionArgument: ExpressibleByArgument, Sendable {
    public let value: String
    public init?(argument: String) {
        guard ProjectConfig.Supported.mariadbVersions.contains(argument) else { return nil }
        value = argument
    }
    public static var allValueStrings: [String] { ProjectConfig.Supported.mariadbVersions }
}

extension WebserverType: ExpressibleByArgument {}
extension DatabaseType: ExpressibleByArgument {}
extension Service: ExpressibleByArgument {}
