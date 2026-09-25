import Testing
@testable import DrupalKit

@Suite struct ProjectNameTests {
    @Test(arguments: [
        ("my-pantheon-site", "my-pantheon-site"),
        ("My Site", "my-site"),
        ("my_site", "my-site"),
        ("Site.Example.com", "site-example-com"),
        ("Café Déjà Vu", "cafe-deja-vu"),
        ("--a__b--", "a-b"),
        ("  spaced   out  ", "spaced-out"),
        ("123", "123"),
        ("d10", "d10"),
    ])
    func sanitizesDirectoryNames(raw: String, expected: String) {
        #expect(ProjectName.sanitize(raw) == expected)
    }

    @Test(arguments: ["___", "日本語", "", "---", "!!!"])
    func unusableNamesYieldNil(raw: String) {
        #expect(ProjectName.sanitize(raw) == nil)
    }

    @Test func truncatesTo63WithoutTrailingDash() throws {
        let raw = String(repeating: "a", count: 62) + "_bbbb"
        let name = try #require(ProjectName.sanitize(raw))
        #expect(name.count <= 63)
        #expect(!name.hasSuffix("-"))
        #expect(name == String(repeating: "a", count: 62))
    }

    @Test func sanitizedNamesAlwaysValidate() {
        for raw in ["My Site", "Café", "a.b.c", String(repeating: "x-", count: 50)] {
            if let name = ProjectName.sanitize(raw) {
                #expect(ProjectName.validationProblem(name) == nil, "\(raw) -> \(name)")
            }
        }
    }

    @Test(arguments: ["my-site", "a", "d10", String(repeating: "a", count: 63)])
    func validNames(name: String) {
        #expect(ProjectName.validationProblem(name) == nil)
    }

    @Test(arguments: ["", "My-Site", "my_site", "-site", "site-", "my.site", String(repeating: "a", count: 64)])
    func invalidNames(name: String) {
        #expect(ProjectName.validationProblem(name) != nil)
    }

    @Test func hostnameUsesDrupalTLD() {
        #expect(ProjectName.hostname(for: "my-pantheon-site") == "my-pantheon-site.drupal")
    }
}
