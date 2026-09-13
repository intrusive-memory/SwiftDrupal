import Foundation
import Testing
@testable import SwiftDrupal

private func config(
    docroot: String = "web",
    php: String = "8.3",
    webserver: String = "nginx-fpm",
    dbType: String = "mariadb",
    dbVersion: String = "10.11",
    env: [String] = []
) -> ProjectConfig {
    ProjectConfig(
        docroot: docroot,
        phpVersion: php,
        webserverType: webserver,
        database: .init(type: dbType, version: dbVersion),
        webEnvironment: env
    )
}

private let projectRoot = URL(filePath: "/Users/dev/Sites/my-site", directoryHint: .isDirectory)
private let tag = DDEVImageCatalog.releaseTag

// MARK: - Image selection

@Suite struct ImageTagSelectionTests {
    @Test(arguments: [
        ("8.3", "nginx-fpm"),
        ("8.1", "apache-fpm"),
        ("7.4", "nginx-fpm"),
        ("8.4", "apache-fpm"),
    ])
    func webImageSelectsReleaseImageAndSelectorEnvironment(php: String, webserver: String) throws {
        let selection = try DDEVImageCatalog.webImage(phpVersion: php, webserverType: webserver)
        #expect(selection.reference == "docker.io/ddev/ddev-webserver:\(tag)")
        #expect(selection.selectorEnvironment == [
            "DDEV_PHP_VERSION=\(php)",
            "DDEV_WEBSERVER_TYPE=\(webserver)",
        ])
    }

    @Test(arguments: ["8.9", "8", "php8.3", ""])
    func webImageRejectsUnsupportedPHPVersion(php: String) {
        #expect(throws: DrupalError.self) {
            try DDEVImageCatalog.webImage(phpVersion: php, webserverType: "nginx-fpm")
        }
        do {
            _ = try DDEVImageCatalog.webImage(phpVersion: php, webserverType: "nginx-fpm")
        } catch let error as DrupalError {
            #expect(error.exitCode == .invalidConfig)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test(arguments: ["nginx", "apache-cgi", "caddy", "generic"])
    func webImageRejectsUnsupportedWebserverType(webserver: String) {
        #expect(throws: DrupalError.self) {
            try DDEVImageCatalog.webImage(phpVersion: "8.3", webserverType: webserver)
        }
    }

    @Test(arguments: [
        ("10.11", "docker.io/ddev/ddev-dbserver-mariadb-10.11"),
        ("11.4", "docker.io/ddev/ddev-dbserver-mariadb-11.4"),
        ("10.6", "docker.io/ddev/ddev-dbserver-mariadb-10.6"),
    ])
    func databaseImageSelectsRepositoryFromVersion(version: String, repository: String) throws {
        let reference = try DDEVImageCatalog.databaseImage(type: "mariadb", version: version)
        #expect(reference == "\(repository):\(tag)")
    }

    @Test func databaseImageVersionIsNotCollapsedAsFloat() throws {
        // "10.10" vs "10.1" must stay distinct; neither is silently rewritten.
        #expect(try DDEVImageCatalog.databaseImage(type: "mariadb", version: "10.1").hasSuffix("mariadb-10.1:\(tag)"))
    }

    @Test(arguments: ["mysql", "postgres", "MariaDB"])
    func databaseImageRejectsNonMariaDB(type: String) {
        #expect(throws: DrupalError.invalidConfig(
            "unsupported database.type \"\(type)\"; v1.0 supports: mariadb"
        )) {
            try DDEVImageCatalog.databaseImage(type: type, version: "10.11")
        }
    }

    @Test(arguments: ["10.12", "9.9", "latest"])
    func databaseImageRejectsUnsupportedVersion(version: String) {
        #expect(throws: DrupalError.self) {
            try DDEVImageCatalog.databaseImage(type: "mariadb", version: version)
        }
    }

    @Test func builtSpecsUseCatalogReferences() throws {
        let web = try WebContainerSpecBuilder(projectName: "my-site", projectRoot: projectRoot, config: config(php: "8.2", webserver: "apache-fpm")).build()
        #expect(web.imageReference == "docker.io/ddev/ddev-webserver:\(tag)")
        #expect(web.environmentValue("DDEV_PHP_VERSION") == "8.2")
        #expect(web.environmentValue("DDEV_WEBSERVER_TYPE") == "apache-fpm")

        let db = try DatabaseContainerSpecBuilder(
            projectName: "my-site", config: config(dbVersion: "11.4"), stateRoot: URL(filePath: "/tmp/state")
        ).build()
        #expect(db.imageReference == "docker.io/ddev/ddev-dbserver-mariadb-11.4:\(tag)")
    }

    @Test func webBuilderPropagatesInvalidConfig() {
        #expect(throws: DrupalError.self) {
            try WebContainerSpecBuilder(projectName: "x", projectRoot: projectRoot, config: config(php: "4.0")).build()
        }
        #expect(throws: DrupalError.self) {
            try DatabaseContainerSpecBuilder(projectName: "x", config: config(dbType: "mysql"), stateRoot: projectRoot).build()
        }
    }
}

// MARK: - Mounts

@Suite struct BindMountPathTests {
    @Test func webSpecMountsProjectRootOverVirtiofs() throws {
        let spec = try WebContainerSpecBuilder(projectName: "my-site", projectRoot: projectRoot, config: config()).build()
        #expect(spec.mounts == [
            MountSpec(kind: .virtiofs, hostPath: "/Users/dev/Sites/my-site", containerPath: "/var/www/html")
        ])
        #expect(spec.workingDirectory == "/var/www/html")
        #expect(spec.environmentValue("DDEV_DOCROOT") == "web")
    }

    @Test(arguments: [
        "/Users/dev/Sites/my-site",
        "/Users/dev/Sites/my-site/",
        "/Users/dev/Sites/./my-site",
        "/Users/dev/Sites/other/../my-site",
    ])
    func projectMountHostPathIsStandardized(path: String) {
        let mount = WebContainerSpecBuilder.projectMount(projectRoot: URL(filePath: path))
        #expect(mount.hostPath == "/Users/dev/Sites/my-site")
        #expect(mount.containerPath == WebContainerSpecBuilder.projectMountPath)
        #expect(!mount.readOnly)
        #expect(!mount.persistent)
    }

    @Test func projectMountPreservesSpacesUnencoded() {
        let mount = WebContainerSpecBuilder.projectMount(projectRoot: URL(filePath: "/Users/dev/My Sites/site one"))
        #expect(mount.hostPath == "/Users/dev/My Sites/site one")
    }

    @Test(arguments: [
        ("web", "web", "/var/www/html/web"),
        ("web/", "web", "/var/www/html/web"),
        ("./web", "web", "/var/www/html/web"),
        ("docroot/public", "docroot/public", "/var/www/html/docroot/public"),
        ("", "", "/var/www/html"),
        (".", "", "/var/www/html"),
    ])
    func docrootMapsUnderProjectMount(docroot: String, normalized: String, containerPath: String) throws {
        #expect(try WebContainerSpecBuilder.normalizedDocroot(docroot) == normalized)
        #expect(try WebContainerSpecBuilder.containerDocrootPath(docroot: docroot) == containerPath)
        let spec = try WebContainerSpecBuilder(projectName: "s", projectRoot: projectRoot, config: config(docroot: docroot)).build()
        #expect(spec.environmentValue("DDEV_DOCROOT") == normalized)
    }

    @Test(arguments: ["/var/www/html/web", "../web", "web/../../etc"])
    func docrootMustStayInsideProject(docroot: String) {
        #expect(throws: DrupalError.self) {
            try WebContainerSpecBuilder.normalizedDocroot(docroot)
        }
    }

    @Test func dbSpecUsesPersistentDataDirectoryOutsideProject() throws {
        let stateRoot = URL(filePath: "/Users/dev/Library/Application Support/drupal", directoryHint: .isDirectory)
        let spec = try DatabaseContainerSpecBuilder(projectName: "my-site", config: config(), stateRoot: stateRoot).build()
        #expect(spec.mounts == [
            MountSpec(
                kind: .virtiofs,
                hostPath: "/Users/dev/Library/Application Support/drupal/projects/my-site/db",
                containerPath: "/var/lib/mysql",
                persistent: true
            )
        ])
        #expect(!spec.mounts[0].hostPath.hasPrefix(projectRoot.path(percentEncoded: false)))
    }

    @Test func dbDataDirectoryUsesSanitizedProjectName() {
        let url = DatabaseContainerSpecBuilder.dataDirectoryHostURL(
            stateRoot: URL(filePath: "/state", directoryHint: .isDirectory), projectName: "My Site"
        )
        #expect(url.path(percentEncoded: false).hasPrefix("/state/projects/my-site/db"))
    }

    @Test func defaultStateRootIsApplicationSupport() {
        #expect(DatabaseContainerSpecBuilder.defaultStateRoot.path(percentEncoded: false).hasSuffix("Application Support/drupal/"))
    }
}

// MARK: - IDs

@Suite struct ContainerNamingTests {
    @Test func idsAreRoleSuffixed() throws {
        let web = try WebContainerSpecBuilder(projectName: "my-site", projectRoot: projectRoot, config: config()).build()
        let db = try DatabaseContainerSpecBuilder(projectName: "my-site", config: config(), stateRoot: projectRoot).build()
        #expect(web.id == "my-site-web")
        #expect(web.role == .web)
        #expect(web.hostname == "my-site.drupal")
        #expect(db.id == "my-site-db")
        #expect(db.role == .db)
    }

    @Test func idsAreSanitizedAndBounded() {
        #expect(ContainerNaming.containerID(projectName: "My Site!", role: .web) == "my-site--web")
        #expect(ContainerNaming.containerID(projectName: "", role: .db) == "project-db")
        let long = ContainerNaming.containerID(projectName: String(repeating: "a", count: 100), role: .web)
        #expect(long.count == ContainerNaming.maxIDLength)
        #expect(long.hasSuffix("-web"))
    }
}

// MARK: - web_environment

@Suite struct WebEnvironmentInjectionTests {
    @Test func emptyWebEnvironmentYieldsOnlyManagedVariables() throws {
        let spec = try WebContainerSpecBuilder(projectName: "my-site", projectRoot: projectRoot, config: config()).build()
        #expect(spec.environment == [
            "DDEV_PROJECT=my-site",
            "DDEV_HOSTNAME=my-site.drupal",
            "DDEV_DOCROOT=web",
            "DDEV_PHP_VERSION=8.3",
            "DDEV_WEBSERVER_TYPE=nginx-fpm",
        ])
    }

    @Test func webEnvironmentIsAppendedInOrder() throws {
        let spec = try WebContainerSpecBuilder(
            projectName: "my-site", projectRoot: projectRoot,
            config: config(env: ["APP_ENV=dev", "EMPTY=", "URL=http://x/?a=b=c"])
        ).build()
        #expect(Array(spec.environment.suffix(3)) == ["APP_ENV=dev", "EMPTY=", "URL=http://x/?a=b=c"])
        #expect(spec.environmentValue("EMPTY") == "")
        #expect(spec.environmentValue("URL") == "http://x/?a=b=c")
    }

    @Test func duplicateWebEnvironmentKeysLastWins() throws {
        let spec = try WebContainerSpecBuilder(
            projectName: "s", projectRoot: projectRoot, config: config(env: ["A=1", "B=2", "A=3"])
        ).build()
        #expect(spec.environment.filter { $0.hasPrefix("A=") } == ["A=3"])
        #expect(spec.environmentValue("B") == "2")
    }

    @Test(arguments: ["DDEV_PHP_VERSION=7.4", "DDEV_WEBSERVER_TYPE=apache-fpm", "DDEV_DOCROOT=x", "DDEV_PROJECT=y"])
    func webEnvironmentCannotOverrideManagedVariables(entry: String) {
        #expect(throws: DrupalError.self) {
            try WebContainerSpecBuilder(projectName: "s", projectRoot: projectRoot, config: config(env: [entry])).build()
        }
    }

    @Test(arguments: ["NOEQUALS", "=value", "1ABC=x", "BAD-KEY=x", "SP ACE=x"])
    func malformedWebEnvironmentIsInvalidConfig(entry: String) {
        do {
            _ = try WebContainerSpecBuilder(projectName: "s", projectRoot: projectRoot, config: config(env: [entry])).build()
            Issue.record("expected invalidConfig for \(entry)")
        } catch let error as DrupalError {
            #expect(error.exitCode == .invalidConfig)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func webEnvironmentIsNotInjectedIntoDatabase() throws {
        let db = try DatabaseContainerSpecBuilder(
            projectName: "s", config: config(env: ["SECRET=1"]), stateRoot: projectRoot
        ).build()
        #expect(db.environmentValue("SECRET") == nil)
    }

    @Test func webEnvironmentReachesServiceThroughCreate() async throws {
        let service = MockContainerService()
        let spec = try WebContainerSpecBuilder(
            projectName: "s", projectRoot: projectRoot, config: config(env: ["FOO=bar"])
        ).build()
        try await service.create(spec)
        #expect(await service.specs["s-web"]?.environmentValue("FOO") == "bar")
    }

    @Test func mergeReplacesInPlaceAndAppendsNewKeys() {
        #expect(EnvironmentList.merge(["PATH=/bin", "A=1", "A=2"], ["A=9", "B=1"]) == ["PATH=/bin", "A=9", "B=1"])
        #expect(EnvironmentList.merge([], []) == [])
        #expect(EnvironmentList.key(of: "K=v=w") == "K")
    }
}
