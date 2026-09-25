// Semantic checks on a typed `ProjectConfig`, shared by the YAML parser and
// by `init`/`config` (which build a config from flags). Returns every
// problem, not just the first.

public enum ConfigValidator {
    public static func validate(_ config: ProjectConfig) -> [DrupalError.Detail] {
        var issues: [DrupalError.Detail] = []
        func add(_ path: String, _ message: String) { issues.append(.init(path: path, message: message)) }

        if let name = config.name, let problem = ProjectName.validationProblem(name) {
            let suggestion = ProjectName.sanitize(name).map { " (try '\($0)')" } ?? ""
            add("name", "invalid project name '\(name)': \(problem)\(suggestion)")
        }

        if let problem = docrootProblem(config.docroot) {
            add("docroot", problem)
        }

        if !ProjectConfig.Supported.phpVersions.contains(config.phpVersion) {
            add("php_version", "unsupported php_version '\(config.phpVersion)'; expected one of: \(quoted(ProjectConfig.Supported.phpVersions))")
        }

        if config.database.type == .mariadb, !ProjectConfig.Supported.mariadbVersions.contains(config.database.version) {
            add("database.version", "unsupported MariaDB version '\(config.database.version)'; expected one of: \(quoted(ProjectConfig.Supported.mariadbVersions))")
        }

        var seen: Set<String> = []
        for (i, entry) in config.webEnvironment.enumerated() {
            let path = "web_environment[\(i)]"
            guard let eq = entry.firstIndex(of: "=") else {
                add(path, "'\(entry)' must be in KEY=value form")
                continue
            }
            let key = String(entry[..<eq])
            if !isEnvName(key) {
                add(path, "'\(key)' is not a valid environment variable name (letters, digits, '_'; not starting with a digit)")
            } else if !seen.insert(key).inserted {
                add(path, "duplicate variable '\(key)'")
            }
        }

        for (i, command) in config.postStart.enumerated() where command.allSatisfy(\.isWhitespace) {
            add("post_start[\(i)]", "commands must not be empty")
        }

        if let node = config.nodejsVersion, !isVersionNumber(node) {
            add("nodejs_version", "invalid nodejs_version '\(node)'; expected a version number like \"22\" or \"22.11.0\"")
        }

        return issues
    }

    static func docrootProblem(_ docroot: String) -> String? {
        if docroot.hasPrefix("/") || docroot.hasPrefix("~") {
            return "docroot '\(docroot)' must be relative to the project root"
        }
        if docroot.split(separator: "/").contains("..") {
            return "docroot '\(docroot)' must stay inside the project (no '..')"
        }
        return nil
    }

    static func isEnvName(_ s: String) -> Bool {
        guard let first = s.unicodeScalars.first, !("0"..."9").contains(first) else { return false }
        return s.unicodeScalars.allSatisfy { $0 == "_" || ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) }
    }

    static func isVersionNumber(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        return (1...3).contains(parts.count) && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }
    }

    private static func quoted(_ values: [String]) -> String {
        values.map { "'\($0)'" }.joined(separator: ", ")
    }
}
