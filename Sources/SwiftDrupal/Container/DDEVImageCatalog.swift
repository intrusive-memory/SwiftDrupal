import Foundation

/// The single source of truth for which published DDEV image a project uses.
///
/// How DDEV's images are actually published (and therefore how selection works):
///
/// | Config                      | Image reference                                           | Selector            |
/// | --------------------------- | --------------------------------------------------------- | ------------------- |
/// | `php_version`               | `docker.io/ddev/ddev-webserver:<releaseTag>`              | env `DDEV_PHP_VERSION` |
/// | `webserver_type`            | (same image)                                              | env `DDEV_WEBSERVER_TYPE` |
/// | `database.version` (MariaDB)| `docker.io/ddev/ddev-dbserver-mariadb-<version>:<releaseTag>` | image repository name |
///
/// `ddev-webserver` is one multi-PHP image: every supported PHP version and both
/// nginx-fpm and apache-fpm are installed, and the container's start script picks
/// them from `DDEV_PHP_VERSION` / `DDEV_WEBSERVER_TYPE`. There is no per-PHP tag
/// to pick. `ddev-dbserver` does publish one repository per engine+version, so the
/// database version selects the repository and the release tag selects the build.
///
/// Both configured values are validated against the supported lists below so an
/// unsupported value fails as `invalidConfig` before any image is pulled.
public enum DDEVImageCatalog {
    /// Registry + namespace for DDEV's images.
    public static let registryNamespace = "docker.io/ddev"

    /// DDEV release whose images we run. All image references share this tag.
    /// TODO(verify): confirm this tag is published for both repositories on
    /// Docker Hub (linux/arm64) before the first live `drupal start`.
    public static let releaseTag = "v1.24.8"

    public static let supportedPHPVersions: [String] = [
        "5.6", "7.0", "7.1", "7.2", "7.3", "7.4", "8.0", "8.1", "8.2", "8.3", "8.4",
    ]

    public static let supportedWebserverTypes: [String] = ["nginx-fpm", "apache-fpm"]

    /// v1.0 supports MariaDB only.
    public static let supportedDatabaseTypes: [String] = ["mariadb"]

    public static let supportedMariaDBVersions: [String] = [
        "5.5", "10.0", "10.1", "10.2", "10.3", "10.4", "10.5", "10.6", "10.7", "10.8",
        "10.11", "11.4", "11.8",
    ]

    /// Environment keys the web image reads to select PHP and web server.
    public static let phpVersionEnvironmentKey = "DDEV_PHP_VERSION"
    public static let webserverTypeEnvironmentKey = "DDEV_WEBSERVER_TYPE"

    /// Image selection for the web container.
    public struct WebImageSelection: Equatable, Sendable {
        public var reference: String
        /// `KEY=value` selector entries that must be injected into the container.
        public var selectorEnvironment: [String]
    }

    /// Selects the web image for `phpVersion` + `webserverType`.
    /// Throws `DrupalError.invalidConfig` for unsupported values.
    public static func webImage(phpVersion: String, webserverType: String) throws -> WebImageSelection {
        guard supportedPHPVersions.contains(phpVersion) else {
            throw DrupalError.invalidConfig(
                "unsupported php_version \"\(phpVersion)\"; supported: \(supportedPHPVersions.joined(separator: ", "))"
            )
        }
        guard supportedWebserverTypes.contains(webserverType) else {
            throw DrupalError.invalidConfig(
                "unsupported webserver_type \"\(webserverType)\"; supported: \(supportedWebserverTypes.joined(separator: ", "))"
            )
        }
        return WebImageSelection(
            reference: reference(repository: "ddev-webserver"),
            selectorEnvironment: [
                "\(phpVersionEnvironmentKey)=\(phpVersion)",
                "\(webserverTypeEnvironmentKey)=\(webserverType)",
            ]
        )
    }

    /// Selects the database image for `type` + `version`.
    /// Throws `DrupalError.invalidConfig` for non-MariaDB types or unsupported versions.
    public static func databaseImage(type: String, version: String) throws -> String {
        guard supportedDatabaseTypes.contains(type) else {
            throw DrupalError.invalidConfig(
                "unsupported database.type \"\(type)\"; v1.0 supports: \(supportedDatabaseTypes.joined(separator: ", "))"
            )
        }
        guard supportedMariaDBVersions.contains(version) else {
            throw DrupalError.invalidConfig(
                "unsupported database.version \"\(version)\" for mariadb; supported: \(supportedMariaDBVersions.joined(separator: ", "))"
            )
        }
        return reference(repository: "ddev-dbserver-\(type)-\(version)")
    }

    /// The one place the reference format lives: `<registryNamespace>/<repository>:<releaseTag>`.
    static func reference(repository: String) -> String {
        "\(registryNamespace)/\(repository):\(releaseTag)"
    }
}
