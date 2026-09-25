import Foundation

// The fully resolved view of a project: the config with defaults applied,
// plus everything derived from it (name, hostname, paths, images). This is
// what `config`/`validate` print and what every runtime call receives.

public struct ResolvedProject: Encodable, Sendable, Equatable {
    public enum NameSource: String, Encodable, Sendable {
        /// Sanitized from the project directory's name.
        case directory
        /// Set explicitly by `name:` in the config file.
        case config
    }

    public struct Images: Encodable, Sendable, Equatable {
        public var web: String
        public var db: String
    }

    public var name: String
    public var nameSource: NameSource
    public var hostname: String
    public var url: String
    public var root: URL
    public var configFile: URL
    public var docrootPath: URL
    public var config: ProjectConfig
    /// Dotted keys the file left unset, so their defaults apply.
    public var defaultsApplied: [String]
    public var images: Images
    /// Non-fatal observations (e.g. the docroot does not exist yet).
    public var warnings: [String]

    enum CodingKeys: String, CodingKey {
        case name, hostname, url, root, config, images
        case nameSource = "name_source"
        case configFile = "config_file"
        case docrootPath = "docroot_path"
        case defaultsApplied = "defaults_applied"
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(nameSource, forKey: .nameSource)
        try c.encode(hostname, forKey: .hostname)
        try c.encode(url, forKey: .url)
        try c.encode(root.filePath, forKey: .root)
        try c.encode(configFile.filePath, forKey: .configFile)
        try c.encode(docrootPath.filePath, forKey: .docrootPath)
        try c.encode(config, forKey: .config)
        try c.encode(defaultsApplied, forKey: .defaultsApplied)
        try c.encode(images, forKey: .images)
    }

    /// Every key that has a default, in file order.
    static let defaultableKeys = [
        "docroot", "php_version", "webserver_type", "database.type", "database.version",
        "web_environment", "post_start",
    ]

    public static func resolve(root: URL, parsed: ParsedConfig) throws(DrupalError) -> ResolvedProject {
        let root = root.standardizedFileURL
        let config = parsed.config
        let name: String
        let source: NameSource
        if let explicit = config.name {
            name = explicit
            source = .config
        } else if let derived = ProjectName.sanitize(root.lastPathComponent) {
            name = derived
            source = .directory
        } else {
            throw DrupalError(
                .configInvalid,
                "cannot derive a project name from directory '\(root.lastPathComponent)': it has no letters or digits",
                details: [.init(path: "name", message: "set `name:` in \(ProjectLayout.configRelativePath)")],
                hint: "Add a `name:` entry, or pass --name to `drupal init`."
            )
        }
        let hostname = ProjectName.hostname(for: name)
        let docrootPath = config.docroot.isEmpty
            ? root
            : root.appending(path: config.docroot, directoryHint: .isDirectory).standardizedFileURL

        var warnings: [String] = []
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: docrootPath.filePath, isDirectory: &isDir) || !isDir.boolValue {
            warnings.append("docroot '\(config.docroot)' does not exist yet at \(docrootPath.filePath)")
        }

        return ResolvedProject(
            name: name,
            nameSource: source,
            hostname: hostname,
            url: "http://\(hostname)",
            root: root,
            configFile: ProjectLayout.configFile(in: root),
            docrootPath: docrootPath,
            config: config,
            defaultsApplied: defaultableKeys.filter { !parsed.explicitKeys.contains($0) },
            images: Images(web: DDEVImages.web, db: DDEVImages.db(config.database)),
            warnings: warnings
        )
    }

    /// Finds, loads, validates, and resolves the project containing `directory`.
    public static func locate(from directory: URL) throws(DrupalError) -> ResolvedProject {
        let root = try ProjectLayout.findRoot(from: directory)
        return try resolve(root: root, parsed: ProjectLayout.load(root: root))
    }
}
