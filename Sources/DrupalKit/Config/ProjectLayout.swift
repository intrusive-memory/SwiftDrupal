import Foundation

// Where a project's config lives and how commands find it.

extension URL {
    /// Plain filesystem path without a trailing slash (except for "/"), as
    /// printed in output.
    public var filePath: String {
        let p = path(percentEncoded: false)
        return p.count > 1 && p.hasSuffix("/") ? String(p.dropLast()) : p
    }
}

public enum ProjectLayout {
    public static let configDirectory = ".drupal"
    public static let configFileName = "config.yaml"
    public static let configRelativePath = "\(configDirectory)/\(configFileName)"

    public static func configFile(in root: URL) -> URL {
        root.appending(path: configDirectory, directoryHint: .isDirectory)
            .appending(path: configFileName, directoryHint: .notDirectory)
    }

    /// Walks up from `start` to the nearest directory containing
    /// `.drupal/config.yaml`, like git does for `.git`.
    public static func findRoot(from start: URL) throws(DrupalError) -> URL {
        var dir = start.standardizedFileURL
        while true {
            if FileManager.default.fileExists(atPath: configFile(in: dir).filePath) {
                return dir
            }
            let parent = dir.deletingLastPathComponent().standardizedFileURL
            if parent.path == dir.path { break }
            dir = parent
        }
        throw DrupalError(
            .projectNotFound,
            "no \(configRelativePath) found in \(start.filePath) or any parent directory",
            hint: "Run `drupal init` in the project root, or pass --project-dir."
        )
    }

    /// Reads and parses the config at `root`.
    public static func load(root: URL) throws(DrupalError) -> ParsedConfig {
        let file = configFile(in: root)
        let text: String
        do {
            text = try String(contentsOf: file, encoding: .utf8)
        } catch {
            throw DrupalError(.ioError, "could not read \(file.filePath): \(error.localizedDescription)")
        }
        return try ConfigParser.parse(text, file: file.filePath)
    }
}
