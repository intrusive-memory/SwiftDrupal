import Foundation

// Rendering for `drupal logs`: the TTY TUI (colorized scrolling lines) and
// the non-TTY/`--json` mode (one compact JSON object per line). Both write
// straight to real stdio with one `FileHandle.write` per line — a direct
// syscall, not buffered `print()` — so each line is flushed as it is
// produced, matching `LiveExecOutputSink`'s approach in ExecIO.swift.

/// Receives merged, source-tagged log lines one at a time, in emission order.
public protocol LogLineSink: Sendable {
    func write(_ entry: SourcedLogLine)
}

// MARK: - JSON mode

/// The exact shape of one `--json`/non-TTY log line: `timestamp` (ISO 8601,
/// UTC, with fractional seconds), `service`, `stream`, `message`.
public struct LogLineJSONDocument: Codable, Equatable, Sendable {
    public var timestamp: String
    public var service: String
    public var stream: String
    public var message: String

    public init(timestamp: String, service: String, stream: String, message: String) {
        self.timestamp = timestamp
        self.service = service
        self.stream = stream
        self.message = message
    }
}

public enum LogLineJSON {
    /// ISO 8601 with fractional seconds, always UTC. A fresh formatter per
    /// call: `ISO8601DateFormatter` is a (non-`Sendable`) class, and this
    /// avoids sharing one across concurrent callers.
    public static func timestampString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    public static func document(for entry: SourcedLogLine) -> LogLineJSONDocument {
        LogLineJSONDocument(
            timestamp: timestampString(entry.line.timestamp),
            service: entry.service.rawValue,
            stream: entry.line.stream.rawValue,
            message: entry.line.message
        )
    }

    /// One compact (single-line) JSON object for `entry`, keys sorted for
    /// deterministic output.
    public static func encode(_ entry: SourcedLogLine) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(document(for: entry))) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

/// Writes one compact JSON object per line to stdout.
public struct JSONLogLineSink: LogLineSink {
    public init() {}

    public func write(_ entry: SourcedLogLine) {
        FileHandle.standardOutput.write(Data((LogLineJSON.encode(entry) + "\n").utf8))
    }
}

// MARK: - TUI mode

public enum LogLineTUI {
    /// ANSI SGR color code for `service`'s `[web]`/`[db]` prefix.
    static func ansiColorCode(for service: ContainerRole) -> String {
        switch service {
        case .web: return "36"  // cyan
        case .db: return "35"  // magenta
        }
    }

    /// A plain scrolling line: a colored `[web]`/`[db]` prefix (uncolored
    /// when `colorEnabled` is false, e.g. `NO_COLOR` is set) followed by the
    /// message. No full-screen redraw, no per-stream styling — just enough to
    /// tell the two sources apart at a glance.
    public static func render(_ entry: SourcedLogLine, colorEnabled: Bool) -> String {
        let tag = "[\(entry.service.rawValue)]"
        let prefix = colorEnabled ? "\u{001B}[\(ansiColorCode(for: entry.service))m\(tag)\u{001B}[0m" : tag
        return "\(prefix) \(entry.line.message)"
    }
}

/// Writes plain, colorized-by-source scrolling lines to stdout.
public struct TUILogLineSink: LogLineSink {
    public let colorEnabled: Bool

    public init(colorEnabled: Bool) {
        self.colorEnabled = colorEnabled
    }

    public func write(_ entry: SourcedLogLine) {
        FileHandle.standardOutput.write(Data((LogLineTUI.render(entry, colorEnabled: colorEnabled) + "\n").utf8))
    }
}
