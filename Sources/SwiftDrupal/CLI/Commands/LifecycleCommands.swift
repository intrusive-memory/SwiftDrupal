import ArgumentParser
import Foundation

// `start`, `stop`, `restart`, `status`/`describe`, and `delete`: short-lived
// clients of the `drupal service run` process (OQ-4). An unreachable service
// fails with `serviceUnavailable` (exit 14); there is no in-process fallback.

/// Options shared by commands that start containers.
public struct StartOptions: ParsableArguments, Sendable {
    @Flag(help: "Return once containers are started, without waiting for their health checks.")
    public var noWait = false

    @Option(help: "Seconds to wait for each container to become healthy.")
    public var timeout: Int = Int(HealthChecker.defaultTimeout.components.seconds)

    public init() {}

    public func validate() throws {
        guard timeout > 0 else { throw ValidationError("--timeout must be greater than 0") }
    }

    func applying(to environment: LifecycleEnvironment) -> LifecycleEnvironment {
        var environment = environment
        environment.healthChecker.timeout = .seconds(timeout)
        return environment
    }
}

extension LifecycleReport {
    var textSummary: String {
        var lines: [String] = warnings
        let verb: String =
            switch command {
            case "start": changed ? "Started" : "Already running:"
            case "stop": changed ? "Stopped" : "Already stopped:"
            case "delete": changed ? "Deleted" : "Nothing to delete for"
            default: command
            }
        lines.append("\(verb) \(project) (\(state.rawValue))")
        for container in containers {
            var line = "  \(container.role.rawValue): \(container.id) \(container.state.rawValue)"
            if let ip = container.ipAddress { line += " \(ip)" }
            lines.append(line)
        }
        if let removedDataDirectories, !removedDataDirectories.isEmpty {
            lines.append("Removed data: \(removedDataDirectories.joined(separator: ", "))")
        }
        if let postStart {
            for result in postStart.commands {
                lines.append("post_start: \(result.command) -> exit \(result.exitCode)")
                if !result.succeeded, !result.output.isEmpty { lines.append(result.output) }
            }
            for skipped in postStart.skipped { lines.append("post_start: \(skipped) -> skipped") }
        }
        if command == "start" { lines.append("URL: \(url)") }
        return lines.joined(separator: "\n")
    }
}

public struct StartCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "Create (if needed) and start the project's containers in the drupal service, and wait for health.",
        discussion: """
            Idempotent: starting a running project succeeds. Containers keep running after this command exits. \
            After the containers are up, each post_start command from the config runs in order inside the web \
            container (/bin/sh -c, in /var/www/html), on every start; the first non-zero exit stops the rest, \
            is reported under postStart in the output, and makes start exit 12.
            """
    )

    @OptionGroup public var output: OutputOptions
    @OptionGroup public var project: LifecycleProjectOptions
    @OptionGroup public var start: StartOptions

    public init() {}

    public func run() async throws {
        let environment = start.applying(to: LifecycleEnvironment.current)
        let report = try await execute(environment: environment)
        try LifecycleOutput.emit(report, options: output, environment: environment) { report.textSummary }
        if let error = report.postStartError { throw error }
    }

    public func execute(environment: LifecycleEnvironment) async throws -> LifecycleReport {
        let loaded = try LifecycleProject.load(options: self.project, environment: environment)
        return try await ProjectLifecycle(project: loaded, client: environment.makeClient(), environment: environment)
            .start(waitForHealth: !start.noWait)
    }
}

public struct StopCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Stop the project's containers gracefully. Idempotent: stopping a stopped project succeeds."
    )

    @OptionGroup public var output: OutputOptions
    @OptionGroup public var project: LifecycleProjectOptions

    public init() {}

    public func run() async throws {
        let environment = LifecycleEnvironment.current
        let report = try await execute(environment: environment)
        try LifecycleOutput.emit(report, options: output, environment: environment) { report.textSummary }
    }

    public func execute(environment: LifecycleEnvironment) async throws -> LifecycleReport {
        let loaded = try LifecycleProject.load(options: self.project, environment: environment)
        return try await ProjectLifecycle(project: loaded, client: environment.makeClient(), environment: environment)
            .stop()
    }
}

public struct RestartCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "restart",
        abstract: "Stop, then start, the project's containers."
    )

    @OptionGroup public var output: OutputOptions
    @OptionGroup public var project: LifecycleProjectOptions
    @OptionGroup public var start: StartOptions

    public init() {}

    public func run() async throws {
        let environment = start.applying(to: LifecycleEnvironment.current)
        let report = try await execute(environment: environment)
        try LifecycleOutput.emit(report, options: output, environment: environment) {
            report.stop.textSummary + "\n" + report.start.textSummary
        }
        if let error = report.start.postStartError { throw error }
    }

    public func execute(environment: LifecycleEnvironment) async throws -> RestartReport {
        let loaded = try LifecycleProject.load(options: self.project, environment: environment)
        let lifecycle = ProjectLifecycle(project: loaded, client: environment.makeClient(), environment: environment)
        let stopped = try await lifecycle.stop()
        let started = try await lifecycle.start(waitForHealth: !start.noWait)
        return RestartReport(stop: stopped, start: started, warnings: stopped.warnings + started.warnings)
    }
}

public struct StatusCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Report container states, the resolved hostname, and the effective config.",
        aliases: ["describe"]
    )

    @OptionGroup public var output: OutputOptions
    @OptionGroup public var project: LifecycleProjectOptions

    public init() {}

    public func run() async throws {
        let environment = LifecycleEnvironment.current
        let report = try await execute(environment: environment)
        try LifecycleOutput.emit(report, options: output, environment: environment) {
            var lines = report.warnings
            lines.append("Project: \(report.project) (\(report.state.rawValue))")
            lines.append("URL: \(report.url)")
            for container in report.containers {
                var line = "  \(container.role.rawValue): \(container.id) \(container.state.rawValue)"
                if let ip = container.ipAddress { line += " \(ip)" }
                lines.append(line)
            }
            if let hosts = report.hostsFileAddress { lines.append("/etc/hosts: \(report.hostname) -> \(hosts)") }
            lines.append("Service: pid \(report.service.pid), drupal \(report.service.drupalVersion)")
            lines.append(report.config.textSummary)
            return lines.joined(separator: "\n")
        }
    }

    public func execute(environment: LifecycleEnvironment) async throws -> StatusReport {
        let loaded = try LifecycleProject.load(options: self.project, environment: environment)
        return try await ProjectLifecycle(project: loaded, client: environment.makeClient(), environment: environment)
            .status()
    }
}

public struct DeleteCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Stop and remove the project's containers and database data. Project source files are not touched.",
        discussion: "Idempotent. The database data directory is deleted permanently unless --keep-data is passed."
    )

    @OptionGroup public var output: OutputOptions
    @OptionGroup public var project: LifecycleProjectOptions

    @Flag(help: "Keep the database data directory (only the containers are removed).")
    public var keepData = false

    public init() {}

    public func run() async throws {
        let environment = LifecycleEnvironment.current
        let report = try await execute(environment: environment)
        try LifecycleOutput.emit(report, options: output, environment: environment) { report.textSummary }
    }

    public func execute(environment: LifecycleEnvironment) async throws -> LifecycleReport {
        let loaded = try LifecycleProject.load(options: self.project, environment: environment)
        return try await ProjectLifecycle(project: loaded, client: environment.makeClient(), environment: environment)
            .delete(keepData: keepData)
    }
}
