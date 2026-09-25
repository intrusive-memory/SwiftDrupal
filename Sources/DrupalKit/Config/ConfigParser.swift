import Foundation
import Yams

// YAML text → `ProjectConfig`. Parsing works on the Yams node tree rather
// than `Decodable` so every problem (unknown key, wrong type, bad value) is
// reported with its dotted path and line, and all problems are reported at
// once instead of stopping at the first.

public struct ParsedConfig: Sendable, Equatable {
    public var config: ProjectConfig
    /// Dotted paths the file set explicitly (non-null), e.g. `database.version`.
    public var explicitKeys: Set<String>
}

public enum ConfigParser {
    public static func parse(_ yaml: String, file: String = ProjectLayout.configRelativePath) throws(DrupalError) -> ParsedConfig {
        let root: Node?
        do {
            root = try Yams.compose(yaml: yaml)
        } catch {
            throw invalid(file, [syntaxDetail(error)])
        }
        var reader = Reader()
        var config = ProjectConfig()
        if let root { reader.readTopLevel(root, into: &config) }
        let issues = reader.issues + ConfigValidator.validate(config).map { detail in
            var d = detail
            if let path = d.path, d.line == nil { d.line = reader.lines[path] }
            return d
        }
        guard issues.isEmpty else { throw invalid(file, issues) }
        return ParsedConfig(config: config, explicitKeys: reader.explicit)
    }

    static func invalid(_ file: String, _ issues: [DrupalError.Detail]) -> DrupalError {
        let first = issues[0]
        let where_ = [first.line.map { "line \($0)" }, first.path].compactMap { $0 }.joined(separator: ", ")
        let lead = where_.isEmpty ? first.message : "\(where_): \(first.message)"
        let message = issues.count == 1
            ? "\(file) is invalid: \(lead)"
            : "\(file) has \(issues.count) problems; first: \(lead)"
        return DrupalError(.configInvalid, message, details: issues, hint: "Fix the file, then run `drupal validate`.")
    }

    private static func syntaxDetail(_ error: any Error) -> DrupalError.Detail {
        guard let yamlError = error as? YamlError else {
            return .init(message: "YAML syntax error: \(error)")
        }
        switch yamlError {
        case let .scanner(context, problem, mark, _), let .parser(context, problem, mark, _), let .composer(context, problem, mark, _):
            let ctx = context.map { "\($0.text) " } ?? ""
            return .init(line: mark.line, message: "YAML syntax error: \(ctx)\(problem)")
        default:
            return .init(message: "YAML syntax error: \(yamlError)")
        }
    }
}

/// Keys DDEV users are likely to carry over, with why they are rejected.
private let ddevOnlyKeys: [String: String] = [
    "type": "drupal only runs Drupal projects, so there is no project type to set",
    "hooks": "use the top-level `post_start` list instead of DDEV's hooks",
    "additional_hostnames": "v1.0 serves exactly one hostname, <name>.drupal",
    "additional_fqdns": "v1.0 serves exactly one hostname, <name>.drupal",
    "xdebug_enabled": "Xdebug is out of scope for v1.0",
    "composer_version": "Composer comes from the web image; run it via `drupal exec composer`",
    "use_dns_when_possible": "hostname resolution is handled by drupal itself",
    "router_http_port": "v1.0 has no router",
    "router_https_port": "v1.0 has no router, and no HTTPS",
    "omit_containers": "v1.0 always runs exactly web and db",
    "webimage_extra_packages": "v1.0 uses DDEV's images unmodified",
    "dbimage_extra_packages": "v1.0 uses DDEV's images unmodified",
    "performance_mode": "v1.0 always bind-mounts the project directory",
    "timezone": "not configurable in v1.0",
    "upload_dirs": "not configurable in v1.0",
    "corepack_enable": "Corepack management is out of scope for v1.0",
]

private struct Reader {
    var issues: [DrupalError.Detail] = []
    var explicit: Set<String> = []
    var lines: [String: Int] = [:]

    mutating func issue(_ path: String?, _ node: Node?, _ message: String) {
        issues.append(.init(path: path, line: node?.mark?.line, message: message))
    }

    mutating func readTopLevel(_ root: Node, into config: inout ProjectConfig) {
        guard let map = root.mapping else {
            issue(nil, root, "the file must be a YAML mapping of keys to values (got \(kind(root)))")
            return
        }
        for (keyNode, value) in map {
            guard let key = keyNode.scalar?.string else {
                issue(nil, keyNode, "keys must be plain strings")
                continue
            }
            lines[key] = keyNode.mark?.line
            if isNull(value) { continue }  // `key:` with no value means "use the default"
            switch key {
            case "name": if let s = string(value, key) { config.name = s; explicit.insert(key) }
            case "docroot": if let s = string(value, key) { config.docroot = s; explicit.insert(key) }
            case "php_version": if let s = string(value, key) { config.phpVersion = s; explicit.insert(key) }
            case "webserver_type":
                if let s = string(value, key) {
                    if let t = WebserverType(rawValue: s) {
                        config.webserverType = t
                        explicit.insert(key)
                    } else {
                        issue(key, value, "unsupported webserver_type '\(s)'; expected one of: \(list(WebserverType.allCases.map(\.rawValue)))")
                    }
                }
            case "database": readDatabase(value, into: &config.database)
            case "web_environment": if let a = stringList(value, key) { config.webEnvironment = a; explicit.insert(key) }
            case "post_start": if let a = stringList(value, key) { config.postStart = a; explicit.insert(key) }
            case "nodejs_version": if let s = string(value, key) { config.nodejsVersion = s; explicit.insert(key) }
            default: unknownKey(key, keyNode, known: ProjectConfig.topLevelKeys, prefix: "")
            }
        }
    }

    mutating func readDatabase(_ node: Node, into db: inout DatabaseConfig) {
        guard let map = node.mapping else {
            issue("database", node, "must be a mapping with `type` and `version` (got \(kind(node)))")
            return
        }
        for (keyNode, value) in map {
            guard let key = keyNode.scalar?.string else {
                issue("database", keyNode, "keys must be plain strings")
                continue
            }
            let path = "database.\(key)"
            lines[path] = keyNode.mark?.line
            if isNull(value) { continue }
            switch key {
            case "type":
                if let s = string(value, path) {
                    if let t = DatabaseType(rawValue: s) {
                        db.type = t
                        explicit.insert(path)
                    } else {
                        issue(path, value, "unsupported database type '\(s)'; v1.0 supports only 'mariadb'")
                    }
                }
            case "version": if let s = string(value, path) { db.version = s; explicit.insert(path) }
            default: unknownKey(key, keyNode, known: ProjectConfig.databaseKeys, prefix: "database.")
            }
        }
    }

    mutating func unknownKey(_ key: String, _ node: Node, known: [String], prefix: String) {
        let path = prefix + key
        if prefix.isEmpty, let why = ddevOnlyKeys[key] {
            issue(path, node, "unknown key '\(key)': it is a DDEV setting drupal v1.0 does not support (\(why))")
        } else if let guess = closest(key, in: known) {
            issue(path, node, "unknown key '\(key)' (did you mean '\(prefix)\(guess)'?)")
        } else {
            issue(path, node, "unknown key '\(key)'; allowed keys: \(list(known.map { prefix + $0 }))")
        }
    }

    /// A scalar as its literal text. Unquoted `8.3` is accepted as "8.3".
    mutating func string(_ node: Node, _ path: String) -> String? {
        guard let s = node.scalar?.string else {
            issue(path, node, "must be a single value (got \(kind(node)))")
            return nil
        }
        return s
    }

    mutating func stringList(_ node: Node, _ path: String) -> [String]? {
        guard let seq = node.sequence else {
            issue(path, node, "must be a list (got \(kind(node)))")
            return nil
        }
        var out: [String] = []
        var ok = true
        for (i, item) in seq.enumerated() {
            if let s = item.scalar?.string, !isNull(item) {
                out.append(s)
            } else {
                issue("\(path)[\(i)]", item, "list items must be strings (got \(isNull(item) ? "null" : kind(item)))")
                ok = false
            }
        }
        return ok ? out : nil
    }

    func isNull(_ node: Node) -> Bool {
        guard let s = node.scalar, s.style == .any || s.style == .plain else { return false }
        return ["", "~", "null", "Null", "NULL"].contains(s.string)
    }

    func kind(_ node: Node) -> String {
        switch node {
        case .scalar: "a single value"
        case .mapping: "a mapping"
        case .sequence: "a list"
        case .alias: "an alias"
        }
    }
}

private func list(_ values: [String]) -> String {
    values.map { "'\($0)'" }.joined(separator: ", ")
}

/// Closest known key within edit distance 2, for "did you mean" hints.
func closest(_ word: String, in candidates: [String]) -> String? {
    let scored = candidates.map { ($0, editDistance(word, $0)) }.filter { $0.1 <= 2 }
    return scored.min { $0.1 < $1.1 }?.0
}

func editDistance(_ a: String, _ b: String) -> Int {
    let a = Array(a), b = Array(b)
    if a.isEmpty { return b.count }
    if b.isEmpty { return a.count }
    var prev = Array(0...b.count)
    for i in 1...a.count {
        var cur = [i] + Array(repeating: 0, count: b.count)
        for j in 1...b.count {
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
        }
        prev = cur
    }
    return prev[b.count]
}
