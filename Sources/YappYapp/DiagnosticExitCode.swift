import Foundation

/// Thread-safe result handoff for command-line diagnostics that bridge an
/// async task back to their synchronous process entry point.
final class DiagnosticExitCode: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Int32 = 0

    var value: Int32 {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ value: Int32) {
        lock.lock()
        stored = value
        lock.unlock()
    }
}
