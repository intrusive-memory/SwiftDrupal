import Foundation

/// The single seam for writes to root-owned system files
/// (`/etc/resolver/drupal`, `/etc/hosts`).
///
/// Tests use `DirectFileWriter` against temp files; only the live
/// `AdministratorFileWriter` escalates privileges.
public protocol PrivilegedFileWriter: Sendable {
    /// Reads a file's contents, or `nil` if it does not exist or is unreadable.
    func readFile(atPath path: String) -> String?
    /// Atomically replaces the file's contents, creating parent directories.
    func writeFile(_ contents: String, atPath path: String) throws
    /// Removes the file. Succeeds if it is already absent.
    func removeFile(atPath path: String) throws
}

extension PrivilegedFileWriter {
    public func readFile(atPath path: String) -> String? {
        try? String(contentsOfFile: path, encoding: .utf8)
    }
}

/// Unprivileged writer: plain Foundation file I/O as the current user.
public struct DirectFileWriter: PrivilegedFileWriter {
    public init() {}

    public func writeFile(_ contents: String, atPath path: String) throws {
        let url = URL(filePath: path)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw HostnameError.privilegedWriteFailed("\(path): \(error.localizedDescription)")
        }
    }

    public func removeFile(atPath path: String) throws {
        guard FileManager.default.fileExists(atPath: path) else { return }
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch {
            throw HostnameError.privilegedWriteFailed("\(path): \(error.localizedDescription)")
        }
    }
}

/// Live writer for root-owned files. Stages content in a user-owned temp file,
/// then copies it into place with elevated privileges.
///
/// NOT exercised by tests — it would prompt for credentials and modify the
/// real system.
public struct AdministratorFileWriter: PrivilegedFileWriter {
    public enum Escalation: Sendable {
        /// `osascript ... with administrator privileges` — GUI password prompt.
        case appleScriptPrompt
        /// `sudo -n` — non-interactive; requires cached credentials or a
        /// NOPASSWD sudoers rule. Suited to unattended agent use.
        case sudoNonInteractive
    }

    public let escalation: Escalation

    public init(escalation: Escalation = .appleScriptPrompt) {
        self.escalation = escalation
    }

    public func writeFile(_ contents: String, atPath path: String) throws {
        if geteuid() == 0 { return try DirectFileWriter().writeFile(contents, atPath: path) }
        let staging = FileManager.default.temporaryDirectory
            .appending(path: "swiftdrupal-\(UUID().uuidString)")
        try DirectFileWriter().writeFile(contents, atPath: staging.path)
        defer { try? FileManager.default.removeItem(at: staging) }
        let directory = URL(filePath: path).deletingLastPathComponent().path
        let command = "/bin/mkdir -p \(Self.shellQuote(directory))"
            + " && /bin/cp \(Self.shellQuote(staging.path)) \(Self.shellQuote(path))"
            + " && /bin/chmod 644 \(Self.shellQuote(path))"
        try runPrivileged(command)
    }

    public func removeFile(atPath path: String) throws {
        if geteuid() == 0 { return try DirectFileWriter().removeFile(atPath: path) }
        guard FileManager.default.fileExists(atPath: path) else { return }
        try runPrivileged("/bin/rm -f \(Self.shellQuote(path))")
    }

    private func runPrivileged(_ shellCommand: String) throws {
        let process = Process()
        switch escalation {
        case .appleScriptPrompt:
            let escaped = shellCommand
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            process.executableURL = URL(filePath: "/usr/bin/osascript")
            process.arguments = ["-e", "do shell script \"\(escaped)\" with administrator privileges"]
        case .sudoNonInteractive:
            process.executableURL = URL(filePath: "/usr/bin/sudo")
            process.arguments = ["-n", "/bin/sh", "-c", shellCommand]
        }
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw HostnameError.privilegedWriteFailed(error.localizedDescription)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw HostnameError.privilegedWriteFailed(
                "exit \(process.terminationStatus): \(message.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
