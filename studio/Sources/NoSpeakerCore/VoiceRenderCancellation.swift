import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public final class VoiceRenderCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
    }
    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }
    public func check() throws {
        if isCancelled { throw CancellationError() }
    }
}

public enum VoiceProcessError: Error, LocalizedError {
    case timeout
    public var errorDescription: String? { "Speech rendering exceeded its time limit." }
}

/// The caller owns the process and its I/O. No busy loop or background
/// process monitor: wait in bounded intervals on the worker thread.
#if !os(iOS)
public enum VoiceProcessRunner {
    public static func run(_ process: Process, cancellation: VoiceRenderCancellation,
                           timeout: Double = 90) throws {
        try run(process,cancellation:cancellation,timeout:timeout,onStarted:{})
    }

    // Internal synchronization point for deterministic child-process tests.
    // Production callers retain the same API and deadline.
    static func run(_ process: Process, cancellation: VoiceRenderCancellation,
                    timeout: Double, onStarted: () -> Void) throws {
        try cancellation.check()
        guard timeout.isFinite, timeout > 0, timeout <= 90 else { throw VoiceProcessError.timeout }
        let finished = DispatchSemaphore(value:0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        onStarted()
        while true {
            if finished.wait(timeout:.now()+0.05) == .success {
                try cancellation.check()
                return
            }
            if cancellation.isCancelled || ProcessInfo.processInfo.systemUptime >= deadline {
                if process.isRunning { process.terminate() }
                if finished.wait(timeout:.now()+2) == .timedOut, process.isRunning {
                    #if canImport(Darwin) || canImport(Glibc)
                    _ = kill(process.processIdentifier,SIGKILL)
                    #endif
                    _ = finished.wait(timeout:.now()+2)
                }
                try cancellation.check()
                throw VoiceProcessError.timeout
            }
        }
    }
}

#endif
