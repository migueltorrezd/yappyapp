import Darwin
import Foundation

/// YA-11: asks the kernel for a free localhost TCP port. The port is released
/// before the server binds it, so a launch that loses the race simply exits
/// and the launcher retries with a new port.
enum LocalPortAllocator {
    static func freePort() -> UInt16? {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr(WhisperServerController.host)

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return nil }

        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard named == 0 else { return nil }

        let port = UInt16(bigEndian: assigned.sin_port)
        return port == 0 ? nil : port
    }
}

/// YA-11: readiness only counts when the process listening on the port is the
/// child we launched. A ping that reaches anyone else is not trusted.
enum WhisperServerListenerCheck {
    static func ownsListener(listenerPIDs: [pid_t], childPID: pid_t) -> Bool {
        guard childPID > 0, !listenerPIDs.isEmpty else { return false }
        return listenerPIDs.allSatisfy { $0 == childPID }
    }
}

/// YA-11: finds whisper-server processes left behind by a crashed earlier
/// app instance. They were launched from our exact binary path and have been
/// re-parented to launchd (ppid 1). A live sibling app's child is never
/// matched, because its parent is still that app.
enum StrandedWhisperServers {
    /// Parses `ps -axo pid=,ppid=,comm=` output.
    static func pids(psOutput: String, binaryPath: String) -> [pid_t] {
        psOutput
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> pid_t? in
                let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
                guard fields.count == 3,
                      let pid = pid_t(fields[0]),
                      let parent = pid_t(fields[1]) else { return nil }
                let command = fields[2].trimmingCharacters(in: .whitespaces)
                guard parent == 1, command == binaryPath else { return nil }
                return pid
            }
    }
}

/// YA-11: exponential backoff for restarting a warm server that died on its
/// own. A server that stayed up for `stableAfter` seconds earns a fresh start
/// at the shortest delay, so one crash a day never waits a minute.
struct WhisperServerRestartBackoff: Sendable {
    static let baseDelay: TimeInterval = 1
    static let maximumDelay: TimeInterval = 60
    static let stableAfter: TimeInterval = 120

    private(set) var consecutiveFailures = 0
    private var readyAt: Date?

    mutating func markReady(at date: Date) {
        readyAt = date
    }

    /// The wait before the next restart attempt after an unexpected exit.
    mutating func nextDelay(now: Date) -> TimeInterval {
        if let readyAt, now.timeIntervalSince(readyAt) >= Self.stableAfter {
            consecutiveFailures = 0
        }
        readyAt = nil
        let delay = min(Self.maximumDelay, Self.baseDelay * pow(2, Double(consecutiveFailures)))
        consecutiveFailures += 1
        return delay
    }

    mutating func reset() {
        consecutiveFailures = 0
        readyAt = nil
    }
}
