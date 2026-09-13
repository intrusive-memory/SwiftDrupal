import ArgumentParser
import Foundation
import Testing
@testable import SwiftDrupal

@Suite struct LogsCommandTests {
    // MARK: - Registration and parsing

    @Test func logsIsRegisteredAndParsesNoArguments() throws {
        #expect(Drupal.configuration.subcommands.contains { $0 == LogsCommand.self })
        let parsed = try #require(try Drupal.parseAsRoot(["logs"]) as? LogsCommand)
        #expect(parsed.service == nil)
        #expect(parsed.follow == false)
        #expect(parsed.output.json == false)
    }

    @Test func parsesAnOptionalServiceArgument() throws {
        let parsed = try LogsCommand.parse(["db"])
        #expect(parsed.service == "db")
    }

    @Test func parsesFollowByLongAndShortName() throws {
        #expect(try LogsCommand.parse(["--follow"]).follow == true)
        #expect(try LogsCommand.parse(["-f"]).follow == true)
        #expect(try LogsCommand.parse(["web", "-f"]).service == "web")
        #expect(try LogsCommand.parse(["web", "-f"]).follow == true)
    }

    @Test func parsesTheJSONFlag() throws {
        #expect(try LogsCommand.parse(["--json"]).output.json == true)
        #expect(try LogsCommand.parse([]).output.json == false)
    }

    // MARK: - Service resolution

    @Test func noServiceArgumentSelectsBothContainersMerged() throws {
        #expect(try LogsCommand.resolveRoles(nil) == [.web, .db])
        #expect(try LogsCommand.resolveRoles("") == [.web, .db])
        #expect(try LogsCommand.resolveRoles("  ") == [.web, .db])
    }

    @Test func explicitServiceArgumentSelectsOneContainer() throws {
        #expect(try LogsCommand.resolveRoles("web") == [.web])
        #expect(try LogsCommand.resolveRoles("DB") == [.db])
    }

    @Test func unknownServiceArgumentIsRejected() {
        do {
            _ = try LogsCommand.resolveRoles("cache")
            Issue.record("expected invalidConfig")
        } catch let error as DrupalError {
            #expect(error.exitCode == .invalidConfig)
        } catch {
            Issue.record("wrong error type \(error)")
        }
    }

    // MARK: - JSON line schema

    @Test func jsonDocumentHasTheDocumentedKeysAndValues() {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000.5)
        let entry = SourcedLogLine(
            service: .db, line: LogLine(timestamp: timestamp, stream: .stderr, message: "connection refused"))

        let document = LogLineJSON.document(for: entry)
        #expect(document.service == "db")
        #expect(document.stream == "stderr")
        #expect(document.message == "connection refused")
        #expect(document.timestamp == LogLineJSON.timestampString(timestamp))
    }

    @Test func jsonTimestampIsISO8601WithFractionalSecondsAndUTC() {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000.123)
        let text = LogLineJSON.timestampString(timestamp)

        #expect(text.hasSuffix("Z"))
        #expect(text.contains("."))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        #expect(formatter.date(from: text) != nil)
    }

    @Test func encodedLineIsExactlyOneCompactJSONObjectWithTheDocumentedKeys() throws {
        let entry = SourcedLogLine(
            service: .web,
            line: LogLine(timestamp: Date(timeIntervalSince1970: 1_700_000_000), stream: .stdout, message: "ready"))
        let text = LogLineJSON.encode(entry)

        #expect(!text.contains("\n"))
        let data = Data(text.utf8)
        let decoded = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(decoded.keys) == ["timestamp", "service", "stream", "message"])
        #expect(decoded["service"] as? String == "web")
        #expect(decoded["stream"] as? String == "stdout")
        #expect(decoded["message"] as? String == "ready")

        // Round-trips through `LogLineJSONDocument` too.
        let redecoded = try JSONDecoder().decode(LogLineJSONDocument.self, from: data)
        #expect(redecoded == LogLineJSON.document(for: entry))
    }

    // MARK: - TUI rendering

    @Test func tuiPrefixesEachLineWithItsSourceInBrackets() {
        let webLine = SourcedLogLine(
            service: .web, line: LogLine(timestamp: Date(), stream: .stdout, message: "hello"))
        let dbLine = SourcedLogLine(
            service: .db, line: LogLine(timestamp: Date(), stream: .stdout, message: "world"))

        #expect(LogLineTUI.render(webLine, colorEnabled: false) == "[web] hello")
        #expect(LogLineTUI.render(dbLine, colorEnabled: false) == "[db] world")
    }

    @Test func tuiAddsAnsiColorOnlyWhenColorIsEnabled() {
        let entry = SourcedLogLine(service: .web, line: LogLine(timestamp: Date(), stream: .stdout, message: "hi"))

        let plain = LogLineTUI.render(entry, colorEnabled: false)
        let colored = LogLineTUI.render(entry, colorEnabled: true)

        #expect(!plain.contains("\u{001B}["))
        #expect(colored.contains("\u{001B}["))
        #expect(colored.contains("hi"))
        #expect(colored != plain)
    }
}
