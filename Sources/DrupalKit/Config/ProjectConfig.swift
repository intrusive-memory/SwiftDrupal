// The v1.0 project config model: exactly the fields
// docs/requirements/02-v1-mvp-requirements.md puts in scope, nothing more.
// Stored at `<project root>/.drupal/config.yaml`.

public enum WebserverType: String, CaseIterable, Codable, Sendable {
    case nginxFPM = "nginx-fpm"
    case apacheFPM = "apache-fpm"
}

/// MariaDB only for v1.0; the enum exists so the YAML stays DDEV-shaped
/// (`database: {type, version}`) and more engines can be added later.
public enum DatabaseType: String, CaseIterable, Codable, Sendable {
    case mariadb
}

public struct DatabaseConfig: Equatable, Codable, Sendable {
    public var type: DatabaseType
    public var version: String

    public init(type: DatabaseType = .mariadb, version: String = ProjectConfig.Defaults.databaseVersion) {
        self.type = type
        self.version = version
    }
}

public struct ProjectConfig: Equatable, Codable, Sendable {
    /// Explicit project name; nil means "derive from the directory name".
    public var name: String?
    /// Web server document root, relative to the project root ("" = the root itself).
    public var docroot: String
    public var phpVersion: String
    public var webserverType: WebserverType
    public var database: DatabaseConfig
    /// `KEY=value` entries exported into the web container.
    public var webEnvironment: [String]
    /// Shell commands run (in order) inside the web container after `start`.
    public var postStart: [String]
    /// Node.js major (or full) version; nil keeps the web image's default.
    public var nodejsVersion: String?

    public init(
        name: String? = nil,
        docroot: String = Defaults.docroot,
        phpVersion: String = Defaults.phpVersion,
        webserverType: WebserverType = Defaults.webserverType,
        database: DatabaseConfig = DatabaseConfig(),
        webEnvironment: [String] = [],
        postStart: [String] = [],
        nodejsVersion: String? = nil
    ) {
        self.name = name
        self.docroot = docroot
        self.phpVersion = phpVersion
        self.webserverType = webserverType
        self.database = database
        self.webEnvironment = webEnvironment
        self.postStart = postStart
        self.nodejsVersion = nodejsVersion
    }

    enum CodingKeys: String, CodingKey {
        case name, docroot, database
        case phpVersion = "php_version"
        case webserverType = "webserver_type"
        case webEnvironment = "web_environment"
        case postStart = "post_start"
        case nodejsVersion = "nodejs_version"
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(docroot, forKey: .docroot)
        try c.encode(phpVersion, forKey: .phpVersion)
        try c.encode(webserverType, forKey: .webserverType)
        try c.encode(database, forKey: .database)
        try c.encode(webEnvironment, forKey: .webEnvironment)
        try c.encode(postStart, forKey: .postStart)
        try c.encode(nodejsVersion, forKey: .nodejsVersion)
    }

    /// Defaults track DDEV's own current defaults (DDEV v1.25.4).
    public enum Defaults {
        public static let docroot = "web"
        public static let phpVersion = "8.4"
        public static let webserverType = WebserverType.nginxFPM
        public static let databaseVersion = "11.8"
    }

    /// Accepted values. PHP: the versions preinstalled in `ddev-webserver`
    /// (DDEV v1.25.4 `PreinstalledPHPVersions`) — others would need an image
    /// build, which v1.0 does not do. MariaDB: DDEV's arm64 versions that
    /// current Drupal (10.3+/11) supports.
    public enum Supported {
        public static let phpVersions = ["8.2", "8.3", "8.4", "8.5"]
        public static let mariadbVersions = ["10.6", "10.11", "11.4", "11.8"]
    }

    /// Top-level YAML keys, in the order `init` writes them.
    public static let topLevelKeys = [
        "name", "docroot", "php_version", "webserver_type", "database",
        "web_environment", "post_start", "nodejs_version",
    ]
    public static let databaseKeys = ["type", "version"]
}

/// Pinned DDEV images (DDEV v1.25.4 `versionconstants`). ddev-webserver ships
/// every preinstalled PHP version and both web servers in one image; DDEV
/// selects them at runtime via environment, not per-tag. The Containerization
/// spike must confirm these references pull and run.
public enum DDEVImages {
    public static let webRepository = "ddev/ddev-webserver"
    public static let webTag = "edbebeadc5"
    public static let dbRepositoryPrefix = "ddev/ddev-dbserver"
    public static let dbTag = "27b956a558"

    public static var web: String { "\(webRepository):\(webTag)" }

    public static func db(_ database: DatabaseConfig) -> String {
        "\(dbRepositoryPrefix)-\(database.type.rawValue)-\(database.version):\(dbTag)"
    }
}
