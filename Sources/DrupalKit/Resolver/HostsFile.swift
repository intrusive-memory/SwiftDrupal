import Darwin
import Foundation

// drupal's own hosts file, in hosts(5) format, under Application Support —
// never /etc/hosts. `start` records `<name>.drupal → web container IP` here,
// `stop`/`delete` remove it, and the DNS responder answers from it. Writes
// are read-modify-write under an flock and land via atomic rename, so the
// responder can read without locking.

public struct HostsFile: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    static let header = """
        # Managed by drupal: <project>.drupal → web container IP, written by
        # `drupal start`, served by `drupal resolver serve`. Not /etc/hosts.

        """

    /// hostname (lowercased) → IP address.
    public func entries() throws(DrupalError) -> [String: String] {
        guard FileManager.default.fileExists(atPath: url.filePath) else { return [:] }
        do {
            return Self.parse(try String(contentsOf: url, encoding: .utf8))
        } catch {
            throw DrupalError(.ioError, "could not read \(url.filePath): \(error.localizedDescription)")
        }
    }

    /// Points `hostname` at `ip`. Returns false if it already did.
    @discardableResult
    public func set(_ hostname: String, to ip: String) throws(DrupalError) -> Bool {
        guard IPAddress.family(of: ip) != nil else {
            throw DrupalError(.internalError, "not an IP address: \(ip)")
        }
        return try update { entries in
            guard entries[hostname.lowercased()] != ip else { return false }
            entries[hostname.lowercased()] = ip
            return true
        }
    }

    /// Returns false if there was no entry.
    @discardableResult
    public func remove(_ hostname: String) throws(DrupalError) -> Bool {
        try update { entries in entries.removeValue(forKey: hostname.lowercased()) != nil }
    }

    static func parse(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let content = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let fields = content.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 2, IPAddress.family(of: fields[0]) != nil else { continue }
            for host in fields.dropFirst() { out[host.lowercased()] = fields[0] }
        }
        return out
    }

    static func render(_ entries: [String: String]) -> String {
        header + entries.sorted { $0.key < $1.key }.map { "\($0.value)\t\($0.key)\n" }.joined()
    }

    private func update(_ body: (inout [String: String]) -> Bool) throws(DrupalError) -> Bool {
        let dir = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw DrupalError(.ioError, "could not create \(dir.filePath): \(error.localizedDescription)")
        }
        let lockPath = url.filePath + ".lock"
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { throw DrupalError(.ioError, "could not open \(lockPath): \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN) }

        var entries = try entries()
        guard body(&entries) else { return false }
        do {
            try Data(Self.render(entries).utf8).write(to: url, options: .atomic)
        } catch {
            throw DrupalError(.ioError, "could not write \(url.filePath): \(error.localizedDescription)")
        }
        return true
    }
}

enum IPAddress {
    /// AF_INET, AF_INET6, or nil if `string` is neither.
    static func family(of string: String) -> Int32? {
        var v4 = in_addr(), v6 = in6_addr()
        if inet_pton(AF_INET, string, &v4) == 1 { return AF_INET }
        if inet_pton(AF_INET6, string, &v6) == 1 { return AF_INET6 }
        return nil
    }

    /// Network-order bytes of an IPv4 or IPv6 address.
    static func bytes(of string: String) -> [UInt8]? {
        var v4 = in_addr(), v6 = in6_addr()
        if inet_pton(AF_INET, string, &v4) == 1 { return withUnsafeBytes(of: &v4) { Array($0) } }
        if inet_pton(AF_INET6, string, &v6) == 1 { return withUnsafeBytes(of: &v6) { Array($0) } }
        return nil
    }
}
