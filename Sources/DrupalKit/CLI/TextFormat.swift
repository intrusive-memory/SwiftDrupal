import Foundation

// Human-readable (text mode) renderings. Not part of the stable contract;
// agents should use --json.

enum TextFormat {
    static func resolved(_ p: ResolvedProject) -> String {
        let applied = Set(p.defaultsApplied)
        func d(_ key: String) -> String { applied.contains(key) ? " (default)" : "" }
        let c = p.config
        let db = "\(c.database.type.rawValue) \(c.database.version)"
            + (applied.contains("database.type") && applied.contains("database.version") ? " (default)" : "")
        let rows: [(String, String)] = [
            ("name", "\(p.name) (from \(p.nameSource.rawValue))"),
            ("url", p.url),
            ("root", p.root.filePath),
            ("config file", p.configFile.filePath),
            ("docroot", (c.docroot.isEmpty ? "\"\" (project root)" : c.docroot) + d("docroot")),
            ("php_version", c.phpVersion + d("php_version")),
            ("webserver_type", c.webserverType.rawValue + d("webserver_type")),
            ("database", db),
            ("web_environment", c.webEnvironment.isEmpty ? "(none)" : c.webEnvironment.joined(separator: ", ")),
            ("post_start", c.postStart.isEmpty ? "(none)" : c.postStart.joined(separator: " ; ")),
            ("nodejs_version", c.nodejsVersion ?? "(web image default)"),
            ("web image", p.images.web),
            ("db image", p.images.db),
        ]
        return table(rows)
    }

    static func status(_ project: ResolvedProject, _ status: ProjectStatus) -> String {
        var rows: [(String, String)] = [("project", project.name), ("url", project.url), ("state", status.state.rawValue)]
        for s in status.services {
            rows.append((s.service.rawValue, s.state.rawValue + (s.ipAddress.map { " at \($0)" } ?? "")))
        }
        return table(rows)
    }

    static func table(_ rows: [(String, String)]) -> String {
        let width = (rows.map(\.0.count).max() ?? 0) + 2
        return rows.map { k, v in (k + ":").padding(toLength: width, withPad: " ", startingAt: 0) + v }
            .joined(separator: "\n")
    }
}
