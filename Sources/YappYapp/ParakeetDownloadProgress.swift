import Foundation

/// YA-51: byte-level progress across every file of one Parakeet download.
/// Files download in parallel; each reports the bytes it has received so far,
/// and the fraction is the sum over the whole plan. Thread safe.
final class ParakeetByteProgress: @unchecked Sendable {
    private let lock = NSLock()
    private let totalBytes: Int64
    private var receivedByFile: [String: Int64] = [:]
    private var lastReported: Double = -1

    /// Below this step a new fraction is not worth a UI update.
    static let reportingStep = 0.005

    init(totalBytes: Int64) {
        self.totalBytes = max(0, totalBytes)
    }

    /// Records the bytes received for one file. A file never moves backwards,
    /// so a retried request cannot make the bar jump down.
    func update(file: String, receivedBytes: Int64, expectedBytes: Int64) {
        lock.lock()
        let capped = min(max(0, receivedBytes), max(0, expectedBytes))
        receivedByFile[file] = max(receivedByFile[file] ?? 0, capped)
        lock.unlock()
    }

    var fraction: Double {
        lock.lock()
        defer { lock.unlock() }
        return unlockedFraction()
    }

    /// The fraction when it moved far enough since the last report, else nil.
    func fractionToReport() -> Double? {
        lock.lock()
        defer { lock.unlock() }
        let current = unlockedFraction()
        guard current >= 1 || current - lastReported >= Self.reportingStep else { return nil }
        lastReported = current
        return current
    }

    private func unlockedFraction() -> Double {
        guard totalBytes > 0 else { return 0 }
        let received = receivedByFile.values.reduce(Int64(0), +)
        return min(1, max(0, Double(received) / Double(totalBytes)))
    }
}
