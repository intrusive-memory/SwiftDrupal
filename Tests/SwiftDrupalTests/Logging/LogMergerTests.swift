import Foundation
import Synchronization
import Testing
@testable import SwiftDrupal

/// Deterministic `LogMergeClock`: `now()` never advances on its own.
///
/// `LogMergeCoordinator` schedules `sleep(until:)` internally, on its own
/// timer task, whenever a buffered line is only waiting on the reorder
/// window — and it does this the instant such a line is buffered, racing
/// against whatever the *other* source's independently-scheduled reading
/// task is doing. An earlier version of this clock made `sleep(until:)`
/// immediately fast-forward `now()` to the requested deadline (a single
/// `Task.yield()`, no real wait), which let that internal timer "win" the
/// race and release a line via the reorder window before the other source
/// had a chance to deliver — nondeterministically reordering results
/// depending on scheduling. None of the tests below want the window to
/// fire this way: window-elapse itself is exercised directly and
/// synchronously against `LogReorderBuffer` (no clock or task scheduling
/// involved), so here `sleep(until:)` simply never resolves on its own —
/// only via the cancellation `LogMergeCoordinator` already performs
/// whenever it reschedules or finishes. Loosely mirrors `TestHealthCheckClock`
/// in Tests/SwiftDrupalTests/Container/MockContainerService.swift, minus
/// the auto-advance that made it unsafe for a two-task race like this one.
final class TestLogMergeClock: LogMergeClock, @unchecked Sendable {
    private let state: Mutex<Date>

    init(start: Date) {
        state = Mutex(start)
    }

    func now() -> Date { state.withLock { $0 } }

    func sleep(until deadline: Date) async throws {
        try await Task.sleep(for: .seconds(86400))
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

    /// Regression for a real dropped-log-lines bug: `LogMergeCoordinator`
    /// used to call `finish(throwing:)` the instant a source failed,
    /// discarding anything still sitting in the reorder buffer. Whether
    /// that discarded a line depended on whether the *other* source's
    /// `ended`/timestamp had already reached the actor before the failure
    /// did — pure scheduling luck, which is exactly why attempt 1's version
    /// of this test passed sometimes and failed sometimes.
    ///
    /// To make the outcome scheduling-independent, `db` here never yields
    /// and never ends: with the fake clock also never advanced, none of
    /// `LogReorderBuffer`'s three release paths (other source produces a
    /// later-or-equal timestamp, other source ends, or the reorder window
    /// elapses) can possibly fire. The only way "before the failure" can
    /// ever reach `results` is through the flush-on-failure path under
    /// test.
    @Test func aFailingSourceFailsTheMergedStream() async throws {
        struct BoomError: Error, Equatable {}
        let web = AsyncThrowingStream<LogLine, Error> { continuation in
            continuation.yield(Self.line(0, "before the failure"))
            continuation.finish(throwing: BoomError())
        }
        var dbContinuation: AsyncThrowingStream<LogLine, Error>.Continuation!
        let db = AsyncThrowingStream<LogLine, Error> { continuation in
            // Deliberately never yields and never finishes: db must stay
            // open and silent for the whole test, so it can't release
            // web's buffered line by ending, and (having produced nothing)
            // can't release it via a later timestamp either.
            dbContinuation = continuation
        }

        let merged = LogMerger.merge(sources: [.web: web, .db: db], clock: TestLogMergeClock(start: Self.epoch))

        var results: [SourcedLogLine] = []
        await #expect(throws: BoomError.self) {
            for try await entry in merged { results.append(entry) }
        }
        #expect(results.map(\.line.message) == ["before the failure"])

        // db's task is still parked waiting on its stream; terminate it now
        // that the assertion is done so it doesn't leak past the test.
        dbContinuation.finish()
    }

    /// Same regression, but with lines from *both* sources in play: `web`
    /// sends a line, then (after that line has provably been merged against
    /// `db`'s — see below) a second, later line, then fails; `db` sends one
    /// line and then, like above, stays open and silent forever.
    ///
    /// `web`'s first line can only ever be released by an ordinary merge
    /// comparison against `db`'s line — `db` never ends and the clock never
    /// advances, so the other two release paths are unavailable — so
    /// observing it in `results` is proof that `db`'s line has already
    /// reached the coordinator. Gating `web`'s second line and failure on
    /// that observation (rather than on a race between the two source
    /// tasks) guarantees both lines are already known to the coordinator
    /// before the failure fires, regardless of how the two source-reading
    /// tasks happen to be scheduled.
    @Test func aFailingSourceFlushesLinesBufferedFromBothSourcesInTimestampOrder() async throws {
        struct BoomError: Error, Equatable {}

        let webFirstLineEmitted = AsyncStream<Void>.makeStream()

        let web = AsyncThrowingStream<LogLine, Error> { continuation in
            continuation.yield(Self.line(0, "web first"))
            Task {
                for await _ in webFirstLineEmitted.stream {}
                continuation.yield(Self.line(5, "web second"))
                continuation.finish(throwing: BoomError())
            }
        }
        var dbContinuation: AsyncThrowingStream<LogLine, Error>.Continuation!
        let db = AsyncThrowingStream<LogLine, Error> { continuation in
            continuation.yield(Self.line(1, "db line"))
            dbContinuation = continuation  // stays open: never ends.
        }

        let merged = LogMerger.merge(sources: [.web: web, .db: db], clock: TestLogMergeClock(start: Self.epoch))

        var results: [SourcedLogLine] = []
        await #expect(throws: BoomError.self) {
            for try await entry in merged {
                results.append(entry)
                if results.count == 1 { webFirstLineEmitted.continuation.finish() }
            }
        }

        #expect(results.map(\.line.message) == ["web first", "db line", "web second"])

        dbContinuation.finish()
    }
}
