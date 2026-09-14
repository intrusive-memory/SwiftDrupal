import Foundation

/// Pure functions deriving the project name and local hostname.
public enum ProjectNaming {
    /// Top-level domain used for local project hostnames.
    public static let hostnameSuffix = "drupal"

    /// The project name: an explicit, non-blank `name:` wins; otherwise the
    /// name of the project directory (the directory holding the config).
    public static func projectName(directoryName: String, explicitName: String?) -> String {
        if let explicit = explicitName?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
            return explicit
        }
        return directoryName
    }

    /// The project name for the project rooted at `projectRoot` with `config`.
    public static func projectName(projectRoot: URL, config: ProjectConfig?) -> String {
        projectName(
            directoryName: projectRoot.standardizedFileURL.lastPathComponent,
            explicitName: config?.name
        )
    }

    /// The local hostname for a project: `<name>.drupal`.
    public static func hostname(projectName: String) -> String {
        "\(projectName).\(hostnameSuffix)"
    }
}
