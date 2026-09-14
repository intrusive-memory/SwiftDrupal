import Darwin
import Dispatch
import Foundation

/// Ensures a cleanup closure (restoring the local terminal) runs even when
/// the process is interrupted by a signal mid-session, not just on a normal
/// return or thrown error (which `defer` already covers).
///
/// `ssh`/`exec` install one of these before requesting a pseudo-terminal and
/// cancel it once the session ends normally. `signal` and `exit` are
/// injectable so tests can trigger the handler with a harmless signal
/// (`SIGUSR2`) instead of `SIGINT`, and observe the "exit" without ending the
/// test process.
public enum InterruptGuard {
    /// Installs a one-shot handler for `signal`: the first delivery runs
    /// `cleanup()` then calls `exit(128 + signal)`, the conventional shell
    /// exit status for death-by-signal. Returns a token to `cancel()` once the
    /// guarded session finishes on its own.
    public static func install(
        signal: Int32 = SIGINT,
        cleanup: @escaping @Sendable () -> Void,
        exit: @escaping @Sendable (Int32) -> Void = { Foundation.exit($0) }
    ) -> InterruptGuardToken {
        Darwin.signal(signal, SIG_IGN)
        // A dedicated queue, not `.main`: this runs inside `drupal exec`/`ssh`,
        // a plain command-line process with no run loop pumping the main
        // queue (mirrors `TerminationSignal.wait` in ServiceServer.swift).
        let queue = DispatchQueue(label: "SwiftDrupal.InterruptGuard")
        let source = DispatchSource.makeSignalSource(signal: signal, queue: queue)
        let token = InterruptGuardToken(source: source, signal: signal)
        source.setEventHandler {
            // One-shot: cancel first so a second delivery of `signal` before
            // `exit()` actually terminates the process (or, in a test with an
            // injected `exit` closure, before the test observes the first
            // one) can't re-run `cleanup()`/`exit()`.
            token.cancel()
            cleanup()
            exit(128 + signal)
        }
        source.resume()
        return token
    }
}

/// Cancels an `InterruptGuard.install(...)` handler and restores the
/// process's default disposition for that signal.
public final class InterruptGuardToken: @unchecked Sendable {
    private let source: DispatchSourceSignal
    private let signal: Int32
    private var cancelled = false
    private let lock = NSLock()

    fileprivate init(source: DispatchSourceSignal, signal: Int32) {
        self.source = source
        self.signal = signal
    }

    public func cancel() {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return }
        cancelled = true
        source.cancel()
        Darwin.signal(signal, SIG_DFL)
    }
}
