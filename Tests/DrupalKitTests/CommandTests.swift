import Foundation
import Testing
@testable import DrupalKit

@Suite struct InitCommandTests {
    @Test func createsConfigWithDefaults() async throws {
        let dir = try tempProject()
        let r = await drupal("init", in: dir)
        #expect(r.code == 0)
        #expect(r.data["action"] as? String == "created")
        let project = try #require(r.data["project"] as? [String: Any])
        #expect(project["name"] as? String == "my-pantheon-site")
        #expect(project["hostname"] as? String == "my-pantheon-site.drupal")
        let parsed = try ConfigParser.parse(readConfig(in: dir))
        #expect(parsed.config == ProjectConfig())
    }

    @Test func isIdempotent() async throws {
        let dir = try tempProject()
        let args = ["init", "--php-version", "8.3", "--web-environment", "A=1"]
        let first = await drupal(args, in: dir)
        let before = try readConfig(in: dir)
        let second = await drupal(args, in: dir)
        #expect(first.code == 0 && second.code == 0)
        #expect(second.data["action"] as? String == "unchanged")
        #expect(try readConfig(in: dir) == before)
    }

    @Test func refusesToClobberWithoutForce() async throws {
        let dir = try tempProject()
        _ = await drupal("init", in: dir)
        let original = try readConfig(in: dir)

        let refused = await drupal("init", "--php-version", "8.3", in: dir)
        #expect(refused.code == ExitStatus.alreadyExists.rawValue)
        #expect(refused.error["code"] as? String == "already_exists")
        #expect(try readConfig(in: dir) == original)

        let forced = await drupal("init", "--php-version", "8.3", "--force", in: dir)
        #expect(forced.code == 0)
        #expect(forced.data["action"] as? String == "overwritten")
        #expect(try ConfigParser.parse(readConfig(in: dir)).config.phpVersion == "8.3")
    }

    @Test func writesEveryFieldFlag() async throws {
        let dir = try tempProject()
        let r = await drupal(
            "init", "--name", "custom", "--docroot", "docroot", "--php-version", "8.2",
            "--webserver-type", "apache-fpm", "--database-type", "mariadb", "--database-version", "10.11",
            "--web-environment", "A=1", "--web-environment", "B=2",
            "--post-start", "drush cr", "--nodejs-version", "22",
            in: dir
        )
        #expect(r.code == 0)
        let config = try ConfigParser.parse(readConfig(in: dir)).config
        #expect(config == ProjectConfig(
            name: "custom", docroot: "docroot", phpVersion: "8.2", webserverType: .apacheFPM,
            database: DatabaseConfig(type: .mariadb, version: "10.11"),
            webEnvironment: ["A=1", "B=2"], postStart: ["drush cr"], nodejsVersion: "22"
        ))
    }

    @Test func badFlagValuesAreUsageErrors() async throws {
        let dir = try tempProject()
        for args in [["init", "--php-version", "7.4"], ["init", "--database-type", "mysql"], ["init", "--webserver-type", "caddy"]] {
            let r = await drupal(args, in: dir)
            #expect(r.code == ExitStatus.usageError.rawValue, "\(args)")
            #expect(r.error["code"] as? String == "usage_error")
        }
        #expect(!FileManager.default.fileExists(atPath: ProjectLayout.configFile(in: dir).filePath))
    }

    @Test func invalidValuesAreConfigErrorsAndWriteNothing() async throws {
        let dir = try tempProject()
        let r = await drupal("init", "--name", "Bad Name", "--web-environment", "NOPE", in: dir)
        #expect(r.code == ExitStatus.configInvalid.rawValue)
        let paths = (r.error["details"] as? [[String: Any]])?.compactMap { $0["path"] as? String }
        #expect(paths == ["name", "web_environment[0]"])
        #expect(!FileManager.default.fileExists(atPath: ProjectLayout.configFile(in: dir).filePath))
    }

    @Test func honorsProjectDir() async throws {
        let dir = try tempProject()
        let parent = dir.deletingLastPathComponent()
        let r = await drupal("init", "--project-dir", dir.lastPathComponent, in: parent)
        #expect(r.code == 0)
        #expect(FileManager.default.fileExists(atPath: ProjectLayout.configFile(in: dir).filePath))
    }
}

@Suite struct ConfigCommandTests {
    @Test func showsResolvedConfigWithDefaults() async throws {
        let dir = try tempProject(config: "php_version: \"8.3\"\n")
        let r = await drupal("config", "--json", in: dir)
        #expect(r.code == 0)
        #expect(r.envelope["command"] as? String == "config")
        #expect(r.data["name"] as? String == "my-pantheon-site")
        #expect(r.data["url"] as? String == "http://my-pantheon-site.drupal")
        let config = try #require(r.data["config"] as? [String: Any])
        #expect(config["php_version"] as? String == "8.3")
        #expect(config["docroot"] as? String == "web")
        let applied = try #require(r.data["defaults_applied"] as? [String])
        #expect(!applied.contains("php_version"))
        #expect(applied.contains("docroot"))
        #expect(r.envelope["warnings"] as? [String] != [])  // docroot missing
    }

    @Test func updatesOnlyGivenFields() async throws {
        let dir = try tempProject()
        _ = await drupal("init", "--php-version", "8.3", "--docroot", "docroot", in: dir)
        let r = await drupal("config", "--webserver-type", "apache-fpm", in: dir)
        #expect(r.code == 0)
        #expect(r.data["action"] as? String == "updated")
        let config = try ConfigParser.parse(readConfig(in: dir)).config
        #expect(config.webserverType == .apacheFPM)
        #expect(config.phpVersion == "8.3")
        #expect(config.docroot == "docroot")
        let again = await drupal("config", "--webserver-type", "apache-fpm", in: dir)
        #expect(again.data["action"] as? String == "unchanged")
    }

    @Test func updateWithoutConfigIsProjectNotFound() async throws {
        let r = await drupal("config", "--php-version", "8.3", in: try tempProject())
        #expect(r.code == ExitStatus.projectNotFound.rawValue)
    }

    @Test func validateReportsAllProblems() async throws {
        let dir = try tempProject(config: "phpversion: 1\ndatabase:\n  type: postgres\n")
        let r = await drupal("validate", in: dir)
        #expect(r.code == 3)
        #expect(r.envelope["ok"] as? Bool == false)
        #expect((r.error["details"] as? [Any])?.count == 2)
    }
}

@Suite struct OutputModeTests {
    @Test func jsonWhenStdoutIsNotATTY() async throws {
        let dir = try tempProject(config: "")
        let r = await drupal("validate", in: dir, tty: false)
        #expect(r.stdout.split(separator: "\n").count == 1)
        #expect(r.envelope["ok"] as? Bool == true)
        #expect(r.stderr.isEmpty)
    }

    @Test func textOnATTYUnlessJSONForced() async throws {
        let dir = try tempProject(config: "")
        let text = await drupal("validate", in: dir, tty: true)
        #expect(text.stdout.hasPrefix("Config is valid"))
        #expect(text.stderr.contains("warning:"))
        let forced = await drupal("validate", "--json", in: dir, tty: true)
        #expect(forced.envelope["ok"] as? Bool == true)
        let suppressed = await drupal("validate", "--no-json", in: dir, tty: false)
        #expect(suppressed.stdout.hasPrefix("Config is valid"))
    }

    @Test func textErrorsGoToStderr() async throws {
        let r = await drupal("validate", in: try tempProject(), tty: true)
        #expect(r.code == 4)
        #expect(r.stdout.isEmpty)
        #expect(r.stderr.hasPrefix("error: no .drupal/config.yaml"))
        #expect(r.stderr.contains("hint:"))
    }

    @Test func usageErrorsGetAnEnvelopeInJSONMode() async throws {
        let r = await drupal("init", "--bogus", in: try tempProject())
        #expect(r.code == 2)
        #expect(r.envelope["command"] as? String == "init")
        #expect(r.error["code"] as? String == "usage_error")
    }

    @Test func helpAndVersionAreNotErrors() async throws {
        let dir = try tempProject()
        let help = await drupal("--help", in: dir)
        #expect(help.code == 0)
        #expect(help.stdout.contains("USAGE"))
        let version = await drupal("--version", in: dir)
        #expect(version.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == DrupalVersion.current)
    }

    @Test func describeIsAnAliasForStatus() async throws {
        let dir = try tempProject(config: "")
        let r = await drupal("describe", in: dir, runtime: FakeRuntime())
        #expect(r.code == 0)
        #expect(r.envelope["command"] as? String == "status")
        #expect((r.data["status"] as? [String: Any])?["state"] as? String == "running")
    }
}

@Suite struct RuntimeCommandTests {
    @Test(arguments: [
        ["start"], ["stop"], ["restart"], ["status"], ["delete"], ["exec", "ls"], ["logs"],
    ])
    func stubRuntimeFailsWithNotImplemented(args: [String]) async throws {
        let dir = try tempProject(config: "")
        let r = await drupal(args, in: dir)
        #expect(r.code == ExitStatus.notImplemented.rawValue)
        #expect(r.envelope["ok"] as? Bool == false)
        #expect(r.error["code"] as? String == "not_implemented")
    }

    @Test func dbCommandsReachTheRuntime() async throws {
        let dir = try tempProject(config: "")
        let dump = dir.appending(path: "dump.sql")
        try "SELECT 1;".write(to: dump, atomically: true, encoding: .utf8)
        #expect(await drupal("import-db", "--file", "dump.sql", in: dir).code == ExitStatus.notImplemented.rawValue)
        #expect(await drupal("export-db", "--file", "out.sql", in: dir).code == ExitStatus.notImplemented.rawValue)
    }

    @Test func startRunsPostStartInOrder() async throws {
        let dir = try tempProject(config: "post_start:\n  - drush cr\n  - drush updb -y\n")
        let runtime = FakeRuntime()
        let r = await drupal("start", in: dir, runtime: runtime)
        #expect(r.code == 0)
        #expect(runtime.recorded == ["start", "exec web bash -c drush cr", "exec web bash -c drush updb -y"])
        #expect((r.data["post_start"] as? [[String: Any]])?.count == 2)
        #expect((r.data["project"] as? [String: Any])?["url"] as? String == "http://my-pantheon-site.drupal")
    }

    @Test func failingPostStartIsItsOwnExitCode() async throws {
        let dir = try tempProject(config: "post_start:\n  - \"false\"\n  - never-runs\n")
        let runtime = FakeRuntime(execExitCode: 1)
        let r = await drupal("start", in: dir, runtime: runtime)
        #expect(r.code == ExitStatus.postStartFailed.rawValue)
        #expect(runtime.recorded == ["start", "exec web bash -c false"])
    }

    @Test func restartStopsThenStarts() async throws {
        let runtime = FakeRuntime()
        let r = await drupal("restart", in: try tempProject(config: ""), runtime: runtime)
        #expect(r.code == 0)
        #expect(runtime.recorded == ["stop", "start"])
    }

    @Test func execPropagatesTheChildExitCode() async throws {
        let dir = try tempProject(config: "")
        let r = await drupal("exec", "--service", "db", "mysql", "-e", "SHOW TABLES", in: dir, runtime: FakeRuntime(execExitCode: 42))
        #expect(r.code == 42)
        #expect(r.envelope["ok"] as? Bool == true)
        #expect(r.data["exit_code"] as? Int == 42)
        #expect(r.data["command"] as? [String] == ["mysql", "-e", "SHOW TABLES"])
        #expect(r.data["stdout"] as? String == "out\n")
    }

    @Test func deletePassesKeepData() async throws {
        let runtime = FakeRuntime()
        let r = await drupal("delete", "--keep-data", in: try tempProject(config: ""), runtime: runtime)
        #expect(r.code == 0)
        #expect(runtime.recorded == ["delete keepData=true"])
    }

    @Test func sshRefusesWithoutATTY() async throws {
        let dir = try tempProject(config: "")
        let r = await drupal("ssh", in: dir, runtime: FakeRuntime())
        #expect(r.code == ExitStatus.usageError.rawValue)
    }

    @Test func exportDBNeedsFileInJSONModeAndWontClobber() async throws {
        let dir = try tempProject(config: "")
        #expect(await drupal("export-db", in: dir, runtime: FakeRuntime()).code == ExitStatus.usageError.rawValue)
        try "old".write(to: dir.appending(path: "db.sql"), atomically: true, encoding: .utf8)
        #expect(await drupal("export-db", "--file", "db.sql", in: dir, runtime: FakeRuntime()).code == ExitStatus.alreadyExists.rawValue)
        #expect(await drupal("export-db", "--file", "db.sql", "--force", in: dir, runtime: FakeRuntime()).code == 0)
    }

    @Test func importDBValidatesItsInput() async throws {
        let dir = try tempProject(config: "")
        #expect(await drupal("import-db", "--file", "missing.sql", in: dir, runtime: FakeRuntime()).code == ExitStatus.ioError.rawValue)
        #expect(await drupal("import-db", "--file", "dump.sql.gz", in: dir, runtime: FakeRuntime()).code == ExitStatus.usageError.rawValue)
        #expect(await drupal("import-db", in: dir, tty: true, runtime: FakeRuntime()).code == ExitStatus.usageError.rawValue)
    }

    @Test func logsStreamJSONLinesThenAnEnvelope() async throws {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let runtime = FakeRuntime(logEntries: [
            LogEntry(timestamp: t, service: .web, stream: .stdout, message: "GET /"),
            LogEntry(timestamp: t.addingTimeInterval(1), service: .db, stream: .stderr, message: "ready"),
        ])
        let r = await drupal("logs", in: try tempProject(config: ""), runtime: runtime)
        #expect(r.code == 0)
        let lines = r.stdout.split(separator: "\n").map { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        #expect(lines.count == 3)
        #expect(Set(lines[0]?.keys ?? [:].keys) == ["timestamp", "service", "stream", "message"])
        #expect(lines[1]?["service"] as? String == "db")
        #expect(lines[1]?["stream"] as? String == "stderr")
        #expect(lines[2]?["ok"] as? Bool == true)
        #expect((lines[2]?["data"] as? [String: Any])?["lines"] as? Int == 2)

        let webOnly = await drupal("logs", "--service", "web", in: try tempProject(config: ""), runtime: runtime)
        #expect(webOnly.stdout.split(separator: "\n").count == 2)
    }
}
