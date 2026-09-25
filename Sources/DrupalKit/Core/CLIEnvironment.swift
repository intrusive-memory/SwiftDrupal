import Foundation
import Synchronization

// Everything a command touches outside its own flags: working directory,
// output streams, TTY state, the container runtime, and the `.drupal`
// resolver's files and services. Commands read it via
// `CLIEnvironment.current` (a task-local) so tests can run the real command
// tree against temp dirs and captured output, in parallel.

public protocol TextOutput: Sendable {
    func write(_ text: String)
}

/// Writes straight to a file descriptor (stdout/stderr).
public struct FileDescriptorOutput: TextOutput {
    let handle: FileHandle
    public static let stdout = FileDescriptorOutput(handle: .standardOutput)
    public static let stderr = FileDescriptorOutput(handle: .standardError)

    public func write(_ text: String) {
        handle.write(Data(text.utf8))
    }
}

/// Accumulates output in memory; used by tests.
public final class CapturedOutput: TextOutput {
    private let buffer = Mutex("")
    public init() {}
    public func write(_ text: String) { buffer.withLock { $0 += text } }
    public var text: String { buffer.withLock { $0 } }
    public var lines: [String] { text.split(separator: "\n").map(String.init) }
}

public struct CLIEnvironment: Sendable {
    public var workingDirectory: URL
    public var stdout: any TextOutput
    public var stderr: any TextOutput
    public var stdoutIsTTY: Bool
    public var stdinIsTTY: Bool
    public var runtime: any ContainerRuntime
    public var platform: any PlatformChecking
    public var resolver: ResolverEnvironment

    public init(
        workingDirectory: URL,
        stdout: any TextOutput,
        stderr: any TextOutput,
        stdoutIsTTY: Bool,
        stdinIsTTY: Bool,
        runtime: any ContainerRuntime,
        platform: any PlatformChecking,
        resolver: ResolverEnvironment
    ) {
        self.workingDirectory = workingDirectory
        self.stdout = stdout
        self.stderr = stderr
        self.stdoutIsTTY = stdoutIsTTY
        self.stdinIsTTY = stdinIsTTY
        self.runtime = runtime
        self.platform = platform
        self.resolver = resolver
    }

    /// The real process environment.
    public static func live() -> CLIEnvironment {
        CLIEnvironment(
            workingDirectory: URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory),
            stdout: FileDescriptorOutput.stdout,
            stderr: FileDescriptorOutput.stderr,
            stdoutIsTTY: isatty(STDOUT_FILENO) == 1,
            stdinIsTTY: isatty(STDIN_FILENO) == 1,
            runtime: UnimplementedRuntime(),
            platform: HostPlatform(),
            resolver: .live()
        )
    }

    @TaskLocal public static var current: CLIEnvironment = .live()
}
