import Foundation

/// Resolves the `<service>` argument of `drupal exec`/`drupal ssh` (a
/// container role, "web" or "db") and the project rooted at the current
/// directory into the container id the host service knows it by
/// (`ContainerNaming.containerID`, the same derivation `start` uses).
public enum ServiceTarget {
    /// `drupal ssh` with no argument opens a shell in the web container.
    public static let defaultRole = ContainerRole.web

    /// Parses `raw` as a container role. `nil` or empty yields `defaultRole`
    /// (only `ssh` allows this). Case-insensitive. Throws
    /// `DrupalError.invalidConfig` for anything else.
    public static func role(for raw: String?) throws -> ContainerRole {
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return defaultRole }
        guard let role = ContainerRole(rawValue: raw.lowercased()) else {
            throw DrupalError.invalidConfig(
                "unknown service \"\(raw)\"; expected \"web\" or \"db\"")
        }
        return role
    }

    /// The container id for `role` in the project rooted at `projectRoot`.
    /// Loads the project config to resolve an explicit `name:`, so this
    /// matches the id `start` created the container under. Throws
    /// `DrupalError.invalidConfig` when the config is missing or malformed.
    public static func containerID(role: ContainerRole, projectRoot: URL) throws -> String {
        let config = try ProjectConfig.load(projectRoot: projectRoot)
        let projectName = ProjectNaming.projectName(projectRoot: projectRoot, config: config)
        return ContainerNaming.containerID(projectName: projectName, role: role)
    }
}
