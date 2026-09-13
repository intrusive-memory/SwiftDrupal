import ArgumentParser
import Foundation

/// `--project-root`, shared by the lifecycle commands.
public struct LifecycleProjectOptions: ParsableArguments, Sendable {
    @Option(
        name: .customLong("project-root"),
        help: "Project root (the directory holding .drupal/config.yaml). Defaults to the nearest ancestor of the current directory that has one.")
    public var projectRoot: String?

    public init() {}
}

/// A project whose config has been loaded and turned into container specs.
///
/// Building the specs validates the config (image catalog, docroot,
/// `web_environment`) before anything talks to the service.
public struct LifecycleProject: Sendable {
    public let root: URL
    public let config: ProjectConfig
    public let name: String
    public let hostname: String
    public let webSpec: ContainerSpec
    public let dbSpec: ContainerSpec

    public init(root: URL, config: ProjectConfig, stateRoot: URL) throws {
        let root = root.standardizedFileURL
        self.root = root
        self.config = config
        name = ProjectNaming.projectName(projectRoot: root, config: config)
        hostname = ProjectNaming.hostname(projectName: name)
        webSpec = try WebContainerSpecBuilder(projectName: name, projectRoot: root, config: config).build()
        dbSpec = try DatabaseContainerSpecBuilder(projectName: name, config: config, stateRoot: stateRoot).build()
    }

    public var configURL: URL { ProjectConfig.configFileURL(projectRoot: root) }
    public var url: String { "http://\(hostname)" }
    /// Specs in start order (database first).
    public var specsInStartOrder: [ContainerSpec] { [dbSpec, webSpec] }
    /// Specs in stop order (web first).
    public var specsInStopOrder: [ContainerSpec] { [webSpec, dbSpec] }

    /// Nearest directory at or above `directory` containing `.drupal/config.yaml`.
    public static func locateRoot(from directory: URL) -> URL? {
        var candidate = directory.standardizedFileURL
        while true {
            if FileManager.default.fileExists(atPath: ProjectConfig.configFileURL(projectRoot: candidate).path) {
                return candidate
            }
            let parent = candidate.deletingLastPathComponent().standardizedFileURL
            if parent.path == candidate.path { return nil }
            candidate = parent
        }
    }

    /// The project root named by `--project-root`, or `currentDirectory` itself.
    /// Used by `init`, which creates the config rather than finding one.
    public static func explicitOrCurrentRoot(_ explicit: String?, currentDirectory: URL) -> URL {
        guard let explicit, !explicit.isEmpty else { return currentDirectory.standardizedFileURL }
        return URL(filePath: explicit, directoryHint: .isDirectory, relativeTo: currentDirectory).standardizedFileURL
    }

    /// Loads the project for a command that needs an existing config.
    /// Throws `DrupalError.invalidConfig` when none is found or it is invalid.
    public static func load(options: LifecycleProjectOptions, environment: LifecycleEnvironment) throws -> LifecycleProject {
        let cwd = environment.currentDirectory()
        let root: URL
        if let explicit = options.projectRoot, !explicit.isEmpty {
            root = explicitOrCurrentRoot(explicit, currentDirectory: cwd)
        } else if let found = locateRoot(from: cwd) {
            root = found
        } else {
            throw DrupalError.invalidConfig(
                "no \(ProjectConfig.configDirectoryName)/\(ProjectConfig.configFileName) found in \(cwd.path) or any parent directory; run `drupal init` in the project root")
        }
        let config = try ProjectConfig.load(projectRoot: root)
        return try LifecycleProject(root: root, config: config, stateRoot: environment.stateRoot)
    }
}

// MARK: - Resolved configuration report

/// The fully resolved configuration: what `start` will actually do.
/// Emitted by `init`, `config`, `validate`, and inside `status`.
public struct ResolvedConfigReport: Codable, Equatable, Sendable {
    public struct ContainerPlan: Codable, Equatable, Sendable {
        public var role: ContainerRole
        public var id: String
        public var image: String
        public var environment: [String]
        public var mounts: [MountSpec]
    }

    public var projectRoot: String
    public var configPath: String
    /// Effective project name.
    public var name: String
    /// `config` when `name:` is set in the file, otherwise `directory`.
    public var nameSource: String
    public var hostname: String
    public var url: String
    /// The config with defaults applied (keys as in the YAML file).
    public var config: ProjectConfig
    /// Absolute in-container path of the docroot.
    public var docrootPath: String
    public var containers: [ContainerPlan]

    public init(project: LifecycleProject) throws {
        projectRoot = project.root.path(percentEncoded: false)
        configPath = project.configURL.path(percentEncoded: false)
        name = project.name
        let explicit = project.config.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        nameSource = explicit.isEmpty ? "directory" : "config"
        hostname = project.hostname
        url = project.url
        config = project.config
        docrootPath = try WebContainerSpecBuilder.containerDocrootPath(docroot: project.config.docroot)
        containers = project.specsInStartOrder.map {
            ContainerPlan(role: $0.role, id: $0.id, image: $0.imageReference, environment: $0.environment, mounts: $0.mounts)
        }
    }

    var textSummary: String {
        var lines = [
            "Project: \(name) (name from \(nameSource))",
            "Root: \(projectRoot)",
            "Config: \(configPath)",
            "URL: \(url)",
            "Docroot: \(config.docroot) -> \(docrootPath)",
            "PHP: \(config.phpVersion) (\(config.webserverType))",
            "Database: \(config.database.type) \(config.database.version)",
        ]
        if !config.webEnvironment.isEmpty {
            lines.append("web_environment: \(config.webEnvironment.joined(separator: ", "))")
        }
        for container in containers {
            lines.append("\(container.role.rawValue): \(container.id) <- \(container.image)")
        }
        return lines.joined(separator: "\n")
    }
}
