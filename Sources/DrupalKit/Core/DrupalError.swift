// The single error type every command surfaces. Anything else that escapes a
// command is wrapped as `.internalError` at the top level.

public struct DrupalError: Error, Sendable, Equatable {
    /// One specific problem, e.g. a single invalid config field.
    public struct Detail: Sendable, Equatable, Codable {
        /// Dotted location of the problem (`database.type`), when there is one.
        public var path: String?
        /// 1-based line in the config file, when known.
        public var line: Int?
        public var message: String

        public init(path: String? = nil, line: Int? = nil, message: String) {
            self.path = path
            self.line = line
            self.message = message
        }
    }

    public var status: ExitStatus
    public var message: String
    public var details: [Detail]
    /// A concrete next step for the operator, e.g. "run `drupal init`".
    public var hint: String?

    public init(_ status: ExitStatus, _ message: String, details: [Detail] = [], hint: String? = nil) {
        self.status = status
        self.message = message
        self.details = details
        self.hint = hint
    }

    public static func notImplemented(_ operation: String) -> DrupalError {
        DrupalError(
            .notImplemented,
            "'\(operation)' is not implemented yet: the Containerization runtime has not been built.",
            hint: "Config commands (init, config, validate, describe-commands) work today."
        )
    }
}

extension DrupalError: CustomStringConvertible {
    public var description: String { "\(status.identifier): \(message)" }
}
