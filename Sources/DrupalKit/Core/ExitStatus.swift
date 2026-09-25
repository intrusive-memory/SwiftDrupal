// Every process exit code `drupal` can produce, in one place. The raw value is
// the exit code; `identifier` is the stable string used as `error.code` in the
// JSON envelope. Numbers and identifiers are part of the public contract
// (docs/cli-contract.md): never renumber, only append.

public enum ExitStatus: Int32, CaseIterable, Sendable, Codable {
    case success = 0
    /// An unexpected failure inside `drupal` itself (a bug).
    case internalError = 1
    /// Bad flags/arguments, or a flag combination that cannot work (e.g.
    /// `ssh` without a TTY).
    case usageError = 2
    /// The project config file failed to parse or validate.
    case configInvalid = 3
    /// No `.drupal/config.yaml` in the directory or any parent.
    case projectNotFound = 4
    /// Refused to overwrite an existing file (`init` without `--force`,
    /// `export-db` onto an existing file).
    case alreadyExists = 5
    /// Wrong macOS version/architecture, or Containerization unusable.
    case platformUnavailable = 6
    /// A container could not be created or started.
    case containerStartFailed = 7
    /// Containers started but did not become healthy within `--timeout`.
    case healthTimeout = 8
    /// The command needs a running project and it is not running.
    case projectNotRunning = 9
    /// Any other runtime operation (stop, exec, logs, delete) failed.
    case containerOperationFailed = 10
    /// Reading or writing a local file failed.
    case ioError = 11
    /// The command exists in the contract but is not implemented yet.
    case notImplemented = 12
    /// A `post_start` command exited non-zero after the containers came up.
    case postStartFailed = 13
    /// A one-time privileged step is needed (the /etc/resolver file); rerun
    /// the command with sudo.
    case permissionRequired = 14
    /// The runtime's kernel could not be fetched or failed its checksum.
    case runtimeAssetsUnavailable = 15

    public var identifier: String {
        switch self {
        case .success: "success"
        case .internalError: "internal_error"
        case .usageError: "usage_error"
        case .configInvalid: "config_invalid"
        case .projectNotFound: "project_not_found"
        case .alreadyExists: "already_exists"
        case .platformUnavailable: "platform_unavailable"
        case .containerStartFailed: "container_start_failed"
        case .healthTimeout: "health_timeout"
        case .projectNotRunning: "project_not_running"
        case .containerOperationFailed: "container_operation_failed"
        case .ioError: "io_error"
        case .notImplemented: "not_implemented"
        case .postStartFailed: "post_start_failed"
        case .permissionRequired: "permission_required"
        case .runtimeAssetsUnavailable: "runtime_assets_unavailable"
        }
    }

    public var summary: String {
        switch self {
        case .success: "Command succeeded."
        case .internalError: "Unexpected internal error (a bug in drupal)."
        case .usageError: "Invalid flags, arguments, or flag combination."
        case .configInvalid: "The project config file is malformed or invalid."
        case .projectNotFound: "No .drupal/config.yaml found in this directory or any parent."
        case .alreadyExists: "Refused to overwrite an existing file; pass --force."
        case .platformUnavailable: "Platform unsupported or Containerization unavailable (needs macOS 26+, Apple silicon)."
        case .containerStartFailed: "A container failed to be created or started."
        case .healthTimeout: "Containers did not become healthy before the timeout."
        case .projectNotRunning: "The project must be running for this command."
        case .containerOperationFailed: "A container operation (stop, exec, logs, delete) failed."
        case .ioError: "Reading or writing a local file failed."
        case .notImplemented: "The command is part of the contract but not implemented yet."
        case .postStartFailed: "A post_start command exited non-zero."
        case .permissionRequired: "A one-time step needs root; rerun the command with sudo."
        case .runtimeAssetsUnavailable: "The Linux kernel could not be downloaded or failed its checksum."
        }
    }
}
