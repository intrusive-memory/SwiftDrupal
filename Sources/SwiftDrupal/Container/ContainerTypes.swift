import Foundation

// Value types describing containers independently of `Containerization`.
// Everything outside `LiveContainerService.swift` (spec builders, lifecycle,
// tests) works only with these types.

/// Which of the two v1.0 project containers a spec or status describes.
public enum ContainerRole: String, Codable, Sendable, CaseIterable {
    case web
    case db
}

/// A host-to-guest filesystem mount.
public struct MountSpec: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// A virtiofs share of a host directory (`Containerization.Mount.share`).
        case virtiofs
    }

    public var kind: Kind
    /// Absolute host path.
    public var hostPath: String
    /// Absolute path inside the container.
    public var containerPath: String
    public var readOnly: Bool
    /// Host directory must survive container deletion and is created on demand
    /// before the container is created (e.g. the database data directory).
    public var persistent: Bool

    public init(
        kind: Kind = .virtiofs,
        hostPath: String,
        containerPath: String,
        readOnly: Bool = false,
        persistent: Bool = false
    ) {
        self.kind = kind
        self.hostPath = hostPath
        self.containerPath = containerPath
        self.readOnly = readOnly
        self.persistent = persistent
    }
}

/// Everything needed to create one container.
public struct ContainerSpec: Codable, Equatable, Sendable {
    /// Container identifier (at most 64 characters).
    public var id: String
    public var role: ContainerRole
    /// Fully qualified OCI image reference, e.g. `docker.io/ddev/ddev-webserver:v1.24.8`.
    public var imageReference: String
    /// Guest hostname.
    public var hostname: String
    /// `KEY=value` entries, applied on top of the image's own environment.
    /// Later entries win over earlier ones with the same key.
    public var environment: [String]
    public var mounts: [MountSpec]
    /// Overrides the image's ENTRYPOINT + CMD when non-nil.
    public var command: [String]?
    public var workingDirectory: String?
    public var cpus: Int
    public var memoryInBytes: UInt64

    public init(
        id: String,
        role: ContainerRole,
        imageReference: String,
        hostname: String,
        environment: [String] = [],
        mounts: [MountSpec] = [],
        command: [String]? = nil,
        workingDirectory: String? = nil,
        cpus: Int = 2,
        memoryInBytes: UInt64 = 2 * 1024 * 1024 * 1024
    ) {
        self.id = id
        self.role = role
        self.imageReference = imageReference
        self.hostname = hostname
        self.environment = environment
        self.mounts = mounts
        self.command = command
        self.workingDirectory = workingDirectory
        self.cpus = cpus
        self.memoryInBytes = memoryInBytes
    }

    /// Value of `key` in `environment` (last entry wins), or nil.
    public func environmentValue(_ key: String) -> String? {
        EnvironmentList.value(of: key, in: environment)
    }
}

/// Lifecycle state as seen by `ContainerService.inspect`.
public enum ContainerState: String, Codable, Sendable {
    /// No container with that id is known to the service.
    case notFound
    case created
    case running
    case stopped
    /// The runtime reported an error; see `ContainerStatus.message`.
    case errored
}

public struct ContainerStatus: Codable, Equatable, Sendable {
    public var id: String
    public var state: ContainerState
    /// The container's dedicated IPv4 address (no prefix length), when networked.
    public var ipAddress: String?
    public var imageReference: String?
    public var message: String?

    public init(
        id: String,
        state: ContainerState,
        ipAddress: String? = nil,
        imageReference: String? = nil,
        message: String? = nil
    ) {
        self.id = id
        self.state = state
        self.ipAddress = ipAddress
        self.imageReference = imageReference
        self.message = message
    }

    public static func notFound(_ id: String) -> ContainerStatus {
        ContainerStatus(id: id, state: .notFound)
    }
}

/// Which output stream a chunk of process output came from.
public enum StdioStream: String, Codable, Sendable {
    case stdout
    case stderr
}

/// A command to run inside a running container.
public struct ExecRequest: Sendable {
    public var arguments: [String]
    /// Extra `KEY=value` entries layered over the container's environment.
    public var environment: [String]
    public var workingDirectory: String?
    /// Allocate a pseudo-terminal (interactive shells).
    public var terminal: Bool
    /// Bytes fed to the process's stdin; stdin is closed when the stream ends.
    public var stdin: AsyncStream<Data>?
    /// Receives stdout/stderr chunks as they arrive. When nil, output is discarded.
    public var output: (@Sendable (StdioStream, Data) -> Void)?

    public init(
        arguments: [String],
        environment: [String] = [],
        workingDirectory: String? = nil,
        terminal: Bool = false,
        stdin: AsyncStream<Data>? = nil,
        output: (@Sendable (StdioStream, Data) -> Void)? = nil
    ) {
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.terminal = terminal
        self.stdin = stdin
        self.output = output
    }
}

public struct ExecResult: Codable, Equatable, Sendable {
    public var exitCode: Int32

    public init(exitCode: Int32) {
        self.exitCode = exitCode
    }

    public var succeeded: Bool { exitCode == 0 }
}

/// One line of a container's main-process output.
public struct LogLine: Codable, Equatable, Sendable {
    public var timestamp: Date
    public var stream: StdioStream
    public var message: String

    public init(timestamp: Date, stream: StdioStream, message: String) {
        self.timestamp = timestamp
        self.stream = stream
        self.message = message
    }
}

/// Helpers for `KEY=value` environment lists.
public enum EnvironmentList {
    /// The key of a `KEY=value` entry (the whole entry when it has no `=`).
    public static func key(of entry: String) -> String {
        entry.firstIndex(of: "=").map { String(entry[..<$0]) } ?? entry
    }

    /// Last value for `key`, or nil.
    public static func value(of key: String, in list: [String]) -> String? {
        for entry in list.reversed() where Self.key(of: entry) == key {
            guard let eq = entry.firstIndex(of: "=") else { return "" }
            return String(entry[entry.index(after: eq)...])
        }
        return nil
    }

    /// Merges `overrides` into `base`: an override replaces the base entry with the
    /// same key in place; new keys are appended in order. Duplicate keys within
    /// `overrides` collapse to the last one.
    public static func merge(_ base: [String], _ overrides: [String]) -> [String] {
        var result = base
        for entry in overrides {
            let k = key(of: entry)
            if let index = result.firstIndex(where: { key(of: $0) == k }) {
                result[index] = entry
                var i = index + 1
                while i < result.count {
                    if key(of: result[i]) == k { result.remove(at: i) } else { i += 1 }
                }
            } else {
                result.append(entry)
            }
        }
        return result
    }

    /// Throws `DrupalError.invalidConfig` unless every entry is `KEY=value` with a
    /// POSIX-style key (`[A-Za-z_][A-Za-z0-9_]*`).
    public static func validate(_ list: [String], field: String) throws {
        for entry in list {
            guard let eq = entry.firstIndex(of: "=") else {
                throw DrupalError.invalidConfig("\(field) entry \"\(entry)\" must be KEY=value")
            }
            let k = entry[..<eq]
            guard let first = k.unicodeScalars.first,
                  first == "_" || (first.isASCII && CharacterSet.letters.contains(first)),
                  k.unicodeScalars.allSatisfy({ $0 == "_" || ($0.isASCII && CharacterSet.alphanumerics.contains($0)) })
            else {
                throw DrupalError.invalidConfig("\(field) entry \"\(entry)\" has an invalid variable name")
            }
        }
    }
}
