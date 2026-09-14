import Foundation

// Contract facts published in the command manifest that ArgumentParser
// introspection cannot supply. Optional per command: a command without an
// annotation still appears in the manifest, with `requiresService: null`.

private let serviceNote = "Needs the drupal service; exits 14 (serviceUnavailable) when its socket is unreachable, with no in-process fallback."
private let projectRootWalkNote =
    "Without --project-root, uses the nearest ancestor of the current directory that contains .drupal/config.yaml."
private let currentDirectoryNote =
    "Resolves the project from the current directory only (no ancestor search); a missing or invalid .drupal/config.yaml exits 10."

extension ServiceCommand: ManifestAnnotated {
    public static var manifestRequiresService: Bool { false }
}

extension ServiceRunCommand: ManifestAnnotated {
    public static var manifestRequiresService: Bool { false }
    public static var manifestNotes: [String] {
        ["The long-lived host process launchd runs; not for direct use. Logs to stderr; no --json. SIGTERM stops containers, then the DNS responder, and exits 0."]
    }
}

extension ServiceInstallCommand: ManifestAnnotated {
    public static var manifestRequiresService: Bool { false }
    public static var manifestNotes: [String] {
        [
            "Prompts once for administrator rights to write /etc/resolver/drupal.",
            "Warns when the binary lives under .build/ or DerivedData/, because the LaunchAgent records its absolute path.",
        ]
    }
}

extension ServiceUninstallCommand: ManifestAnnotated {
    public static var manifestRequiresService: Bool { false }
}

extension ServiceStatusCommand: ManifestAnnotated {
    public static var manifestRequiresService: Bool { false }
    public static var manifestNotes: [String] {
        ["Reports socketReachable instead of failing: exits 0 even when the service is down."]
    }
}

extension InitCommand: ManifestAnnotated {
    public static var manifestRequiresService: Bool { false }
    public static var manifestNotes: [String] {
        ["post_start is not settable by flag; edit .drupal/config.yaml."]
    }
}

extension ConfigCommand: ManifestAnnotated {
    public static var manifestRequiresService: Bool { false }
    public static var manifestNotes: [String] { [projectRootWalkNote] }
}

extension ValidateCommand: ManifestAnnotated {
    public static var manifestRequiresService: Bool { false }
    public static var manifestNotes: [String] { [projectRootWalkNote, "Exits 10 when the config is invalid."] }
}

extension StartCommand: ManifestAnnotated {
    public static var manifestRequiresService: Bool { true }
    public static var manifestNotes: [String] {
        [
            serviceNote, projectRootWalkNote, "Idempotent.",
            "Runs the config's post_start commands in the web container after every successful start (/bin/sh -c, working directory /var/www/html), in order, stopping at the first non-zero exit. Results are under postStart in the report; a failure exits 12.",
        ]
    }
}

extension StopCommand: ManifestAnnotated {
    public static var manifestRequiresService: Bool { true }
    public static var manifestNotes: [String] { [serviceNote, projectRootWalkNote, "Idempotent."] }
}

extension RestartCommand: ManifestAnnotated {
    public static var manifestRequiresService: Bool { true }
    public static var manifestNotes: [String] {
        [serviceNote, projectRootWalkNote, "Runs post_start as start does; a post_start failure exits 12."]
    }
}

extension StatusCommand: ManifestAnnotated {
    public static var manifestRequiresService: Bool { true }
    public static var manifestNotes: [String] { [serviceNote, projectRootWalkNote] }
}

extension DeleteCommand: ManifestAnnotated {
    public static var manifestRequiresService: Bool { true }
    public static var manifestNotes: [String] {
        [
            serviceNote, projectRootWalkNote,
            "DESTRUCTIVE BY DEFAULT: permanently deletes the project's database data directory. Pass --keep-data to remove only the containers. Project source files are never touched.",
            "Idempotent.",
        ]
    }
}

extension ImportDBCommand: ManifestAnnotated {
    public static var manifestRequiresService: Bool { true }
    public static var manifestNotes: [String] {
        [
            serviceNote,
            "Without --project-root, uses the current directory (no ancestor search); a missing config is tolerated and the directory name is the project name.",
            "Gzip input (.gz or gzip magic bytes) is decompressed while streaming.",
        ]
    }
}

extension ExportDBCommand: ManifestAnnotated {
    public static var manifestRequiresService: Bool { true }
    public static var manifestNotes: [String] {
        [
            serviceNote,
            "Without a file argument the SQL dump is written to stdout and the result document to stderr.",
            "Without --project-root, uses the current directory (no ancestor search); a missing config is tolerated.",
        ]
    }
}

extension ExecCommand: ManifestAnnotated {
    public static var manifestRequiresService: Bool { true }
    public static var manifestNotes: [String] {
        [
            serviceNote, currentDirectoryNote,
            "TTY is auto-detected; there are no -i/-t flags. A pseudo-terminal is requested and the local terminal set to raw mode exactly when stdin is a TTY. stdin is always forwarded.",
            "Remote stdout/stderr pass through unchanged; exits with the remote exit status. --json affects only drupal's own error output.",
            "SIGINT restores the terminal and exits 130 (128+signal).",
        ]
    }
}

extension SSHCommand: ManifestAnnotated {
    public static var manifestRequiresService: Bool { true }
    public static var manifestNotes: [String] {
        [
            serviceNote, currentDirectoryNote,
            "Always requests a pseudo-terminal; raw mode is enabled only when stdin is a TTY. There are no -i/-t flags.",
            "Runs the container's login shell ($SHELL -l, falling back to /bin/sh). Exits with the shell's exit status. --json affects only drupal's own error output.",
            "SIGINT restores the terminal and exits 130 (128+signal).",
        ]
    }
}

extension LogsCommand: ManifestAnnotated {
    public static var manifestRequiresService: Bool { true }
    public static var manifestNotes: [String] {
        [
            serviceNote, currentDirectoryNote,
            "JSON mode emits one compact object per line: {timestamp, service, stream, message}.",
            "With --follow, SIGINT exits 0.",
        ]
    }
}

extension DescribeCommandsCommand: ManifestAnnotated {
    public static var manifestRequiresService: Bool { false }
    public static var manifestNotes: [String] { ["Always JSON, regardless of TTY."] }
}
