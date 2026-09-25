import Darwin
import Foundation
import Synchronization

// The `.drupal` DNS responder behind `drupal resolver serve`. macOS routes
// only `*.drupal` lookups here (via /etc/resolver/drupal), so it is
// authoritative for that one zone and refuses everything else. Answers come
// from the HostsFile, re-read whenever it changes, so a new container IP is
// live as soon as `start` records it. UDP only, 127.0.0.1 only.

public enum DNS {
    public static let zone = "drupal"
    public static let defaultPort: UInt16 = 15353
    /// Short, because container IPs change on every start.
    static let ttl: UInt32 = 1

    enum RCode: UInt8 {
        case noError = 0, formErr = 1, nxDomain = 3, notImp = 4, refused = 5
    }

    enum QType: UInt16 {
        case a = 1, aaaa = 28
    }

    /// The response to one query packet, or nil if it is too malformed to
    /// answer at all (no header).
    static func answer(_ query: [UInt8], hosts: [String: String]) -> [UInt8]? {
        guard query.count >= 12, query[2] & 0x80 == 0 else { return nil }  // too short, or a response
        let opcode = (query[2] >> 3) & 0x0F
        let qdcount = Int(query[4]) << 8 | Int(query[5])
        func reply(_ rcode: RCode, question: ArraySlice<UInt8> = [], answers: [[UInt8]] = []) -> [UInt8] {
            var out: [UInt8] = [query[0], query[1]]
            out.append(0x80 | (opcode << 3) | 0x04 | (query[2] & 0x01))  // QR, opcode, AA, RD
            out.append(rcode.rawValue)
            out += [0, question.isEmpty ? 0 : 1, 0, UInt8(answers.count), 0, 0, 0, 0]
            out += question
            for a in answers { out += a }
            return out
        }
        guard opcode == 0 else { return reply(.notImp) }
        guard qdcount == 1, let (name, end) = parseName(query, at: 12), end + 4 <= query.count else {
            return reply(.formErr)
        }
        let question = query[12..<(end + 4)]
        let qtype = UInt16(query[end]) << 8 | UInt16(query[end + 1])
        let qclass = UInt16(query[end + 2]) << 8 | UInt16(query[end + 3])

        guard qclass == 1, name == zone || name.hasSuffix("." + zone) else { return reply(.refused, question: question) }
        if name == zone { return reply(.noError, question: question) }
        // Longest registered suffix wins, so `*.site.drupal` resolves too.
        var labels = name.split(separator: ".")
        var ip: String?
        while labels.count >= 2 {
            if let hit = hosts[labels.joined(separator: ".")] { ip = hit; break }
            labels.removeFirst()
        }
        guard let ip, let rdata = IPAddress.bytes(of: ip) else { return reply(.nxDomain, question: question) }
        let wanted: QType? = rdata.count == 4 ? .a : .aaaa
        guard qtype == wanted?.rawValue || qtype == 255 else { return reply(.noError, question: question) }  // NODATA
        var record: [UInt8] = [0xC0, 0x0C]  // pointer to the question name
        record += be16(wanted!.rawValue) + be16(1) + be32(ttl) + be16(UInt16(rdata.count)) + rdata
        return reply(.noError, question: question, answers: [record])
    }

    /// Lowercased dotted name and the offset just past it. No compression
    /// pointers: a question name never needs one.
    static func parseName(_ p: [UInt8], at start: Int) -> (String, Int)? {
        var labels: [String] = []
        var i = start
        while i < p.count {
            let len = Int(p[i])
            if len == 0 { return (labels.joined(separator: ".").lowercased(), i + 1) }
            guard len < 64, i + 1 + len <= p.count else { return nil }
            labels.append(String(decoding: p[(i + 1)...(i + len)], as: UTF8.self))
            i += 1 + len
        }
        return nil
    }

    static func query(_ name: String, type: QType, id: UInt16) -> [UInt8] {
        var out = be16(id) + [0x01, 0x00] + be16(1) + [0, 0, 0, 0, 0, 0]  // RD, one question
        for label in name.split(separator: ".") {
            out.append(UInt8(label.utf8.count))
            out += Array(label.utf8)
        }
        out.append(0)
        return out + be16(type.rawValue) + be16(1)
    }

    static func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }
    static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
}

public final class DNSResponder: Sendable {
    public let hostsFile: HostsFile
    private let socketFD: Int32
    private let stopped = Mutex(false)
    /// The bound port (useful when constructed with port 0).
    public let port: UInt16

    /// Binds 127.0.0.1:`port` immediately so bind failures surface here.
    public init(hostsFile: HostsFile, port: UInt16) throws(DrupalError) {
        self.hostsFile = hostsFile
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw DrupalError(.ioError, "could not create a UDP socket: \(String(cString: strerror(errno)))") }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        // Wake periodically so `stop()` is noticed.
        var timeout = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var addr = Self.loopback(port: port)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else {
            let reason = String(cString: strerror(errno))
            close(fd)
            throw DrupalError(
                .ioError, "could not bind the DNS responder to 127.0.0.1:\(port): \(reason)",
                hint: "Another responder is probably already running; see `drupal resolver status`."
            )
        }
        var actual = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(fd, $0, &len) }
        }
        socketFD = fd
        self.port = UInt16(bigEndian: actual.sin_port)
    }

    deinit { close(socketFD) }

    public func stop() { stopped.withLock { $0 = true } }

    /// Serves until `stop()`; blocks the calling thread.
    public func run() {
        var cache: (modified: Date?, entries: [String: String]) = (nil, [:])
        var buffer = [UInt8](repeating: 0, count: 1500)
        while !stopped.withLock({ $0 }) {
            var from = sockaddr_storage()
            var fromLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(socketFD, &buffer, buffer.count, 0, $0, &fromLen) }
            }
            guard n > 0 else { continue }  // timeout or transient error
            let modified = (try? FileManager.default.attributesOfItem(atPath: hostsFile.url.filePath))?[.modificationDate] as? Date
            if modified != cache.modified {
                cache = (modified, (try? hostsFile.entries()) ?? [:])
            }
            guard let response = DNS.answer(Array(buffer[0..<n]), hosts: cache.entries) else { continue }
            _ = withUnsafePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(socketFD, response, response.count, 0, $0, fromLen) }
            }
        }
    }

    static func loopback(port: UInt16) -> sockaddr_in {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        return addr
    }
}

/// Minimal client for health-checking a responder directly (bypassing the
/// system resolver).
enum DNSProbe {
    struct Response: Equatable {
        var rcode: UInt8
        var addresses: [String]
    }

    static func query(_ name: String, port: UInt16, type: DNS.QType = .a, timeout: TimeInterval = 1) -> Response? {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let id = UInt16.random(in: 1...UInt16.max)
        let packet = DNS.query(name, type: type, id: id)
        var addr = DNSResponder.loopback(port: port)
        let sent = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard sent == packet.count else { return nil }
        var buffer = [UInt8](repeating: 0, count: 1500)
        let n = recv(fd, &buffer, buffer.count, 0)
        guard n >= 12, buffer[0] == UInt8(id >> 8), buffer[1] == UInt8(id & 0xFF) else { return nil }
        return parse(Array(buffer[0..<n]))
    }

    /// Extracts rcode and A/AAAA answers from a response to a single question.
    static func parse(_ p: [UInt8]) -> Response? {
        guard p.count >= 12, let (_, qEnd) = DNS.parseName(p, at: 12) else { return nil }
        let ancount = Int(p[6]) << 8 | Int(p[7])
        var i = qEnd + 4
        var addresses: [String] = []
        for _ in 0..<ancount {
            // Name: we only ever emit a 2-byte pointer.
            guard i + 12 <= p.count, p[i] & 0xC0 == 0xC0 else { return nil }
            let type = UInt16(p[i + 2]) << 8 | UInt16(p[i + 3])
            let rdlen = Int(p[i + 10]) << 8 | Int(p[i + 11])
            let start = i + 12
            guard start + rdlen <= p.count else { return nil }
            let rdata = Array(p[start..<(start + rdlen)])
            var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            let family = type == DNS.QType.a.rawValue ? AF_INET : AF_INET6
            if inet_ntop(family, rdata, &text, socklen_t(text.count)) != nil {
                addresses.append(String(cString: text))
            }
            i = start + rdlen
        }
        return Response(rcode: p[3] & 0x0F, addresses: addresses)
    }
}
