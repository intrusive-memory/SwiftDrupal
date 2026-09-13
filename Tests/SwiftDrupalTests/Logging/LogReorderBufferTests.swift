import Foundation
import Testing
@testable import SwiftDrupal

/// `LogReorderBuffer` is a pure, synchronous state machine (no I/O, no
/// sleeps) — every test here drives it with hand-picked `Date`s, so the
/// reorder-window behavior is fully deterministic and runs instantly.
@Suite struct LogReorderBufferTests {
    private static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private static func line(_ offsetSeconds: Double, _ message: String, stream: StdioStream = .stdout) -> LogLine {
        LogLine(timestamp: epoch.addingTimeInterval(offsetSeconds), stream: stream, message: message)
    }

    // MARK: - Ordinary two-way merge (both sources have data)

    @Test func interleavesTwoFakeTimestampedStreamsInTimestampOrderAndTagsTheSource() {
        let buffer = LogReorderBuffer(reorderWindow: 0.25)
        let arrival = Self.epoch

        // Two fake source streams, arriving already fully available (both
        // buffered before any `drain`), interleaved by timestamp.
        buffer.receive(.web, Self.line(0, "web starting"), arrivalTime: arrival)
        buffer.receive(.web, Self.line(2, "web ready"), arrivalTime: arrival)
        buffer.receive(.db, Self.line(1, "db starting"), arrivalTime: arrival)
        buffer.receive(.db, Self.line(3, "db ready"), arrivalTime: arrival)
        buffer.markEnded(.web)
        buffer.markEnded(.db)

        let emitted = buffer.drain(now: arrival)

        #expect(emitted.map(\.line.message) == ["web starting", "db starting", "web ready", "db ready"])
        #expect(emitted.map(\.service) == [.web, .db, .web, .db])
        #expect(buffer.isEmpty)
    }

    @Test func keepsArrivalOrderWithinOneSource() {
        let buffer = LogReorderBuffer(reorderWindow: 0.25)
        let arrival = Self.epoch
        // Three same-timestamp lines from one source must come out in the
        // order they arrived, not re-sorted.
        buffer.receive(.web, Self.line(0, "first"), arrivalTime: arrival)
        buffer.receive(.web, Self.line(0, "second"), arrivalTime: arrival)
        buffer.receive(.web, Self.line(0, "third"), arrivalTime: arrival)
        buffer.markEnded(.web)
        buffer.markEnded(.db)

        #expect(buffer.drain(now: arrival).map(\.line.message) == ["first", "second", "third"])
    }

    @Test func breaksEqualTimestampTiesBetweenSourcesInFavorOfWeb() {
        let buffer = LogReorderBuffer(reorderWindow: 0.25)
        let arrival = Self.epoch
        buffer.receive(.db, Self.line(0, "db at t0"), arrivalTime: arrival)
        buffer.receive(.web, Self.line(0, "web at t0"), arrivalTime: arrival)
        buffer.markEnded(.web)
        buffer.markEnded(.db)

        let emitted = buffer.drain(now: arrival)
        #expect(emitted.map(\.service) == [.web, .db])
        #expect(emitted.map(\.line.message) == ["web at t0", "db at t0"])
    }

    // MARK: - The other source has nothing buffered yet

    @Test func doesNotEmitAWaitingLineBeforeTheOtherSourceCatchesUpOrEndsOrTheWindowElapses() {
        let buffer = LogReorderBuffer(reorderWindow: 0.25)
        let arrival = Self.epoch
        buffer.receive(.web, Self.line(0, "web only so far"), arrivalTime: arrival)
        // db has produced nothing and has not ended: web's line can't be
        // confirmed safe yet.
        #expect(buffer.drain(now: arrival).isEmpty)
        #expect(buffer.drain(now: arrival.addingTimeInterval(0.1)).isEmpty)
    }

    @Test func emitsAsSoonAsTheOtherSourceProducesALaterOrEqualTimestamp() {
        let buffer = LogReorderBuffer(reorderWindow: 0.25)
        let arrival = Self.epoch
        buffer.receive(.web, Self.line(0, "web t0"), arrivalTime: arrival)
        #expect(buffer.drain(now: arrival).isEmpty)

        // db's first line arrives later-or-equal to web's buffered line —
        // web's line is now provably the earliest possible, safe immediately
        // even though the window has not elapsed.
        let dbArrival = arrival.addingTimeInterval(0.01)
        buffer.receive(.db, Self.line(0.5, "db t0.5"), arrivalTime: dbArrival)
        let emitted = buffer.drain(now: dbArrival)
        #expect(emitted.map(\.line.message) == ["web t0"])
    }

    @Test func emitsImmediatelyOnceTheOtherSourceHasEndedRegardlessOfTheWindow() {
        let buffer = LogReorderBuffer(reorderWindow: 0.25)
        let arrival = Self.epoch
        buffer.receive(.web, Self.line(0, "web only"), arrivalTime: arrival)
        buffer.markEnded(.db)

        // No need to wait out the window: db can never produce anything else.
        let emitted = buffer.drain(now: arrival)
        #expect(emitted.map(\.line.message) == ["web only"])
    }

    @Test func emitsAfterTheReorderWindowElapsesEvenIfTheOtherSourceIsStillSilent() {
        let buffer = LogReorderBuffer(reorderWindow: 0.25)
        let arrival = Self.epoch
        buffer.receive(.web, Self.line(0, "web only"), arrivalTime: arrival)

        // Just under the window: still not safe.
        #expect(buffer.drain(now: arrival.addingTimeInterval(0.249)).isEmpty)
        // At/after the window: emit anyway, db having stayed silent.
        let emitted = buffer.drain(now: arrival.addingTimeInterval(0.25))
        #expect(emitted.map(\.line.message) == ["web only"])
    }

    @Test func nextDeadlineReportsTheEarliestWindowExpiryAndNilWhenNothingIsBlockedOnIt() {
        let buffer = LogReorderBuffer(reorderWindow: 0.25)
        let arrival = Self.epoch
        #expect(buffer.nextDeadline() == nil)

        buffer.receive(.web, Self.line(0, "solo"), arrivalTime: arrival)
        #expect(buffer.nextDeadline() == arrival.addingTimeInterval(0.25))

        // Once db has data (or has ended), the ordinary-merge/ended path
        // applies and the window is no longer the limiting factor.
        buffer.markEnded(.db)
        #expect(buffer.nextDeadline() == nil)
    }

    // MARK: - Single-source mode (the other role marked ended up front)

    @Test func singleActiveSourceNeverWaitsOnTheWindow() {
        let buffer = LogReorderBuffer(reorderWindow: 0.25)
        buffer.markEnded(.db)  // `drupal logs web`: db isn't part of the merge at all.
        let arrival = Self.epoch

        buffer.receive(.web, Self.line(0, "one"), arrivalTime: arrival)
        buffer.receive(.web, Self.line(1, "two"), arrivalTime: arrival)

        #expect(buffer.drain(now: arrival).map(\.line.message) == ["one", "two"])
    }

    @Test func sourceTaggingSurvivesTheMerge() {
        let buffer = LogReorderBuffer(reorderWindow: 0.25)
        let arrival = Self.epoch
        buffer.receive(.web, Self.line(0, "w", stream: .stdout), arrivalTime: arrival)
        buffer.receive(.db, Self.line(1, "d", stream: .stderr), arrivalTime: arrival)
        buffer.markEnded(.web)
        buffer.markEnded(.db)

        let emitted = buffer.drain(now: arrival)
        #expect(emitted[0].service == .web)
        #expect(emitted[0].line.stream == .stdout)
        #expect(emitted[1].service == .db)
        #expect(emitted[1].line.stream == .stderr)
    }
}
