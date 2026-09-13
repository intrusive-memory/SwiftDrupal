import Foundation

/// Pure text transforms for `/etc/hosts`-format content.
///
/// Only lines carrying `marker` are ever modified or removed; every other
/// byte of the file is preserved.
public enum HostsFileEditor {
    public static let marker = "# managed-by: drupal"

    /// The line this tool owns for `hostname`.
    public static func line(hostname: String, ip: IPv4) -> String {
        "\(ip)\t\(hostname.lowercased())\t\(marker)"
    }

    /// Inserts (or replaces) the owned mapping for `hostname`. Idempotent:
    /// applying it twice yields identical content.
    public static func inserting(hostname: String, ip: IPv4, into content: String) -> String {
        var result = removing(hostname: hostname, from: content)
        if !result.isEmpty, !result.hasSuffix("\n") { result += "\n" }
        return result + line(hostname: hostname, ip: ip) + "\n"
    }

    /// Removes only owned lines mapping `hostname`.
    public static func removing(hostname: String, from content: String) -> String {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        let kept = lines.filter { !isOwnedLine($0, hostname: hostname) }
        return kept.joined(separator: "\n")
    }

    static func isOwnedLine(_ line: Substring, hostname: String) -> Bool {
        guard line.hasSuffix(marker) else { return false }
        let fields = line.dropLast(marker.count).split(whereSeparator: { $0 == " " || $0 == "\t" })
        return fields.count >= 2 && fields.dropFirst().contains { $0.lowercased() == hostname.lowercased() }
    }

    /// The first IPv4 address any non-comment line maps `hostname` to.
    public static func address(for hostname: String, in content: String) -> IPv4? {
        for rawLine in content.split(separator: "\n") {
            let uncommented = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let fields = uncommented.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 2, let ip = IPv4(String(fields[0])) else { continue }
            if fields.dropFirst().contains(where: { $0.lowercased() == hostname.lowercased() }) {
                return ip
            }
        }
        return nil
    }
}
