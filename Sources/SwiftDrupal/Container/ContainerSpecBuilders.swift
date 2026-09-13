import Foundation

/// Container id derivation shared by both spec builders.
public enum ContainerNaming {
    /// `LinuxContainer.maxIDLength` in Containerization.
    public static let maxIDLength = 64

    /// `<sanitized project name>-<role>`, e.g. `my-site-web`. Characters outside
    /// `[a-z0-9_.-]` become `-`; the name part is truncated so the id fits 64 chars.
    public static func containerID(projectName: String, role: ContainerRole) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789_.-")
        var name = String(projectName.lowercased().map { allowed.contains($0) ? $0 : "-" })
        if name.isEmpty { name = "project" }
        let suffix = "-\(role.rawValue)"
        return String(name.prefix(maxIDLength - suffix.count)) + suffix
    }
}

/// Builds the `ddev-webserver` container spec for a project.
///
/// Mount layout (mirrors DDEV): the whole project root is shared over virtiofs at
/// `/var/www/html`, and the configured `docroot` is the subdirectory the web
/// server serves (`/var/www/html/<docroot>`), communicated via `DDEV_DOCROOT`.
/// Mounting the project root (not just the docroot) keeps `composer.json`,
/// `vendor/`, and `drush` reachable inside the container.
public struct WebContainerSpecBuilder: Sendable {
    /// Where the project root is mounted in the web container.
    public static let projectMountPath = "/var/www/html"
    public static let docrootEnvironmentKey = "DDEV_DOCROOT"

    public var projectName: String
    public var projectRoot: URL
    public var config: ProjectConfig

    public init(projectName: String, projectRoot: URL, config: ProjectConfig) {
        self.projectName = projectName
        self.projectRoot = projectRoot
        self.config = config
    }

    /// Environment keys the builder owns; `web_environment` may not set them.
    public static let reservedEnvironmentKeys: Set<String> = [
        "DDEV_PROJECT",
        "DDEV_HOSTNAME",
        docrootEnvironmentKey,
        DDEVImageCatalog.phpVersionEnvironmentKey,
        DDEVImageCatalog.webserverTypeEnvironmentKey,
    ]

    /// Normalized docroot relative to the project root ("" for the root itself).
    /// Throws `invalidConfig` for absolute paths or `..` components.
    public static func normalizedDocroot(_ docroot: String) throws -> String {
        let trimmed = docroot.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/") {
            throw DrupalError.invalidConfig("docroot \"\(docroot)\" must be relative to the project root")
        }
        let components = trimmed.split(separator: "/").filter { $0 != "." }
        if components.contains("..") {
            throw DrupalError.invalidConfig("docroot \"\(docroot)\" must not contain \"..\"")
        }
        return components.joined(separator: "/")
    }

    /// Absolute in-container path of the docroot, e.g. `/var/www/html/web`.
    public static func containerDocrootPath(docroot: String) throws -> String {
        let relative = try normalizedDocroot(docroot)
        return relative.isEmpty ? projectMountPath : "\(projectMountPath)/\(relative)"
    }

    /// The virtiofs bind mount of the project directory.
    public static func projectMount(projectRoot: URL) -> MountSpec {
        MountSpec(
            kind: .virtiofs,
            hostPath: projectRoot.standardizedFileURL.path(percentEncoded: false).trimmingTrailingSlash,
            containerPath: projectMountPath
        )
    }

    public func build() throws -> ContainerSpec {
        let image = try DDEVImageCatalog.webImage(
            phpVersion: config.phpVersion,
            webserverType: config.webserverType
        )
        let docroot = try Self.normalizedDocroot(config.docroot)

        try EnvironmentList.validate(config.webEnvironment, field: "web_environment")
        if let clash = config.webEnvironment.first(where: {
            Self.reservedEnvironmentKeys.contains(EnvironmentList.key(of: $0))
        }) {
            throw DrupalError.invalidConfig(
                "web_environment entry \"\(clash)\" sets a variable drupal manages; change the matching config field instead"
            )
        }

        let hostname = ProjectNaming.hostname(projectName: projectName)
        let base = [
            "DDEV_PROJECT=\(projectName)",
            "DDEV_HOSTNAME=\(hostname)",
            "\(Self.docrootEnvironmentKey)=\(docroot)",
        ] + image.selectorEnvironment

        return ContainerSpec(
            id: ContainerNaming.containerID(projectName: projectName, role: .web),
            role: .web,
            imageReference: image.reference,
            hostname: hostname,
            environment: EnvironmentList.merge(base, config.webEnvironment),
            mounts: [Self.projectMount(projectRoot: projectRoot)],
            workingDirectory: Self.projectMountPath
        )
    }
}

/// Builds the `ddev-dbserver` (MariaDB) container spec for a project.
///
/// The data directory is a persistent host directory outside the project tree
/// (so it is not visible through the web container's project mount), shared over
/// virtiofs at `/var/lib/mysql`.
public struct DatabaseContainerSpecBuilder: Sendable {
    public static let dataDirectoryContainerPath = "/var/lib/mysql"

    public var projectName: String
    public var config: ProjectConfig
    /// Root for per-project runtime state; see `defaultStateRoot`.
    public var stateRoot: URL

    public init(projectName: String, config: ProjectConfig, stateRoot: URL = DatabaseContainerSpecBuilder.defaultStateRoot) {
        self.projectName = projectName
        self.config = config
        self.stateRoot = stateRoot
    }

    /// `~/Library/Application Support/drupal`.
    public static var defaultStateRoot: URL {
        URL.applicationSupportDirectory.appending(path: "drupal", directoryHint: .isDirectory)
    }

    /// `<stateRoot>/projects/<container-safe project name>/db`.
    public static func dataDirectoryHostURL(stateRoot: URL, projectName: String) -> URL {
        let id = ContainerNaming.containerID(projectName: projectName, role: .db)
        let safeName = String(id.dropLast("-db".count))
        return stateRoot
            .appending(path: "projects", directoryHint: .isDirectory)
            .appending(path: safeName, directoryHint: .isDirectory)
            .appending(path: "db", directoryHint: .isDirectory)
    }

    public func build() throws -> ContainerSpec {
        let reference = try DDEVImageCatalog.databaseImage(
            type: config.database.type,
            version: config.database.version
        )
        let dataDirectory = Self.dataDirectoryHostURL(stateRoot: stateRoot, projectName: projectName)
        return ContainerSpec(
            id: ContainerNaming.containerID(projectName: projectName, role: .db),
            role: .db,
            imageReference: reference,
            hostname: ContainerNaming.containerID(projectName: projectName, role: .db),
            environment: ["DDEV_PROJECT=\(projectName)"],
            mounts: [
                MountSpec(
                    kind: .virtiofs,
                    hostPath: dataDirectory.standardizedFileURL.path(percentEncoded: false).trimmingTrailingSlash,
                    containerPath: Self.dataDirectoryContainerPath,
                    persistent: true
                )
            ]
        )
    }
}

extension String {
    fileprivate var trimmingTrailingSlash: String {
        var s = self
        while s.count > 1, s.hasSuffix("/") { s.removeLast() }
        return s
    }
}
