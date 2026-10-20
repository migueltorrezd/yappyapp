import Darwin
import Foundation

/// Prevents multiple physical copies of YappYapp from creating independent
/// menu-bar items. macOS can index both the installed app and a packaged build,
/// so bundle identity alone is not enough to guarantee a single process.
@MainActor
final class SingleInstanceGuard {
    static let shared = SingleInstanceGuard()

    private var lockFileDescriptor: Int32 = -1

    private init() {}

    func acquire() -> Bool {
        if lockFileDescriptor >= 0 {
            return true
        }

        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "app.yappyapp.YappYapp"
        let lockURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(Self.lockFileName(
                bundleIdentifier: bundleIdentifier,
                userID: getuid(),
                supportBaseOverride: ProcessInfo.processInfo.environment[AppPaths.applicationSupportBaseEnvironmentKey]
            ))

        let descriptor = lockURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        }

        // If the lock file itself cannot be opened, fail open so a filesystem
        // issue never prevents the user from launching YappYapp.
        guard descriptor >= 0 else {
            return true
        }

        guard Darwin.lockf(descriptor, F_TLOCK, 0) == 0 else {
            Darwin.close(descriptor)
            return false
        }

        lockFileDescriptor = descriptor
        return true
    }

    /// An isolated support base (launch smokes, clean-install checks) shares
    /// no files with the user's own copy, so it gets its own lock: a smoke run
    /// never collides with the YappYapp the user has open, and two copies on
    /// the real support folder still cannot both start.
    nonisolated static func lockFileName(bundleIdentifier: String, userID: uid_t, supportBaseOverride: String?) -> String {
        var name = "\(bundleIdentifier).\(userID)"
        if let base = supportBaseOverride?.trimmingCharacters(in: .whitespacesAndNewlines), !base.isEmpty {
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325
            for byte in base.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01b3
            }
            name += ".\(String(hash, radix: 16))"
        }
        return name + ".instance.lock"
    }
}
