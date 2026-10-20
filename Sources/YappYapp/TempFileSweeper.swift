import Foundation

/// YA-13: voice WAVs and Whisper transcript files live in the temp directory
/// as `yappyapp-*`. A quit, Sparkle relaunch or crash can strand them, so the
/// app sweeps old ones at launch and deletes the in-flight ones on quit.
enum TempFileSweeper {
    static let prefix = "yappyapp-"
    /// Files younger than this may belong to a CLI diagnostic running right
    /// now, so the launch sweep leaves them for the next launch.
    static let minimumAge: TimeInterval = 120

    /// Deletes `yappyapp-*` entries in `directory` older than `minimumAge`.
    /// Returns the names it removed.
    @discardableResult
    static func sweep(
        directory: URL = FileManager.default.temporaryDirectory,
        now: Date = Date(),
        minimumAge: TimeInterval = TempFileSweeper.minimumAge
    ) -> [String] {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var removed: [String] = []
        for entry in entries where entry.lastPathComponent.hasPrefix(prefix) {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            guard now.timeIntervalSince(modified) >= minimumAge else { continue }
            if (try? fileManager.removeItem(at: entry)) != nil {
                removed.append(entry.lastPathComponent)
            }
        }
        return removed.sorted()
    }
}

/// Audio files a dictation is still using. The transcription task removes its
/// own file when it ends; on quit, whatever is left gets deleted here.
@MainActor
final class InFlightAudioFiles {
    private(set) var urls: Set<URL> = []

    func insert(_ url: URL) {
        urls.insert(url)
    }

    func remove(_ url: URL) {
        urls.remove(url)
    }

    /// Deletes every tracked file. Returns how many were removed.
    @discardableResult
    func deleteAll() -> Int {
        var count = 0
        for url in urls where (try? FileManager.default.removeItem(at: url)) != nil {
            count += 1
        }
        urls.removeAll()
        return count
    }
}
