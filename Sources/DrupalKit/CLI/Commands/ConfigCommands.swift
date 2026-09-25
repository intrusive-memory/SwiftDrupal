import ArgumentParser
import Foundation

// init / config / validate: the config-file commands. Fully implemented; none
// of them touch containers.

/// `data` for init and config updates.
struct ConfigWriteResult: Encodable, Sendable {
    enum Action: String, Encodable, Sendable {
        case created, overwritten, updated, unchanged
    }

    var action: Action
    var project: ResolvedProject
}

struct InitCommand: DrupalCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Create .drupal/config.yaml in the project directory.",
        discussion: """
            Writes a config from defaults plus any field flags. Idempotent: re-running \
            with the same flags leaves the file unchanged and succeeds. Refuses to replace \
            a different existing config (exit 5) unless --force.
            """
    )

    @OptionGroup var global: GlobalOptions
    @OptionGroup var fields: ConfigFieldOptions

    @Flag(help: "Overwrite an existing, different config file.")
    var force = false

    func execute(_ context: CommandContext) async throws(DrupalError) -> CommandOutput {
        let root = context.directory
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.filePath, isDirectory: &isDir), isDir.boolValue else {
            throw DrupalError(.usageError, "project directory \(root.filePath) does not exist")
        }

        var config = ProjectConfig()
        _ = fields.apply(to: &config)
        let (project, rendered) = try prepare(config, root: root)

        let file = ProjectLayout.configFile(in: root)
        let action: ConfigWriteResult.Action
        if let existing = try? String(contentsOf: file, encoding: .utf8) {
            if existing == rendered {
                action = .unchanged
            } else if force {
                action = .overwritten
            } else {
                throw DrupalError(
                    .alreadyExists,
                    "\(file.filePath) already exists with different contents",
                    hint: "Pass --force to replace it, or use `drupal config --<field> <value>` to change individual fields."
                )
            }
        } else {
            action = .created
        }
        if action != .unchanged { try write(rendered, to: file) }

        let verb = switch action {
        case .created: "Created"
        case .overwritten: "Overwrote"
        case .updated: "Updated"
        case .unchanged: "Unchanged:"
        }
        return CommandOutput(
            data: ConfigWriteResult(action: action, project: project),
            text: "\(verb) \(file.filePath)\nProject '\(project.name)' will be served at \(project.url)",
            warnings: project.warnings
        )
    }
}

struct ConfigCommand: DrupalCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Show the resolved config, or update fields with flags.",
        discussion: """
            Without field flags: prints the fully resolved config (defaults applied, \
            name/hostname/paths/images derived) and changes nothing. With field flags: \
            rewrites .drupal/config.yaml with those fields changed (comments in the file \
            are not preserved). Use `init` to create the file.
            """
    )

    @OptionGroup var global: GlobalOptions
    @OptionGroup var fields: ConfigFieldOptions

    func execute(_ context: CommandContext) async throws(DrupalError) -> CommandOutput {
        if fields.isEmpty {
            let project = try context.project()
            return CommandOutput(data: project, text: TextFormat.resolved(project), warnings: project.warnings)
        }

        let root = try ProjectLayout.findRoot(from: context.directory)
        let parsed = try ProjectLayout.load(root: root)
        var config = parsed.config
        _ = fields.apply(to: &config)
        let (project, rendered) = try prepare(config, root: root)

        let file = ProjectLayout.configFile(in: root)
        let existing = try? String(contentsOf: file, encoding: .utf8)
        let action: ConfigWriteResult.Action = existing == rendered ? .unchanged : .updated
        if action == .updated { try write(rendered, to: file) }
        return CommandOutput(
            data: ConfigWriteResult(action: action, project: project),
            text: (action == .updated ? "Updated " : "Unchanged: ") + file.filePath,
            warnings: project.warnings
        )
    }
}

struct ValidateCommand: DrupalCommand {
    static let configuration = CommandConfiguration(
        commandName: "validate",
        abstract: "Validate .drupal/config.yaml and print the resolved config.",
        discussion: "Exit 0 when valid; exit 3 with every problem listed in error.details when not."
    )

    @OptionGroup var global: GlobalOptions

    func execute(_ context: CommandContext) async throws(DrupalError) -> CommandOutput {
        let project = try context.project()
        return CommandOutput(
            data: project,
            text: "Config is valid: \(project.configFile.filePath)\n\n" + TextFormat.resolved(project),
            warnings: project.warnings
        )
    }
}

/// Validates a flag-built config, renders it, and resolves the rendered text
/// exactly as a later load would (so `defaults_applied` matches the file).
/// Throws before anything is written.
private func prepare(_ config: ProjectConfig, root: URL) throws(DrupalError) -> (ResolvedProject, String) {
    let issues = ConfigValidator.validate(config)
    if !issues.isEmpty {
        // Detail paths name config keys; the flag is the key in kebab-case.
        throw ConfigParser.invalid("the requested config", issues)
    }
    let rendered = ConfigWriter.render(config)
    let parsed = try ConfigParser.parse(rendered, file: ProjectLayout.configFile(in: root).filePath)
    return (try ResolvedProject.resolve(root: root, parsed: parsed), rendered)
}

private func write(_ text: String, to file: URL) throws(DrupalError) {
    do {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file, options: .atomic)
    } catch {
        throw DrupalError(.ioError, "could not write \(file.filePath): \(error.localizedDescription)")
    }
}
