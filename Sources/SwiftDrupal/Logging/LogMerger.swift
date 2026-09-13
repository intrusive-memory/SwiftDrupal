import Foundation

/// Merges one or two container log streams into a single timestamp-ordered,
/// source-tagged stream, using `LogReorderBuffer` for the actual merge
/// decision and a `LogMergeClock` for timing.
///
/// `drupal logs` (`LogsCommand`) is the only caller; tests exercise
/// `LogReorderBuffer` directly (deterministic, no async, no sleeps) and this
/// type end to end with a fake `LogMergeClock` whose `sleep(until:)` advances
/// virtual time instead of waiting for real.
public enum LogMerger {
    /// - Parameters:
    ///   - sources: one entry per container being followed (`drupal logs web`
    ///     supplies just `.web`; plain `drupal logs` supplies both). A role
    ///     absent from this dictionary is treated as already ended, so a
    ///     single-source merge never waits on the reorder window.
    public static func merge(
        sources: [ContainerRole: AsyncThrowingStream<LogLine, Error>],
        clock: any LogMergeClock = SystemLogMergeClock(),
        reorderWindow: TimeInterval = LogReorderBuffer.defaultReorderWindow
    ) -> AsyncThrowingStream<SourcedLogLine, Error> {
        AsyncThrowingStream { continuation in
            let coordinator = LogMergeCoordinator(
                reorderWindow: reorderWindow,
                clock: clock,
                continuation: continuation,
                activeServices: Set(sources.keys)
            )
            let task = Task {
                await withTaskGroup(of: Void.self) { group in
                    for (service, stream) in sources {
                        group.addTask {
                            do {
                                for try await line in stream {
                                    await coordinator.received(service, line)
                                }
                                await coordinator.ended(service)
                            } catch {
                                await coordinator.failed(error)
                            }
                        }
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Owns one `LogReorderBuffer` and the single timer that drives its
/// window-elapsed emissions, so the two source-reading tasks in
/// `LogMerger.merge` never need to race against a timeout themselves — they
/// just report what they see and let the actor decide what is safe to emit.
private actor LogMergeCoordinator {
    private let buffer: LogReorderBuffer
    private let clock: any LogMergeClock
    private let continuation: AsyncThrowingStream<SourcedLogLine, Error>.Continuation
    private let activeCount: Int
    private var endedCount = 0
    private var timerTask: Task<Void, Never>?
    private var finished = false

    init(
        reorderWindow: TimeInterval,
        clock: any LogMergeClock,
        continuation: AsyncThrowingStream<SourcedLogLine, Error>.Continuation,
        activeServices: Set<ContainerRole>
    ) {
        self.buffer = LogReorderBuffer(reorderWindow: reorderWindow)
        self.clock = clock
        self.continuation = continuation
        self.activeCount = activeServices.count
        for role in ContainerRole.allCases where !activeServices.contains(role) {
            buffer.markEnded(role)
        }
    }

    func received(_ service: ContainerRole, _ line: LogLine) {
        guard !finished else { return }
        buffer.receive(service, line, arrivalTime: clock.now())
        drainAndReschedule()
    }

    func ended(_ service: ContainerRole) {
        guard !finished else { return }
        buffer.markEnded(service)
        endedCount += 1
        drainAndReschedule()
    }

    func failed(_ error: Error) {
        guard !finished else { return }
        // Flush whatever the buffer is still holding — in normal merge
        // order — before finishing with the error. Otherwise lines that
        // arrived but were only ever "provisionally" buffered (waiting on
        // the other source or the reorder window) would be silently
        // dropped, and those are exactly the lines a user needs when a
        // stream errors out.
        for item in buffer.drainAll() {
            continuation.yield(item)
        }
        finish(throwing: error)
    }

    private func drainAndReschedule() {
        guard !finished else { return }
        for item in buffer.drain(now: clock.now()) {
            continuation.yield(item)
        }
        if endedCount >= activeCount && buffer.isEmpty {
            finish(throwing: nil)
            return
        }
        rescheduleTimer()
    }

    private func rescheduleTimer() {
        timerTask?.cancel()
        guard let deadline = buffer.nextDeadline() else {
            timerTask = nil
            return
        }
        let clock = self.clock
        timerTask = Task { [weak self] in
            try? await clock.sleep(until: deadline)
            guard !Task.isCancelled else { return }
            await self?.timerFired()
        }
    }

    private func timerFired() {
        guard !finished else { return }
        drainAndReschedule()
    }

    private func finish(throwing error: Error?) {
        finished = true
        timerTask?.cancel()
        timerTask = nil
        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
    }
}
