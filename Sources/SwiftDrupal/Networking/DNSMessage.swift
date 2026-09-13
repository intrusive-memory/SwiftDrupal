import Foundation
import Synchronization

/// A dotted-quad IPv4 address, validated at construction.
public struct IPv4: Hashable, Sendable, CustomStringConvertible {
    public let octets: [UInt8]

    public init?(_ string: String) {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var bytes: [UInt8] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isASCII),
                  part.allSatisfy(\.isNumber), let value = UInt8(part)
            else { return nil }
            bytes.append(value)
        }
        octets = bytes
    }

    public init(octets: (UInt8, UInt8, UInt8, UInt8)) {
        self.octets = [octets.0, octets.1, octets.2, octets.3]
    }

    public var description: String { octets.map(String.init).joined(separator: ".") }
}

/// Errors raised by hostname-resolution components.
public enum HostnameError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidIPAddress(String)
    case invalidHostname(String)
    case responderFailed(String)
    case privilegedWriteFailed(String)

    public var description: String {
        switch self {
        case .invalidIPAddress(let value): "Invalid IPv4 address: \(value)"
        case .invalidHostname(let value): "Hostname is not under .\(ProjectNaming.hostnameSuffix): \(value)"
        case .responderFailed(let message): "Local DNS responder failed: \(message)"
        case .privilegedWriteFailed(let message): "Privileged file write failed: \(message)"
        }
    }
}

/// Thread-safe map of `*.drupal` hostnames to their current IPv4 address.
///
/// This is the responder's "current IP" record: updated on every `start`
/// with the web container's freshly assigned address.
public final class DNSRecordStore: Sendable {
    private let records = Mutex<[String: IPv4]>([:])

    public init() {}

    /// Canonical form used for lookups: lowercased, trailing dot stripped.
    static func canonical(_ name: String) -> String {
        var name = name.lowercased()
        while name.hasSuffix(".") { name.removeLast() }
        return name
    }

    public func set(_ ip: IPv4, for hostname: String) {
        let key = Self.canonical(hostname)
        records.withLock { $0[key] = ip }
    }

    public func remove(_ hostname: String) {
        let key = Self.canonical(hostname)
        _ = records.withLock { $0.removeValue(forKey: key) }
    }

    /// Exact match first; otherwise a subdomain of a registered hostname
    /// (e.g. `www.site.drupal` resolves to `site.drupal`'s address).
    public func address(for hostname: String) -> IPv4? {
        let name = Self.canonical(hostname)
        return records.withLock { records in
            if let exact = records[name] { return exact }
            return records.first { name.hasSuffix(".\($0.key)") }?.value
        }
    }
}

/// Pure DNS wire-format logic: parses a query datagram and builds the response.
///
/// No sockets are involved, so this is fully unit-testable.
public struct DNSQueryHandler: Sendable {
    public enum RCode: UInt8, Sendable {
        case noError = 0
        case formatError = 1
        case nameError = 3  // NXDOMAIN
        case notImplemented = 4
        case refused = 5
    }

    public static let typeA: UInt16 = 1
    public static let typeANY: UInt16 = 255
    public static let classIN: UInt16 = 1

    public let store: DNSRecordStore
    public let zone: String
    public let ttl: UInt32

    /// - Parameters:
    ///   - zone: The only zone answered; everything else is REFUSED.
    ///   - ttl: Kept short so a new container IP on `start` is picked up quickly.
    public init(store: DNSRecordStore, zone: String = ProjectNaming.hostnameSuffix, ttl: UInt32 = 1) {
        self.store = store
        self.zone = DNSRecordStore.canonical(zone)
        self.ttl = ttl
    }

    public struct Question: Equatable, Sendable {
        public var name: String
        public var type: UInt16
        public var qclass: UInt16
    }

    /// Returns the response datagram, or `nil` when the input should be
    /// dropped silently (too short to carry a header, or itself a response).
    public func response(to query: [UInt8]) -> [UInt8]? {
        guard query.count >= 12 else { return nil }
        let id = [query[0], query[1]]
        let flags = UInt16(query[2]) << 8 | UInt16(query[3])
        guard flags & 0x8000 == 0 else { return nil }  // QR set: not a query
        let opcode = UInt8((flags >> 11) & 0x0F)
        let recursionDesired = flags & 0x0100 != 0
        let qdcount = UInt16(query[4]) << 8 | UInt16(query[5])

        guard opcode == 0 else {
            return Self.header(id: id, rd: recursionDesired, rcode: .notImplemented, qd: 0, an: 0)
        }
        guard qdcount == 1, let (question, questionEnd) = Self.parseQuestion(query, offset: 12) else {
            return Self.header(id: id, rd: recursionDesired, rcode: .formatError, qd: 0, an: 0)
        }
        let questionBytes = Array(query[12..<questionEnd])
        let name = DNSRecordStore.canonical(question.name)

        let inZone = name.hasSuffix(".\(zone)") || name == zone
        guard inZone else {
            return Self.header(id: id, rd: recursionDesired, rcode: .refused, qd: 1, an: 0) + questionBytes
        }
        guard name != zone, let ip = store.address(for: name) else {
            return Self.header(id: id, rd: recursionDesired, rcode: .nameError, qd: 1, an: 0) + questionBytes
        }
        let wantsA = (question.type == Self.typeA || question.type == Self.typeANY)
            && question.qclass == Self.classIN
        guard wantsA else {
            // Name exists but has no record of this type (e.g. AAAA): NODATA.
            return Self.header(id: id, rd: recursionDesired, rcode: .noError, qd: 1, an: 0) + questionBytes
        }
        var answer: [UInt8] = [0xC0, 0x0C]  // compression pointer to the question name
        answer += Self.be16(Self.typeA) + Self.be16(Self.classIN)
        answer += [UInt8(ttl >> 24 & 0xFF), UInt8(ttl >> 16 & 0xFF), UInt8(ttl >> 8 & 0xFF), UInt8(ttl & 0xFF)]
        answer += Self.be16(4) + ip.octets
        return Self.header(id: id, rd: recursionDesired, rcode: .noError, qd: 1, an: 1) + questionBytes + answer
    }

    // MARK: - Wire helpers

    static func be16(_ value: UInt16) -> [UInt8] { [UInt8(value >> 8), UInt8(value & 0xFF)] }

    static func header(id: [UInt8], rd: Bool, rcode: RCode, qd: UInt16, an: UInt16) -> [UInt8] {
        // QR=1, opcode=0, AA=1, TC=0, RD copied, RA=0.
        let flagsHigh: UInt8 = 0x80 | 0x04 | (rd ? 0x01 : 0)
        return id + [flagsHigh, rcode.rawValue] + be16(qd) + be16(an) + be16(0) + be16(0)
    }

    /// Parses one uncompressed question. Returns the question and the offset just past it.
    static func parseQuestion(_ bytes: [UInt8], offset start: Int) -> (Question, Int)? {
        var offset = start
        var labels: [String] = []
        var nameLength = 0
        while true {
            guard offset < bytes.count else { return nil }
            let length = Int(bytes[offset])
            offset += 1
            if length == 0 { break }
            guard length <= 63 else { return nil }  // compression pointers are not valid in a query name
            guard offset + length <= bytes.count else { return nil }
            nameLength += length + 1
            guard nameLength <= 255 else { return nil }
            guard let label = String(bytes: bytes[offset..<offset + length], encoding: .utf8) else { return nil }
            labels.append(label)
            offset += length
        }
        guard offset + 4 <= bytes.count, !labels.isEmpty else { return nil }
        let type = UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
        let qclass = UInt16(bytes[offset + 2]) << 8 | UInt16(bytes[offset + 3])
        return (Question(name: labels.joined(separator: "."), type: type, qclass: qclass), offset + 4)
    }

    /// Builds a standard recursive query datagram (used by tests and diagnostics).
    public static func makeQuery(id: UInt16, name: String, type: UInt16 = typeA) -> [UInt8] {
        var bytes = be16(id) + [0x01, 0x00] + be16(1) + be16(0) + be16(0) + be16(0)
        for label in DNSRecordStore.canonical(name).split(separator: ".") {
            let utf8 = Array(label.utf8)
            bytes.append(UInt8(utf8.count))
            bytes += utf8
        }
        bytes.append(0)
        bytes += be16(type) + be16(classIN)
        return bytes
    }
}
