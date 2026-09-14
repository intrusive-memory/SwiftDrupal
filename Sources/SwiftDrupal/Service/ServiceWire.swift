import Foundation

// Wire protocol between short-lived `drupal` commands and the long-lived
// `drupal service run` process (OQ-4).
//
// Transport: one Unix-domain stream connection per call.
// Framing:   each message is a 4-byte big-endian unsigned length followed by
//            that many bytes of UTF-8 JSON (`ServiceFraming`).
// Exchange:
//   - Unary calls:  client sends one `ServiceRequest`, server replies with one
//                   `ServiceResponse` and closes.
//   - `logs`:       server replies `.streamOpened` (or `.failure`), then zero or
//                   more `.logLine`, then `.streamEnded` or `.failure`. The client
//                   closing the connection cancels the stream.
//   - `exec`:       client may follow the request with `ServiceStreamInput`
//                   frames (`.stdin` …, `.stdinClosed`); server sends `.output`
//                   frames in order, then exactly one `.exited` or `.failure`.

/// Protocol revision; bumped on incompatible wire changes.
public enum ServiceProtocol {
    public static let version = 1
}

/// The wire form of `ExecRequest` (closures and streams are replaced by
/// `.output` / `.stdin` frames on the same connection).
public struct ExecRequestPayload: Codable, Equatable, Sendable {
    public var arguments: [String]
    public var environment: [String]
    public var workingDirectory: String?
    public var terminal: Bool
    /// When true the client sends `ServiceStreamInput` frames for stdin.
    public var hasStdin: Bool

    public init(
        arguments: [String], environment: [String] = [], workingDirectory: String? = nil,
        terminal: Bool = false, hasStdin: Bool = false
    ) {
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.terminal = terminal
        self.hasStdin = hasStdin
    }

    public init(_ request: ExecRequest) {
        self.init(
            arguments: request.arguments, environment: request.environment,
            workingDirectory: request.workingDirectory, terminal: request.terminal,
            hasStdin: request.stdin != nil)
    }
}

/// Client → server: the first frame on every connection.
public enum ServiceRequest: Codable, Equatable, Sendable {
    /// Liveness/identity check used by `service status`.
    case ping
    case pullImage(reference: String)
    case create(spec: ContainerSpec)
    case start(id: String)
    case stop(id: String)
    case delete(id: String)
    case inspect(id: String)
    case exec(id: String, request: ExecRequestPayload)
    case logs(id: String, follow: Bool)
    /// Points `hostname` at `ip` in the service-owned responder.
    case activateHostname(hostname: String, ip: String)
    case deactivateHostname(hostname: String)

    /// Whether the call uses the streaming exchange rather than one response frame.
    public var isStreaming: Bool {
        switch self {
        case .exec, .logs: true
        default: false
        }
    }
}

/// Client → server frames that follow an `.exec` request.
public enum ServiceStreamInput: Codable, Equatable, Sendable {
    case stdin(data: Data)
    case stdinClosed
}

/// Identity of a running service.
public struct ServiceInfo: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var drupalVersion: String
    public var pid: Int32

    public init(protocolVersion: Int = ServiceProtocol.version, drupalVersion: String = Drupal.version, pid: Int32) {
        self.protocolVersion = protocolVersion
        self.drupalVersion = drupalVersion
        self.pid = pid
    }
}

/// Result of pointing a hostname at a container IP inside the service.
///
/// A user-level LaunchAgent cannot write `/etc/hosts` unattended, so when the
/// resolver strategy fails verification the service sets
/// `hostsFileWriteRequired` and the CLI process performs that privileged write.
public struct HostnameActivationReport: Codable, Equatable, Sendable {
    public var hostname: String
    public var ip: String
    /// The strategy that serves (or must serve) the hostname.
    public var strategy: HostnameStrategyKind
    /// The CLI must write the `/etc/hosts` fallback line itself.
    public var hostsFileWriteRequired: Bool
    public var warnings: [String]

    public init(
        hostname: String, ip: String, strategy: HostnameStrategyKind,
        hostsFileWriteRequired: Bool, warnings: [String] = []
    ) {
        self.hostname = hostname
        self.ip = ip
        self.strategy = strategy
        self.hostsFileWriteRequired = hostsFileWriteRequired
        self.warnings = warnings
    }
}

/// A transported error. Decodes back into the original `DrupalError` or
/// `HostnameError` where possible.
public struct ServiceFailure: Codable, Equatable, Sendable, Error, CustomStringConvertible {
    public enum Kind: String, Codable, Sendable {
        case invalidConfig, platformUnavailable, containerFailedToStart, healthCheckTimeout, serviceUnavailable
        case invalidIPAddress, invalidHostname, responderFailed, privilegedWriteFailed
        /// Malformed or unexpected frames.
        case protocolError
        /// Any other error raised inside the service.
        case other
    }

    public var kind: Kind
    public var message: String

    public init(kind: Kind, message: String) {
        self.kind = kind
        self.message = message
    }

    public init(_ error: any Error) {
        switch error {
        case let failure as ServiceFailure:
            self = failure
        case let drupal as DrupalError:
            let kind: Kind =
                switch drupal {
                case .invalidConfig: .invalidConfig
                case .platformUnavailable: .platformUnavailable
                case .containerFailedToStart: .containerFailedToStart
                case .healthCheckTimeout: .healthCheckTimeout
                case .serviceUnavailable: .serviceUnavailable
                }
            self.init(kind: kind, message: drupal.message)
        case let hostname as HostnameError:
            switch hostname {
            case .invalidIPAddress(let m): self.init(kind: .invalidIPAddress, message: m)
            case .invalidHostname(let m): self.init(kind: .invalidHostname, message: m)
            case .responderFailed(let m): self.init(kind: .responderFailed, message: m)
            case .privilegedWriteFailed(let m): self.init(kind: .privilegedWriteFailed, message: m)
            }
        default:
            self.init(kind: .other, message: String(describing: error))
        }
    }

    /// The error a client call rethrows.
    public var error: any Error {
        switch kind {
        case .invalidConfig: DrupalError.invalidConfig(message)
        case .platformUnavailable: DrupalError.platformUnavailable(message)
        case .containerFailedToStart: DrupalError.containerFailedToStart(message)
        case .healthCheckTimeout: DrupalError.healthCheckTimeout(message)
        case .serviceUnavailable: DrupalError.serviceUnavailable(message)
        case .invalidIPAddress: HostnameError.invalidIPAddress(message)
        case .invalidHostname: HostnameError.invalidHostname(message)
        case .responderFailed: HostnameError.responderFailed(message)
        case .privilegedWriteFailed: HostnameError.privilegedWriteFailed(message)
        case .protocolError, .other: self
        }
    }

    public var description: String { "Service error (\(kind.rawValue)): \(message)" }
}

/// Server → client frames.
public enum ServiceResponse: Codable, Equatable, Sendable {
    case pong(info: ServiceInfo)
    /// Success of a call with no result value.
    case ok
    /// Success of `start`; carries the hostname activation the service performed
    /// when the started container is a web container.
    case started(hostnameActivation: HostnameActivationReport?)
    case status(ContainerStatus)
    case hostnameActivation(HostnameActivationReport)
    case failure(ServiceFailure)
    // Streaming
    case streamOpened
    case logLine(LogLine)
    case output(stream: StdioStream, data: Data)
    case exited(ExecResult)
    case streamEnded
}

public enum ServiceFraming {
    /// Upper bound on a single frame's JSON payload.
    public static let maximumPayloadLength = 16 * 1024 * 1024
    public static let headerLength = 4

    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    /// Length-prefixes `payload`.
    public static func frame(_ payload: Data) throws -> Data {
        guard payload.count <= maximumPayloadLength else {
            throw ServiceFailure(kind: .protocolError, message: "frame of \(payload.count) bytes exceeds limit")
        }
        let length = UInt32(payload.count)
        var data = Data([UInt8(length >> 24 & 0xFF), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)])
        data.append(payload)
        return data
    }

    /// JSON-encodes and frames `message`.
    public static func encode<Message: Encodable>(_ message: Message) throws -> Data {
        try frame(makeEncoder().encode(message))
    }
}

/// Incremental frame reassembly: feed arbitrary byte chunks, pull whole frames.
public struct ServiceFrameDecoder: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ bytes: Data) {
        buffer.append(bytes)
    }

    /// Bytes buffered but not yet returned as a frame.
    public var bufferedByteCount: Int { buffer.count }

    /// The next complete payload, or nil when more bytes are needed.
    public mutating func nextPayload() throws -> Data? {
        guard buffer.count >= ServiceFraming.headerLength else { return nil }
        let start = buffer.startIndex
        let length = Int(buffer[start]) << 24 | Int(buffer[start + 1]) << 16 | Int(buffer[start + 2]) << 8
            | Int(buffer[start + 3])
        guard length <= ServiceFraming.maximumPayloadLength else {
            throw ServiceFailure(kind: .protocolError, message: "incoming frame of \(length) bytes exceeds limit")
        }
        guard buffer.count >= ServiceFraming.headerLength + length else { return nil }
        let payloadStart = start + ServiceFraming.headerLength
        let payload = Data(buffer[payloadStart..<payloadStart + length])
        buffer = Data(buffer[(payloadStart + length)...])
        return payload
    }

    /// The next complete message decoded as `Message`, or nil when more bytes are needed.
    public mutating func next<Message: Decodable>(_ type: Message.Type) throws -> Message? {
        guard let payload = try nextPayload() else { return nil }
        do {
            return try JSONDecoder().decode(type, from: payload)
        } catch {
            throw ServiceFailure(kind: .protocolError, message: "undecodable \(type) frame: \(error)")
        }
    }
}
