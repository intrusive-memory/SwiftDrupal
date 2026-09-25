import Foundation
import Testing
@testable import DrupalKit

@Suite struct ConfigParserTests {
    func problems(_ yaml: String) -> [DrupalError.Detail] {
        do {
            _ = try ConfigParser.parse(yaml)
            return []
        } catch {
            #expect(error.status == .configInvalid)
            return error.details
        }
    }

    @Test func emptyFileIsAllDefaults() throws {
        let parsed = try ConfigParser.parse("")
        #expect(parsed.config == ProjectConfig())
        #expect(parsed.explicitKeys.isEmpty)
        #expect(parsed.config.phpVersion == ProjectConfig.Defaults.phpVersion)
        #expect(parsed.config.database.version == ProjectConfig.Defaults.databaseVersion)
        #expect(parsed.config.docroot == "web")
        #expect(parsed.config.webserverType == .nginxFPM)
    }

    @Test func requirementsDocExampleParses() throws {
        let parsed = try ConfigParser.parse("""
            docroot: web
            php_version: "8.3"
            webserver_type: nginx-fpm
            database:
              type: mariadb
              version: "10.11"
            web_environment: []
            """)
        #expect(parsed.config.phpVersion == "8.3")
        #expect(parsed.config.database == DatabaseConfig(type: .mariadb, version: "10.11"))
        #expect(parsed.explicitKeys == ["docroot", "php_version", "webserver_type", "database.type", "database.version", "web_environment"])
    }

    @Test func unquotedVersionsKeepTheirText() throws {
        let parsed = try ConfigParser.parse("php_version: 8.3\ndatabase:\n  version: 10.11\n")
        #expect(parsed.config.phpVersion == "8.3")
        #expect(parsed.config.database.version == "10.11")
    }

    @Test func nullValuesMeanDefault() throws {
        let parsed = try ConfigParser.parse("php_version:\nnodejs_version: ~\n")
        #expect(parsed.config.phpVersion == ProjectConfig.Defaults.phpVersion)
        #expect(parsed.config.nodejsVersion == nil)
        #expect(parsed.explicitKeys.isEmpty)
    }

    @Test func allOptionalFieldsParse() throws {
        let parsed = try ConfigParser.parse("""
            name: custom-name
            docroot: ""
            webserver_type: apache-fpm
            web_environment:
              - FOO=bar
              - EMPTY=
            post_start:
              - drush cr
            nodejs_version: "22"
            """)
        #expect(parsed.config.name == "custom-name")
        #expect(parsed.config.docroot == "")
        #expect(parsed.config.webserverType == .apacheFPM)
        #expect(parsed.config.webEnvironment == ["FOO=bar", "EMPTY="])
        #expect(parsed.config.postStart == ["drush cr"])
        #expect(parsed.config.nodejsVersion == "22")
    }

    @Test func unknownKeySuggestsClosestMatch() {
        let p = problems("phpversion: \"8.3\"\n")
        #expect(p.count == 1)
        #expect(p[0].path == "phpversion")
        #expect(p[0].line == 1)
        #expect(p[0].message.contains("did you mean 'php_version'"))
    }

    @Test func unknownNestedKeyIsReportedWithPath() {
        let p = problems("database:\n  type: mariadb\n  verison: \"10.11\"\n")
        #expect(p.map(\.path) == ["database.verison"])
        #expect(p[0].line == 3)
        #expect(p[0].message.contains("database.version"))
    }

    @Test func ddevOnlyKeysGetAnExplanation() {
        let p = problems("xdebug_enabled: false\ntype: drupal\n")
        #expect(p.map(\.path) == ["xdebug_enabled", "type"])
        #expect(p.allSatisfy { $0.message.contains("DDEV setting") })
    }

    @Test(arguments: ["mysql", "postgres", "MariaDB"])
    func onlyMariaDBIsSupported(type: String) {
        let p = problems("database:\n  type: \(type)\n")
        #expect(p.map(\.path) == ["database.type"])
        #expect(p[0].message.contains("only 'mariadb'"))
    }

    @Test(arguments: ["8.0", "7.4", "8", "latest", "8.3.1"])
    func rejectsUnsupportedPHP(version: String) {
        let p = problems("php_version: \"\(version)\"\n")
        #expect(p.map(\.path) == ["php_version"])
        #expect(p[0].line == 1)
        #expect(p[0].message.contains("'8.4'"))
    }

    @Test func rejectsUnsupportedMariaDBVersion() {
        let p = problems("database:\n  version: \"10.4\"\n")
        #expect(p.map(\.path) == ["database.version"])
    }

    @Test func rejectsUnknownWebserver() {
        let p = problems("webserver_type: caddy\n")
        #expect(p.map(\.path) == ["webserver_type"])
        #expect(p[0].message.contains("nginx-fpm"))
    }

    @Test func wrongShapesAreReported() {
        let p = problems("database: mariadb\nweb_environment: FOO=bar\npost_start:\n  - [nested]\nphp_version: [8.3]\n")
        #expect(Set(p.compactMap(\.path)) == ["database", "web_environment", "post_start[0]", "php_version"])
    }

    @Test func topLevelMustBeAMapping() {
        let p = problems("- a\n- b\n")
        #expect(p.count == 1)
        #expect(p[0].message.contains("mapping"))
    }

    @Test func syntaxErrorsCarryALine() {
        let p = problems("docroot: web\nphp_version: \"8.3\n")
        #expect(p.count == 1)
        #expect(p[0].message.hasPrefix("YAML syntax error"))
        #expect(p[0].line != nil)
    }

    @Test func webEnvironmentEntriesAreValidated() {
        let p = problems("web_environment:\n  - NOEQUALS\n  - 9BAD=x\n  - OK=1\n  - OK=2\n")
        #expect(p.map(\.path) == ["web_environment[0]", "web_environment[1]", "web_environment[3]"])
        #expect(p[2].message.contains("duplicate"))
    }

    @Test(arguments: ["/var/www", "../outside", "web/../../x", "~/site"])
    func docrootMustStayInsideProject(docroot: String) {
        #expect(problems("docroot: \"\(docroot)\"\n").map(\.path) == ["docroot"])
    }

    @Test func invalidExplicitNameSuggestsSanitizedForm() {
        let p = problems("name: My_Site\n")
        #expect(p.map(\.path) == ["name"])
        #expect(p[0].message.contains("try 'my-site'"))
    }

    @Test func nodejsVersionMustBeNumeric() {
        #expect(problems("nodejs_version: \"22.11.0\"\n").isEmpty)
        #expect(problems("nodejs_version: lts\n").map(\.path) == ["nodejs_version"])
    }

    @Test func reportsEveryProblemAtOnce() throws {
        do {
            _ = try ConfigParser.parse("phpversion: 1\nwebserver_type: caddy\ndatabase:\n  type: mysql\n", file: "x.yaml")
            Issue.record("expected failure")
        } catch {
            #expect(error.details.count == 3)
            #expect(error.message.hasPrefix("x.yaml has 3 problems"))
            #expect(error.status.rawValue == 3)
        }
    }
}

@Suite struct ConfigWriterTests {
    @Test func roundTripsThroughTheParser() throws {
        let config = ProjectConfig(
            name: "round-trip",
            docroot: "docroot",
            phpVersion: "8.2",
            webserverType: .apacheFPM,
            database: DatabaseConfig(version: "10.11"),
            webEnvironment: ["QUOTED=\"hi\" # not a comment", "COLON=a: b"],
            postStart: ["drush cr", "echo 'x' && echo \"y\"\\n"],
            nodejsVersion: "20"
        )
        let parsed = try ConfigParser.parse(ConfigWriter.render(config))
        #expect(parsed.config == config)
    }

    @Test func defaultConfigRoundTrips() throws {
        let text = ConfigWriter.render(ProjectConfig())
        #expect(try ConfigParser.parse(text).config == ProjectConfig())
        #expect(text.contains("php_version: \"\(ProjectConfig.Defaults.phpVersion)\""))
        #expect(!text.contains("name:"))
        #expect(!text.contains("nodejs_version"))
    }

    @Test func renderingIsDeterministic() {
        let config = ProjectConfig(webEnvironment: ["A=1"])
        #expect(ConfigWriter.render(config) == ConfigWriter.render(config))
    }
}

@Suite struct ResolvedProjectTests {
    @Test func derivesNameAndHostnameFromDirectory() throws {
        let dir = try tempProject("My Pantheon_Site", config: "")
        let project = try ResolvedProject.locate(from: dir)
        #expect(project.name == "my-pantheon-site")
        #expect(project.nameSource == .directory)
        #expect(project.hostname == "my-pantheon-site.drupal")
        #expect(project.url == "http://my-pantheon-site.drupal")
        #expect(project.defaultsApplied == ResolvedProject.defaultableKeys)
    }

    @Test func explicitNameWins() throws {
        let dir = try tempProject("whatever", config: "name: chosen\n")
        let project = try ResolvedProject.locate(from: dir)
        #expect(project.name == "chosen")
        #expect(project.nameSource == .config)
        #expect(project.hostname == "chosen.drupal")
    }

    @Test func findsProjectFromSubdirectory() throws {
        let dir = try tempProject(config: "")
        let sub = dir.appending(path: "web/modules/custom", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let project = try ResolvedProject.locate(from: sub)
        #expect(project.root.filePath == dir.standardizedFileURL.filePath)
        #expect(project.docrootPath.filePath == dir.appending(path: "web").standardizedFileURL.filePath)
        #expect(project.warnings.isEmpty)
    }

    @Test func missingConfigIsProjectNotFound() throws {
        let dir = try tempProject()
        #expect(throws: DrupalError.self) { try ResolvedProject.locate(from: dir) }
        do { _ = try ResolvedProject.locate(from: dir) } catch { #expect(error.status == .projectNotFound) }
    }

    @Test func underivableNameIsConfigInvalid() throws {
        let dir = try tempProject("___", config: "")
        do {
            _ = try ResolvedProject.locate(from: dir)
            Issue.record("expected failure")
        } catch {
            #expect(error.status == .configInvalid)
            #expect(error.details.first?.path == "name")
        }
    }

    @Test func warnsWhenDocrootIsMissing() throws {
        let dir = try tempProject(config: "docroot: public\n")
        let project = try ResolvedProject.locate(from: dir)
        #expect(project.warnings.count == 1)
        #expect(project.warnings[0].contains("public"))
    }

    @Test func imagesFollowTheDatabaseVersion() throws {
        let dir = try tempProject(config: "database:\n  version: \"10.11\"\n")
        let project = try ResolvedProject.locate(from: dir)
        #expect(project.images.db.hasPrefix("ddev/ddev-dbserver-mariadb-10.11:"))
        #expect(project.images.web.hasPrefix("ddev/ddev-webserver:"))
    }
}
