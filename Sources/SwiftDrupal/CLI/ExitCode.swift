import ArgumentParser
import Foundation

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
    /// The long-lived `drupal service` host process is not reachable over its
    /// socket. Remedy: `drupal service install`. Commands never fall back to
    /// running containers or DNS in-process.
    case serviceUnavailable = 14

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
    case serviceUnavailable(String)

    public var exitCode: ExitCode {
        switch self {
        case .invalidConfig: .invalidConfig
        case .platformUnavailable: .platformUnavailable
        case .containerFailedToStart: .containerFailedToStart
        case .healthCheckTimeout: .healthCheckTimeout
        case .serviceUnavailable: .serviceUnavailable
        }
    }

    public var description: String {
        switch self {
        case .invalidConfig(let message): "Invalid config: \(message)"
        case .platformUnavailable(let message): "Platform unavailable: \(message)"
        case .containerFailedToStart(let message): "Container failed to start: \(message)"
        case .healthCheckTimeout(let message): "Timed out waiting for health: \(message)"
        case .serviceUnavailable(let message): "Service unavailable: \(message)"
        }
    }

    /// Stable machine-readable name of the failure class (the `ExitCode` case name).
    public var code: String {
        switch self {
        case .invalidConfig: "invalidConfig"
        case .platformUnavailable: "platformUnavailable"
        case .containerFailedToStart: "containerFailedToStart"
        case .healthCheckTimeout: "healthCheckTimeout"
        case .serviceUnavailable: "serviceUnavailable"
        }
    }

    /// The failure detail without the class prefix.
    public var message: String {
        switch self {
        case .invalidConfig(let m), .platformUnavailable(let m), .containerFailedToStart(let m),
            .healthCheckTimeout(let m), .serviceUnavailable(let m):
            m
        }
    }

    /// A command the user or agent can run to fix the failure, when one exists.
    public var remedy: String? {
        switch self {
        case .serviceUnavailable: "drupal service install"
        default: nil
        }
    }

    /// Machine-readable error document emitted on stderr in JSON mode.
    public var report: ErrorReport {
        ErrorReport(error: .init(code: code, exitCode: exitCode.rawValue, message: message, remedy: remedy))
    }
}

/// JSON error envelope: `{"error":{"code":…,"exitCode":…,"message":…,"remedy":…}}`.
public struct ErrorReport: Codable, Equatable, Sendable {
    public struct Body: Codable, Equatable, Sendable {
        public var code: String
        public var exitCode: Int32
        public var message: String
        public var remedy: String?
    }

    public var error: Body

    public func jsonString() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(self)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
