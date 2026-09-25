import Foundation

// Project names become the DNS label in `<name>.drupal`, so they must be a
// valid RFC 1123 hostname label: 1–63 chars of [a-z0-9-], not starting or
// ending with '-'.
//
// Directory names are sanitized into that shape; an explicit `name:` in the
// config is validated as-is (never silently rewritten).

public enum ProjectName {
    public static let tld = "drupal"
    public static let maxLength = 63

    /// Derives a label from a directory name:
    /// 1. strip diacritics (`café` → `cafe`), lowercase;
    /// 2. every run of characters outside [a-z0-9] becomes a single '-';
    /// 3. trim leading/trailing '-';
    /// 4. truncate to 63 characters, then trim trailing '-' again.
    /// Returns nil when nothing usable remains (e.g. `___` or `日本`).
    public static func sanitize(_ raw: String) -> String? {
        let folded = raw.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        var out = ""
        var pendingDash = false
        for scalar in folded.unicodeScalars {
            if isLabelAlnum(scalar) {
                if pendingDash && !out.isEmpty { out.append("-") }
                pendingDash = false
                out.unicodeScalars.append(scalar)
            } else {
                pendingDash = true
            }
        }
        if out.count > maxLength {
            out = String(out.prefix(maxLength))
            while out.hasSuffix("-") { out.removeLast() }
        }
        return out.isEmpty ? nil : out
    }

    /// Why `name` is not a valid label, or nil if it is.
    public static func validationProblem(_ name: String) -> String? {
        if name.isEmpty { return "must not be empty" }
        if name.unicodeScalars.count > maxLength { return "must be at most \(maxLength) characters (got \(name.unicodeScalars.count))" }
        if let bad = name.unicodeScalars.first(where: { !isLabelAlnum($0) && $0 != "-" }) {
            return "may only contain lowercase letters, digits, and '-' (found '\(bad)')"
        }
        if name.hasPrefix("-") || name.hasSuffix("-") { return "must not start or end with '-'" }
        return nil
    }

    public static func hostname(for name: String) -> String { "\(name).\(tld)" }

    private static func isLabelAlnum(_ s: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(s) || ("0"..."9").contains(s)
    }
}
