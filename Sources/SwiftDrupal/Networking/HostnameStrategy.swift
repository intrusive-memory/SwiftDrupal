import Foundation

/// Identifies a hostname-resolution implementation (stable for JSON output).
public enum HostnameStrategyKind: String, Codable, Sendable, CaseIterable {
    case localResolver = "local-resolver"
    case hostsFile = "hosts-file"

    /// v1.0 default (Resolved OQ-1).
    public static let `default`: HostnameStrategyKind = .localResolver
}

/// Makes `<name>.drupal` resolve to the web container's current IP.
///
/// `activate` is called on every `start` with the freshly assigned IP;
/// implementations must be idempotent.
public protocol HostnameStrategy: Sendable {
    var kind: HostnameStrategyKind { get }

    /// Registers (or re-points) `hostname` at `ip`.
    func activate(hostname: String, ip: String) async throws

    /// Re-points an already active `hostname` at a new `ip`.
    func update(hostname: String, ip: String) async throws

    /// Removes the mapping for `hostname`. Succeeds if already absent.
    func deactivate(hostname: String) async throws

    /// The address this strategy currently answers for `hostname`, if any.
    func currentAddress(for hostname: String) -> IPv4?
}

extension HostnameStrategy {
    public func update(hostname: String, ip: String) async throws {
        try await activate(hostname: hostname, ip: ip)
    }
}

enum HostnameValidation {
    static func validate(hostname: String, ip: String) throws -> IPv4 {
        guard let address = IPv4(ip) else { throw HostnameError.invalidIPAddress(ip) }
        let name = DNSRecordStore.canonical(hostname)
        guard name.hasSuffix(".\(ProjectNaming.hostnameSuffix)"),
              name.count > ProjectNaming.hostnameSuffix.count + 1
        else { throw HostnameError.invalidHostname(hostname) }
        return address
    }
}

/// Default strategy: in-process DNS responder on `127.0.0.1:<port>` plus the
/// one-time `/etc/resolver/drupal` registration.
public final class LocalResolverStrategy: HostnameStrategy {
    public var kind: HostnameStrategyKind { .localResolver }

    public let store: DNSRecordStore
    public let server: LocalDNSServer
    public let registrar: ResolverFileRegistrar

    public init(
        port: UInt16 = LocalDNSServer.defaultPort,
        registrar: ResolverFileRegistrar,
        store: DNSRecordStore = DNSRecordStore()
    ) {
        self.store = store
        self.server = LocalDNSServer(handler: DNSQueryHandler(store: store), port: port)
        self.registrar = registrar
    }

    public func activate(hostname: String, ip: String) async throws {
        let address = try HostnameValidation.validate(hostname: hostname, ip: ip)
        store.set(address, for: hostname)
        let boundPort = try server.start()
        try registrar.register(port: boundPort)
    }

    public func deactivate(hostname: String) async throws {
        store.remove(hostname)
    }

    public func currentAddress(for hostname: String) -> IPv4? {
        store.address(for: hostname)
    }

    /// Stops the responder. The resolver file is left in place (it is the
    /// one-time registration); use `registrar.unregister()` to remove it.
    public func shutdown() {
        server.stop()
    }
}

/// Fallback strategy: owns a marked `<ip> <name>.drupal` line in `/etc/hosts`.
public struct HostsFileStrategy: HostnameStrategy {
    public static let defaultPath = "/etc/hosts"

    public var kind: HostnameStrategyKind { .hostsFile }
    public let path: String
    public let writer: any PrivilegedFileWriter

    public init(path: String = HostsFileStrategy.defaultPath, writer: any PrivilegedFileWriter) {
        self.path = path
        self.writer = writer
    }

    public func activate(hostname: String, ip: String) async throws {
        let address = try HostnameValidation.validate(hostname: hostname, ip: ip)
        let current = writer.readFile(atPath: path) ?? ""
        let updated = HostsFileEditor.inserting(hostname: hostname, ip: address, into: current)
        guard updated != current else { return }  // skip the privileged write when nothing changed
        try writer.writeFile(updated, atPath: path)
    }

    public func deactivate(hostname: String) async throws {
        guard let current = writer.readFile(atPath: path) else { return }
        let updated = HostsFileEditor.removing(hostname: hostname, from: current)
        guard updated != current else { return }
        try writer.writeFile(updated, atPath: path)
    }

    public func currentAddress(for hostname: String) -> IPv4? {
        guard let content = writer.readFile(atPath: path) else { return nil }
        return HostsFileEditor.address(for: hostname, in: content)
    }
}
