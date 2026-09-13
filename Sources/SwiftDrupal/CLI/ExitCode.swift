import ArgumentParser

/// Distinct, documented process exit codes for the `drupal` CLI.
///
/// Values avoid ArgumentParser's reserved codes (`0` success, `1` generic
/// failure, `64` usage error) so an agent can branch on the failure class
/// without string-matching stderr.
///
/// Note: ArgumentParser also defines a type named `ExitCode`. Inside this
/// module the local enum wins; in files importing both modules, qualify as
/// `SwiftDrupal.ExitCode` / `ArgumentParser.ExitCode`.
public enum ExitCode: Int32, CaseIterable, Sendable, Codable {
    case success = 0
    case failure = 1
    /// The project config file is missing, unreadable, or does not match the schema.
    case invalidConfig = 10
    /// `Containerization` or the host platform cannot run containers.
    case platformUnavailable = 11
    /// A web or database container failed to start.
    case containerFailedToStart = 12
    /// A container started but did not become healthy in time.
    case healthCheckTimeout = 13

    /// The equivalent ArgumentParser exit code.
    public var argumentParserExitCode: ArgumentParser.ExitCode {
        ArgumentParser.ExitCode(rawValue)
    }
}

/// Errors thrown by `drupal` commands, each tied to a documented `ExitCode`.
public enum DrupalError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidConfig(String)
    case platformUnavailable(String)
    case containerFailedToStart(String)
    case healthCheckTimeout(String)

    public var exitCode: ExitCode {
        switch self {
        case .invalidConfig: .invalidConfig
        case .platformUnavailable: .platformUnavailable
        case .containerFailedToStart: .containerFailedToStart
        case .healthCheckTimeout: .healthCheckTimeout
        }
    }

    public var description: String {
        switch self {
        case .invalidConfig(let message): "Invalid config: \(message)"
        case .platformUnavailable(let message): "Platform unavailable: \(message)"
        case .containerFailedToStart(let message): "Container failed to start: \(message)"
        case .healthCheckTimeout(let message): "Timed out waiting for health: \(message)"
        }
    }
}
