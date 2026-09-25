import Foundation

// `ProjectConfig` → YAML text. Hand-rendered (not Yams' emitter) for a
// stable key order and quoting: version strings are always quoted so YAML
// never reads "10.10" as the number 10.1. Output is deterministic, which is
// what makes `init` idempotent (same flags → byte-identical file).

public enum ConfigWriter {
    public static let header = """
        # drupal project config (v1.0). Hand-editable; see docs/cli-contract.md.
        # The project name defaults to this directory's name and the site is
        # served at http://<name>.drupal. Check with: drupal validate


        """

    public static func render(_ config: ProjectConfig) -> String {
        var out = header
        if let name = config.name { out += "name: \(quote(name))\n" }
        out += "docroot: \(quote(config.docroot))\n"
        out += "php_version: \(quote(config.phpVersion))\n"
        out += "webserver_type: \(config.webserverType.rawValue)\n"
        out += "database:\n"
        out += "  type: \(config.database.type.rawValue)\n"
        out += "  version: \(quote(config.database.version))\n"
        out += list("web_environment", config.webEnvironment)
        out += list("post_start", config.postStart)
        if let node = config.nodejsVersion { out += "nodejs_version: \(quote(node))\n" }
        return out
    }

    private static func list(_ key: String, _ items: [String]) -> String {
        if items.isEmpty { return "\(key): []\n" }
        return "\(key):\n" + items.map { "  - \(quote($0))\n" }.joined()
    }

    /// A JSON string literal is also a valid YAML double-quoted scalar.
    static func quote(_ s: String) -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        return (try? String(decoding: e.encode(s), as: UTF8.self)) ?? "\"\""
    }
}
