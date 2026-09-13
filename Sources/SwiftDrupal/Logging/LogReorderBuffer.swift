import Foundation

/// One log line tagged with the container it came from. What `drupal logs`
/// ultimately emits, one way or another (TUI line or JSON object).
public struct SourcedLogLine: Equatable, Sendable {
    public var service: ContainerRole
    public var line: LogLine

    public init(service: ContainerRole, line: LogLine) {
        self.service = service
        self.line = line
    }
}

/// Pure, synchronous merge state machine for `drupal logs`: buffers
/// source-tagged log lines from the web and db containers and decides, given
/// "now", which are safe to emit next in timestamp order.
///
/// Both containers produce their own lines in non-decreasing timestamp order,
/// but the *other* source can simply be quiet for a while — a plain k-way
/// merge can't tell "nothing more is coming right now" from "slow, wait
/// forever". A buffered line becomes safe to emit once:
///   1. the other source's buffered front is timestamped later-or-equal (the
///      ordinary two-way merge case — no waiting needed), or
///   2. the other source has ended (nothing more will ever arrive from it), or
///   3. `reorderWindow` has elapsed since this line arrived at the buffer
///      (bounded wait, then emit anyway — a line from the other source could
///      still turn out to belong before it, but by less than the window).
///
/// Equal timestamps keep arrival order within one source (each source's
/// queue is FIFO) and break ties between sources by emitting `web` before
/// `db`.
///
/// This type does no I/O and never sleeps — it is driven by an external
/// caller (`LogMerger`) that supplies wall-clock time through an injectable
/// clock, which is what makes the window logic deterministically testable
/// without real delays.
public final class LogReorderBuffer: @unchecked Sendable {
    /// Default bounded wait for a silent source before emitting anyway.
    public static let defaultReorderWindow: TimeInterval = 0.25

    /// Total order used to pick the next safe line: event timestamp first,
    /// then source priority (`web` before `db`) to break timestamp ties,
    /// then arrival sequence to keep within-source FIFO order stable.
    private struct Key: Comparable {
        let timestamp: Date
        let priority: Int
        let sequence: Int

        static func < (lhs: Key, rhs: Key) -> Bool {
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
            if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
            return lhs.sequence < rhs.sequence
        }
    }

    private struct Buffered {
        let sourced: SourcedLogLine
        let arrivalTime: Date
        let key: Key
    }

    private let reorderWindow: TimeInterval
    private var queues: [ContainerRole: [Buffered]] = [.web: [], .db: []]
    private var ended: [ContainerRole: Bool] = [.web: false, .db: false]
    private var nextSequence = 0

    public init(reorderWindow: TimeInterval = LogReorderBuffer.defaultReorderWindow) {
        self.reorderWindow = reorderWindow
    }

    /// Buffers a source-tagged line that arrived at `arrivalTime` (wall-clock
    /// time as seen by the driving loop's clock, not `line.timestamp`).
    public func receive(_ service: ContainerRole, _ line: LogLine, arrivalTime: Date) {
        nextSequence += 1
        let key = Key(timestamp: line.timestamp, priority: priority(service), sequence: nextSequence)
        queues[service, default: []].append(
            Buffered(sourced: SourcedLogLine(service: service, line: line), arrivalTime: arrivalTime, key: key))
    }

    /// Marks `service`'s source as finished: no more lines will ever arrive
    /// from it, so the other source no longer needs to wait on it.
    public func markEnded(_ service: ContainerRole) {
        ended[service] = true
    }

    /// Pops every line that is safe to emit as of `now`, in emission order.
    public func drain(now: Date) -> [SourcedLogLine] {
        var emitted: [SourcedLogLine] = []
        while let popped = popSafeFront(now: now) {
            emitted.append(popped)
        }
        return emitted
    }

    /// Pops and returns *every* currently buffered line, regardless of
    /// window, ended state, or what the other source's front looks like —
    /// in the same total merge order `drain` would eventually produce
    /// (timestamp, then `web` before `db` on ties, then per-source arrival
    /// order). Used when a source has failed: whatever the buffer is
    /// holding at that point must still reach the caller before the merged
    /// stream finishes with the error, rather than being silently dropped
    /// because the ordinary safety checks were never satisfied.
    public func drainAll() -> [SourcedLogLine] {
        let all = (queues[.web] ?? []) + (queues[.db] ?? [])
        let flushed = all.sorted { $0.key < $1.key }.map(\.sourced)
        queues[.web] = []
        queues[.db] = []
        return flushed
    }

    /// The earliest time a currently-blocked front becomes safe purely
    /// because `reorderWindow` elapses, or nil when nothing is blocked on the
    /// window (either both queues are empty, or every non-empty front is
    /// already resolvable against the other source).
    public func nextDeadline() -> Date? {
        var deadline: Date?
        for service in ContainerRole.allCases {
            guard let front = queues[service]?.first else { continue }
            let other = otherRole(service)
            if queues[other]?.first != nil { continue }  // ordinary merge applies, no window needed
            if ended[other] == true { continue }  // already safe now
            let candidate = front.arrivalTime.addingTimeInterval(reorderWindow)
            if deadline == nil || candidate < deadline! { deadline = candidate }
        }
        return deadline
    }

    /// True once every buffered line has been drained.
    public var isEmpty: Bool {
        (queues[.web]?.isEmpty ?? true) && (queues[.db]?.isEmpty ?? true)
    }

    // MARK: - Internals

    private func popSafeFront(now: Date) -> SourcedLogLine? {
        guard let service = safeService(now: now) else { return nil }
        return queues[service]!.removeFirst().sourced
    }

    /// At most one source can be "safe" at a time: when both queues are
    /// non-empty, the ordinary merge comparison is mutually exclusive (ties
    /// resolve to `web` via `Key.priority`); when only one has data, only it
    /// can qualify (through the other-ended or window-elapsed cases).
    private func safeService(now: Date) -> ContainerRole? {
        for service in ContainerRole.allCases {
            guard let front = queues[service]?.first else { continue }
            let other = otherRole(service)
            if let otherFront = queues[other]?.first {
                if front.key <= otherFront.key { return service }
            } else if ended[other] == true {
                return service
            } else if now.timeIntervalSince(front.arrivalTime) >= reorderWindow {
                return service
            }
        }
        return nil
    }

    private func priority(_ service: ContainerRole) -> Int {
        service == .web ? 0 : 1
    }

    private func otherRole(_ service: ContainerRole) -> ContainerRole {
        service == .web ? .db : .web
    }
}
