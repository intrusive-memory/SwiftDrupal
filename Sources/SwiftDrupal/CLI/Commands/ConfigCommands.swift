import ArgumentParser
import Foundation

// `init`, `config`, and `validate` only read or write the project config file.
// They never construct a service client, so they work without the service.

/// Result of `init`.
public struct InitReport: Codable, Equatable, Sendable {
    public var command = "init"
    /// The config file did not exist before.
    public var created: Bool
    /// The file on disk was (re)written. False when it already matched.
    public var written: Bool
    public var resolved: ResolvedConfigReport
}

/// Result of `validate`.
public struct ValidateReport: Codable, Equatable, Sendable {
    public var valid: Bool
    public var resolved: ResolvedConfigReport
}

/// `drupal init`: writes `.drupal/config.yaml` with defaults applied.
public struct InitCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Write the project config (.drupal/config.yaml), applying defaults for any field not given.",
        discussion: """
            Run in the project root (or pass --project-root). Re-running is safe: an existing config \
            is kept, with only the fields passed as options changed. An unreadable existing config is \
            replaced only with --force. Does not need the drupal service.
            """
    )

    @OptionGroup public var output: OutputOptions

    @Option(name: .customLong("project-root"), help: "Project root to initialize. Defaults to the current directory.")
    public var projectRoot: String?

    @Option(help: "Project name (defaults to the project directory's name; written only when given).")
    public var name: String?

    @Option(help: "Docroot relative to the project root.")
    public var docroot: String?

    @Option(help: "PHP version (\(DDEVImageCatalog.supportedPHPVersions.joined(separator: ", "))).")
    public var phpVersion: String?

    @Option(help: "Web server type (\(DDEVImageCatalog.supportedWebserverTypes.joined(separator: ", "))).")
    public var webserverType: String?

    @Option(help: "Database type (\(DDEVImageCatalog.supportedDatabaseTypes.joined(separator: ", "))).")
    public var databaseType: String?

    @Option(help: "Database version (\(DDEVImageCatalog.supportedMariaDBVersions.joined(separator: ", "))).")
    public var databaseVersion: String?

    @Option(help: "KEY=value for the web container; repeat for several. Replaces the existing list when given.")
    public var webEnvironment: [String] = []

    @Flag(help: "Replace an existing config file that cannot be read.")
    public var force = false

    public init() {}

    public func run() async throws {
        let environment = LifecycleEnvironment.current
        let report = try execute(environment: environment)
        try LifecycleOutput.emit(report, options: output, environment: environment) {
            let verb = report.written ? (report.created ? "Created" : "Updated") : "Unchanged"
            return "\(verb) \(report.resolved.configPath)\n\(report.resolved.textSummary)"
        }
    }

    public func execute(environment: LifecycleEnvironment) throws -> InitReport {
        let root = LifecycleProject.explicitOrCurrentRoot(projectRoot, currentDirectory: environment.currentDirectory())
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path(percentEncoded: false), isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw DrupalError.invalidConfig("project root \(root.path(percentEncoded: false)) is not a directory")
        }

        let url = ProjectConfig.configFileURL(projectRoot: root)
        let exists = FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
        var existing: ProjectConfig?
        if exists {
            do {
                existing = try ProjectConfig.load(from: url)
            } catch {
                guard force else {
                    throw DrupalError.invalidConfig(
                        "\(url.path(percentEncoded: false)) exists but is invalid (\(error)); fix it or pass --force to replace it")
                }
            }
        }

        let config = applyOptions(to: existing ?? .default)
        // Validate (image catalog, docroot, web_environment) before writing.
        let project = try LifecycleProject(root: root, config: config, stateRoot: environment.stateRoot)

        let written = existing != config
        if written {
            do {
                try config.write(to: url)
            } catch {
                throw DrupalError.invalidConfig("cannot write \(url.path(percentEncoded: false)): \(error.localizedDescription)")
            }
        }
        return InitReport(created: !exists, written: written, resolved: try ResolvedConfigReport(project: project))
    }

    func applyOptions(to base: ProjectConfig) -> ProjectConfig {
        var config = base
        if let name { config.name = name.isEmpty ? nil : name }
        if let docroot { config.docroot = docroot }
        if let phpVersion { config.phpVersion = phpVersion }
        if let webserverType { config.webserverType = webserverType }
        if let databaseType { config.database.type = databaseType }
        if let databaseVersion { config.database.version = databaseVersion }
        if !webEnvironment.isEmpty { config.webEnvironment = webEnvironment }
        return config
    }
}

/// `drupal config`: prints the fully resolved configuration without starting anything.
public struct ConfigCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Print the fully resolved project configuration (defaults applied, container plan) without starting anything."
    )

    @OptionGroup public var output: OutputOptions
    @OptionGroup public var project: LifecycleProjectOptions

    public init() {}

    public func run() async throws {
        let environment = LifecycleEnvironment.current
        let report = try execute(environment: environment)
        try LifecycleOutput.emit(report, options: output, environment: environment) { report.textSummary }
    }

    public func execute(environment: LifecycleEnvironment) throws -> ResolvedConfigReport {
        try ResolvedConfigReport(project: LifecycleProject.load(options: project, environment: environment))
    }
}

/// `drupal validate`: checks the config; exits 10 (invalidConfig) when it is invalid.
public struct ValidateCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "validate",
        abstract: "Validate the project config and print the resolved configuration. Exits 10 when invalid."
    )

    @OptionGroup public var output: OutputOptions
    @OptionGroup public var project: LifecycleProjectOptions

    public init() {}

    public func run() async throws {
        let environment = LifecycleEnvironment.current
        let report = try execute(environment: environment)
        try LifecycleOutput.emit(report, options: output, environment: environment) {
            "Config is valid.\n\(report.resolved.textSummary)"
        }
    }

    public func execute(environment: LifecycleEnvironment) throws -> ValidateReport {
        ValidateReport(
            valid: true, resolved: try ResolvedConfigReport(project: LifecycleProject.load(options: project, environment: environment)))
    }
}
