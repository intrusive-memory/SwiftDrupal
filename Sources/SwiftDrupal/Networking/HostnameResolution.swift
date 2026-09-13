import Darwin
import Foundation

/// Checks that the operating system actually resolves a hostname to an IP.
public protocol HostnameResolverVerifier: Sendable {
    func verify(hostname: String, expectedIP: String) async -> Bool
}

/// Live verifier: asks the system resolver (`getaddrinfo`, i.e. mDNSResponder,
/// which honours `/etc/resolver`) with a few retries to absorb cache lag.
///
/// Guards against the macOS 26 `/etc/resolver` custom-TLD regression.
/// NOT exercised by tests — it depends on real system resolver state.
public struct SystemResolverVerifier: HostnameResolverVerifier {
    public let attempts: Int
    public let delay: Duration

    public init(attempts: Int = 5, delay: Duration = .milliseconds(300)) {
        self.attempts = max(1, attempts)
        self.delay = delay
    }

    public func verify(hostname: String, expectedIP: String) async -> Bool {
        for attempt in 0..<attempts {
            let addresses = await Task.detached { Self.lookupIPv4(hostname) }.value
            if addresses.contains(expectedIP) { return true }
            if attempt < attempts - 1 { try? await Task.sleep(for: delay) }
        }
        return false
    }

    static func lookupIPv4(_ hostname: String) -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_DGRAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(hostname, nil, &hints, &result) == 0 else { return [] }
        defer { freeaddrinfo(result) }
        var addresses: [String] = []
        var cursor = result
        while let info = cursor {
            if info.pointee.ai_family == AF_INET, let raw = info.pointee.ai_addr {
                let sin = raw.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                let octets = withUnsafeBytes(of: sin.s_addr) { Array($0) }
                addresses.append(IPv4(octets: (octets[0], octets[1], octets[2], octets[3])).description)
            }
            cursor = info.pointee.ai_next
        }
        return addresses
    }
}

/// Outcome of activating hostname resolution on `start`.
public struct HostnameActivation: Sendable {
    /// The strategy now serving the hostname.
    public let strategy: any HostnameStrategy
    /// Human-readable warnings to surface in the command's output
    /// (e.g. the resolver fell back to `/etc/hosts`).
    public let warnings: [String]

    /// Whether the fallback strategy replaced the primary.
    public let usedFallback: Bool

    public var kind: HostnameStrategyKind { strategy.kind }
}

/// Activates the primary (local-resolver) strategy, verifies it really
/// answers, and falls back to the hosts-file strategy if it does not.
public struct HostnameResolutionCoordinator: Sendable {
    public let primary: any HostnameStrategy
    public let fallback: any HostnameStrategy
    public let verifier: any HostnameResolverVerifier

    public init(
        primary: any HostnameStrategy,
        fallback: any HostnameStrategy,
        verifier: any HostnameResolverVerifier
    ) {
        self.primary = primary
        self.fallback = fallback
        self.verifier = verifier
    }

    /// Call on every `start` with the web container's freshly assigned IP.
    public func activate(hostname: String, ip: String) async throws -> HostnameActivation {
        // Invalid input is a caller error, not a reason to fall back.
        _ = try HostnameValidation.validate(hostname: hostname, ip: ip)

        let reason: String
        do {
            try await primary.activate(hostname: hostname, ip: ip)
            if await verifier.verify(hostname: hostname, expectedIP: ip) {
                // Keep the fallback from shadowing the resolver with a stale IP.
                try? await fallback.deactivate(hostname: hostname)
                return HostnameActivation(strategy: primary, warnings: [], usedFallback: false)
            }
            reason = "the \(primary.kind.rawValue) strategy was registered but \(hostname) did not resolve to \(ip)"
                + " (known macOS 26 /etc/resolver custom-TLD regression)"
            try? await primary.deactivate(hostname: hostname)
        } catch {
            reason = "the \(primary.kind.rawValue) strategy failed: \(error)"
        }

        try await fallback.activate(hostname: hostname, ip: ip)
        let warning = "Warning: \(reason); fell back to the \(fallback.kind.rawValue) strategy for \(hostname)."
        return HostnameActivation(strategy: fallback, warnings: [warning], usedFallback: true)
    }

    public func deactivate(hostname: String) async {
        try? await primary.deactivate(hostname: hostname)
        try? await fallback.deactivate(hostname: hostname)
    }
}

/// Factory for the default (live) hostname-resolution wiring.
public enum HostnameResolution {
    public struct Configuration: Sendable {
        public var resolverFilePath: String
        public var hostsFilePath: String
        public var responderPort: UInt16
        public var writer: any PrivilegedFileWriter
        public var verifier: any HostnameResolverVerifier

        public init(
            resolverFilePath: String = ResolverFileRegistrar.defaultPath,
            hostsFilePath: String = HostsFileStrategy.defaultPath,
            responderPort: UInt16 = LocalDNSServer.defaultPort,
            writer: any PrivilegedFileWriter = AdministratorFileWriter(),
            verifier: any HostnameResolverVerifier = SystemResolverVerifier()
        ) {
            self.resolverFilePath = resolverFilePath
            self.hostsFilePath = hostsFilePath
            self.responderPort = responderPort
            self.writer = writer
            self.verifier = verifier
        }

        /// Real system paths, privileged writer, and real resolver verification.
        public static var live: Configuration { Configuration() }
    }

    /// Builds a strategy of the given kind.
    public static func makeStrategy(
        _ kind: HostnameStrategyKind,
        configuration: Configuration = .live
    ) -> any HostnameStrategy {
        switch kind {
        case .localResolver:
            LocalResolverStrategy(
                port: configuration.responderPort,
                registrar: ResolverFileRegistrar(
                    path: configuration.resolverFilePath, writer: configuration.writer))
        case .hostsFile:
            HostsFileStrategy(path: configuration.hostsFilePath, writer: configuration.writer)
        }
    }

    /// Default wiring: local-resolver primary, verified, with `/etc/hosts` fallback.
    public static func makeDefaultCoordinator(configuration: Configuration = .live) -> HostnameResolutionCoordinator {
        HostnameResolutionCoordinator(
            primary: makeStrategy(.default, configuration: configuration),
            fallback: makeStrategy(.hostsFile, configuration: configuration),
            verifier: configuration.verifier)
    }
}
