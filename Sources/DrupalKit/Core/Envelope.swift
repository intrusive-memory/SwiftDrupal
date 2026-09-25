import Foundation

// The JSON envelope every command prints in JSON mode: exactly one line on
// stdout, success or failure. Schema is documented in docs/cli-contract.md;
// bump `schemaVersion` on any breaking change.
//
//   {"command":"validate","data":{...},"error":null,"ok":true,
//    "schema_version":1,"warnings":[]}

public struct Envelope: Encodable, Sendable {
    public static let schemaVersion = 1

    public struct ErrorBody: Encodable, Sendable {
        public var code: String
        public var exitCode: Int32
        public var message: String
        public var details: [DrupalError.Detail]
        public var hint: String?

        enum CodingKeys: String, CodingKey {
            case code, message, details, hint
            case exitCode = "exit_code"
        }

        public init(_ error: DrupalError) {
            code = error.status.identifier
            exitCode = error.status.rawValue
            message = error.message
            details = error.details
            hint = error.hint
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(code, forKey: .code)
            try c.encode(exitCode, forKey: .exitCode)
            try c.encode(message, forKey: .message)
            try c.encode(details, forKey: .details)
            try c.encode(hint, forKey: .hint)  // explicit null when absent
        }
    }

    public var command: String
    public var data: (any Encodable & Sendable)?
    public var warnings: [String]
    public var error: ErrorBody?

    public var ok: Bool { error == nil }

    public static func success(_ command: String, data: (any Encodable & Sendable)?, warnings: [String] = []) -> Envelope {
        Envelope(command: command, data: data, warnings: warnings, error: nil)
    }

    public static func failure(_ command: String, _ error: DrupalError, warnings: [String] = []) -> Envelope {
        Envelope(command: command, data: nil, warnings: warnings, error: ErrorBody(error))
    }

    enum CodingKeys: String, CodingKey {
        case ok, command, data, warnings, error
        case schemaVersion = "schema_version"
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.schemaVersion, forKey: .schemaVersion)
        try c.encode(ok, forKey: .ok)
        try c.encode(command, forKey: .command)
        if let data {
            try data.encode(to: c.superEncoder(forKey: .data))
        } else {
            try c.encodeNil(forKey: .data)
        }
        try c.encode(warnings, forKey: .warnings)
        try c.encode(error, forKey: .error)
    }

    /// Single-line JSON with sorted keys, suitable for line-oriented parsing.
    public func jsonLine() -> String {
        JSONOutput.line(self)
    }
}

public enum JSONOutput {
    static func encoder(pretty: Bool = false) -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = pretty
            ? [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
            : [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    /// Encodes any value as one line of JSON. Encoding our own model types
    /// cannot fail; if it somehow does, emit a valid internal-error envelope.
    public static func line(_ value: some Encodable) -> String {
        do {
            return String(decoding: try encoder().encode(value), as: UTF8.self)
        } catch {
            return #"{"command":"","data":null,"error":{"code":"internal_error","details":[],"exit_code":1,"hint":null,"message":"failed to encode output"},"ok":false,"schema_version":1,"warnings":[]}"#
        }
    }
}
