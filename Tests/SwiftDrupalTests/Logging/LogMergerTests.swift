import Foundation
import Synchronization
import Testing
@testable import SwiftDrupal

/// Deterministic `LogMergeClock`: `sleep(until:)` advances virtual time to
/// (at least) the requested deadline instead of waiting for real — mirrors
/// `TestHealthCheckClock` in Tests/SwiftDrupalTests/Container/MockContainerService.swift.
final class TestLogMergeClock: LogMergeClock, @unchecked Sendable {
    private let state: Mutex<Date>

    init(start: Date) {
        state = Mutex(start)
    }

    func now() -> Date { state.withLock { $0 } }

    func sleep(until deadline: Date) async throws {
        try Task.checkCancellation()
        state.withLock { if deadline > $0 { $0 = deadline } }
        await Task.yield()
    }
}

/// `LogMerger` end to end: real `AsyncThrowingStream`s and the actual actor
/// wiring, but a fake clock so nothing here waits on real time.
@Suite struct LogMergerTests {
    private static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private static func line(_ offsetSeconds: Double, _ message: String) -> LogLine {
        LogLine(timestamp: epoch.addingTimeInterval(offsetSeconds), stream: .stdout, message: message)
    }

    private static func finiteStream(_ lines: [LogLine]) -> AsyncThrowingStream<LogLine, Error> {
        AsyncThrowingStream { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        }
    }

    @Test func mergesTwoFakeTimestampedStreamsInOrderAndTagsTheSource() async throws {
        let web = Self.finiteStream([Self.line(0, "web boot"), Self.line(2, "web ready")])
        let db = Self.finiteStream([Self.line(1, "db boot"), Self.line(3, "db ready")])

        let merged = LogMerger.merge(
            sources: [.web: web, .db: db], clock: TestLogMergeClock(start: Self.epoch))

        var results: [SourcedLogLine] = []
        for try await entry in merged { results.append(entry) }

        #expect(results.map(\.line.message) == ["web boot", "db boot", "web ready", "db ready"])
        #expect(results.map(\.service) == [.web, .db, .web, .db])
    }

    @Test func aSingleRequestedServiceIsPassedThroughWithoutWaitingOnTheOtherSource() async throws {
        let web = Self.finiteStream([Self.line(0, "only web one"), Self.line(1, "only web two")])

        let merged = LogMerger.merge(sources: [.web: web], clock: TestLogMergeClock(start: Self.epoch))

        var results: [SourcedLogLine] = []
        for try await entry in merged { results.append(entry) }

        #expect(results.map(\.line.message) == ["only web one", "only web two"])
        #expect(results.allSatisfy { $0.service == .web })
    }

    @Test func aFailingSourceFailsTheMergedStream() async throws {
        struct BoomError: Error, Equatable {}
        let web = AsyncThrowingStream<LogLine, Error> { continuation in
            continuation.yield(Self.line(0, "before the failure"))
            continuation.finish(throwing: BoomError())
        }
        let db = Self.finiteStream([])

        let merged = LogMerger.merge(sources: [.web: web, .db: db], clock: TestLogMergeClock(start: Self.epoch))

        var results: [SourcedLogLine] = []
        await #expect(throws: BoomError.self) {
            for try await entry in merged { results.append(entry) }
        }
        #expect(results.map(\.line.message) == ["before the failure"])
    }
}
