import Foundation

// Host prerequisites checked before any container command: Apple silicon and
// macOS 26+ (Containerization's own floor). Runs before the runtime so a
// wrong host gets `platform_unavailable`, not a confusing runtime error.

public protocol PlatformChecking: Sendable {
    func check() throws(DrupalError)
}

public struct HostPlatform: PlatformChecking {
    public init() {}

    public func check() throws(DrupalError) {
        #if !arch(arm64)
        throw DrupalError(.platformUnavailable, "drupal requires an Apple silicon Mac; Containerization does not support this architecture")
        #else
        let version = ProcessInfo.processInfo.operatingSystemVersion
        if version.majorVersion < 26 {
            throw DrupalError(
                .platformUnavailable,
                "drupal requires macOS 26 or later (running \(version.majorVersion).\(version.minorVersion))"
            )
        }
        #endif
    }
}
