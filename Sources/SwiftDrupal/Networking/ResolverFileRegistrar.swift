import Foundation

/// Writes the one-time `/etc/resolver/drupal` registration that routes
/// `*.drupal` lookups to the local responder.
///
/// Uses the resolver(5) `port` directive so the responder runs on a
/// non-privileged port; only this file write needs elevated privileges.
public struct ResolverFileRegistrar: Sendable {
    public static let defaultPath = "/etc/resolver/\(ProjectNaming.hostnameSuffix)"

    public let path: String
    public let writer: any PrivilegedFileWriter

    public init(path: String = ResolverFileRegistrar.defaultPath, writer: any PrivilegedFileWriter) {
        self.path = path
        self.writer = writer
    }

    /// The exact resolver file contents for a responder on `port`.
    public static func contents(port: UInt16, nameserver: String = LocalDNSServer.loopbackAddress) -> String {
        """
        # Managed by drupal (SwiftDrupal): routes *.\(ProjectNaming.hostnameSuffix) to the local DNS responder.
        nameserver \(nameserver)
        port \(port)

        """
    }

    /// Whether the file already exists with the expected contents.
    public func isRegistered(port: UInt16) -> Bool {
        writer.readFile(atPath: path) == Self.contents(port: port)
    }

    /// Writes the resolver file only if missing or stale, so the privileged
    /// step (and any password prompt) happens once, not on every `start`.
    /// - Returns: `true` if a write was performed.
    @discardableResult
    public func register(port: UInt16) throws -> Bool {
        guard !isRegistered(port: port) else { return false }
        try writer.writeFile(Self.contents(port: port), atPath: path)
        return true
    }

    public func unregister() throws {
        try writer.removeFile(atPath: path)
    }
}
