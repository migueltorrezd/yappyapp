import Foundation

// LLM-CLEANUP (YA-10): the cleanup model on disk, and what the app may say
// about it. "Cleanup model ready" is only true when the runtime is present
// and the model file is the pinned one, checked by SHA-1. Hashing 1.1 GB on
// every launch is too slow, so a verified file gets a small stamp (checksum,
// size, modification date); a changed file loses it and is checked again.

struct CleanupModelStamp: Codable, Equatable, Sendable {
    var sha1: String
    var size: Int64
    var modified: Double
}

enum CleanupModelError: LocalizedError, Equatable {
    case checksumMismatch(expected: String, actual: String)
    case httpStatus(Int)
    case canceled

    var errorDescription: String? {
        switch self {
        case .checksumMismatch(let expected, let actual):
            "The cleanup model failed its checksum (expected \(expected), got \(actual)). It was not installed."
        case .httpStatus(let code):
            "The cleanup model download returned HTTP \(code)."
        case .canceled:
            L10n.tr("Cleanup model download canceled.")
        }
    }
}

enum CleanupModelStore {
    static var stampURL: URL {
        AppPaths.modelsDirectory.appendingPathComponent(".\(LLMCleaner.model.filename).verified.json")
    }

    /// Partial download kept next to the model until it is verified.
    static var stagingURL: URL {
        AppPaths.modelsDirectory.appendingPathComponent("\(LLMCleaner.model.filename).download")
    }

    static func currentStamp(of url: URL, sha1: String) -> CleanupModelStamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return CleanupModelStamp(sha1: sha1.lowercased(), size: size, modified: modified.timeIntervalSince1970)
    }

    /// True when the model file still matches the stamp written after its
    /// checksum passed. Cheap: no hashing.
    static func isVerified(
        modelURL: URL = LLMCleaner.modelURL,
        stampURL: URL = stampURL,
        expectedSHA1: String = LLMCleaner.model.expectedSHA1
    ) -> Bool {
        guard let data = try? Data(contentsOf: stampURL),
              let stamp = try? JSONDecoder().decode(CleanupModelStamp.self, from: data),
              stamp.sha1 == expectedSHA1.lowercased(),
              let current = currentStamp(of: modelURL, sha1: expectedSHA1) else { return false }
        // Sub-millisecond noise in a JSON round trip of the date is not a change.
        return current.sha1 == stamp.sha1
            && current.size == stamp.size
            && abs(current.modified - stamp.modified) < 0.001
    }

    private static func writeStamp(for modelURL: URL, stampURL: URL, sha1: String) throws {
        guard let stamp = currentStamp(of: modelURL, sha1: sha1) else { return }
        try PrivateFile.write(try JSONEncoder().encode(stamp), to: stampURL)
    }

    /// Hashes an unstamped model (for example one installed by an older
    /// version or by hand) and stamps it when it is the pinned file. Slow:
    /// call it off the main thread.
    @discardableResult
    static func verifyExisting(
        modelURL: URL = LLMCleaner.modelURL,
        stampURL: URL = stampURL,
        expectedSHA1: String = LLMCleaner.model.expectedSHA1,
        sha1: (URL) throws -> String = ModelIntegrity.sha1Hex(for:)
    ) throws -> Bool {
        guard FileManager.default.fileExists(atPath: modelURL.path) else { return false }
        let actual = try sha1(modelURL)
        guard actual.lowercased() == expectedSHA1.lowercased() else {
            try? FileManager.default.removeItem(at: stampURL)
            return false
        }
        try writeStamp(for: modelURL, stampURL: stampURL, sha1: expectedSHA1)
        return true
    }

    /// Checks a finished download and moves it into place. A file that fails
    /// the checksum is deleted and never becomes the model.
    static func install(
        downloadedFile: URL,
        modelURL: URL = LLMCleaner.modelURL,
        stampURL: URL = stampURL,
        expectedSHA1: String = LLMCleaner.model.expectedSHA1,
        sha1: (URL) throws -> String = ModelIntegrity.sha1Hex(for:)
    ) throws {
        let actual = try sha1(downloadedFile)
        guard actual.lowercased() == expectedSHA1.lowercased() else {
            try? FileManager.default.removeItem(at: downloadedFile)
            throw CleanupModelError.checksumMismatch(expected: expectedSHA1, actual: actual)
        }
        let fileManager = FileManager.default
        try PrivateFile.ensureDirectory(at: modelURL.deletingLastPathComponent())
        try? fileManager.removeItem(at: stampURL)
        if fileManager.fileExists(atPath: modelURL.path) {
            try fileManager.removeItem(at: modelURL)
        }
        try fileManager.moveItem(at: downloadedFile, to: modelURL)
        try writeStamp(for: modelURL, stampURL: stampURL, sha1: expectedSHA1)
    }
}

// MARK: - What Setup says

/// Download progress of the cleanup model, owned by AppDelegate.
enum CleanupDownloadPhase: Equatable, Sendable {
    case idle
    case downloading(fraction: Double?)
    case verifying
    case failed(String)
}

/// One honest line about cleanup for Setup and the status line.
enum CleanupReadiness: Equatable, Sendable {
    /// Verbatim: nothing to run.
    case off
    /// No llama.cpp runtime: the model is never downloaded in this state.
    case needsRuntime
    case needsModel(downloadsAllowed: Bool)
    case downloading(fraction: Double?)
    case verifying
    case failed(String)
    case ready

    static func evaluate(
        mode: CleanupMode,
        runtimeAvailable: Bool,
        modelVerified: Bool,
        downloadsAllowed: Bool,
        download: CleanupDownloadPhase
    ) -> CleanupReadiness {
        guard mode.usesModel else { return .off }
        guard runtimeAvailable else { return .needsRuntime }
        if modelVerified { return .ready }
        switch download {
        case .downloading(let fraction): return .downloading(fraction: fraction)
        case .verifying: return .verifying
        case .failed(let message): return .failed(message)
        case .idle: return .needsModel(downloadsAllowed: downloadsAllowed)
        }
    }

    /// Short uppercase line under the mode picker.
    var headline: String {
        switch self {
        case .off:
            L10n.tr("NO MODEL NEEDED")
        case .needsRuntime:
            L10n.tr("THIS COPY CAN'T RUN CLEANUP")
        case .needsModel(let downloadsAllowed):
            downloadsAllowed ? L10n.tr("NEEDS THE CLEANUP MODEL") : L10n.tr("NEEDS THE CLEANUP MODEL · DOWNLOADS OFF")
        case .downloading(let fraction):
            fraction.map { L10n.tr("DOWNLOADING %@%%", "\(Int(($0 * 100).rounded(.down)))") } ?? L10n.tr("DOWNLOADING")
        case .verifying:
            L10n.tr("VERIFYING")
        case .failed:
            L10n.tr("DOWNLOAD FAILED")
        case .ready:
            L10n.tr("CLEANUP MODEL READY")
        }
    }

    /// Plain sentence for the status line and tab feedback.
    var detail: String {
        switch self {
        case .off:
            L10n.tr("As spoken. No cleanup.")
        case .needsRuntime:
            L10n.tr("This copy of YappYapp can't run cleanup. Reinstall it from the latest DMG. Until then, you get your words as spoken.")
        case .needsModel(let downloadsAllowed):
            downloadsAllowed
                ? L10n.tr("Needs the cleanup model (about %@ MB). Until then, you get your words as spoken.", "\(LLMCleaner.model.approximateSizeMB)")
                : L10n.tr("Needs the cleanup model, and downloads are off. Turn them on in Setup > App, or ask your IT admin for %@.", LLMCleaner.model.filename)
        case .downloading:
            L10n.tr("Downloading the cleanup model (about %@ MB). You get your words as spoken until it's done.", "\(LLMCleaner.model.approximateSizeMB)")
        case .verifying:
            L10n.tr("Verifying the cleanup model.")
        case .failed(let message):
            message
        case .ready:
            L10n.tr("Cleanup model ready.")
        }
    }

    var canDownload: Bool {
        switch self {
        case .needsModel(let downloadsAllowed): downloadsAllowed
        case .failed: true
        default: false
        }
    }

    var canCancel: Bool {
        if case .downloading = self { return true }
        return false
    }

    var progress: Double? {
        if case .downloading(let fraction) = self { return fraction }
        return nil
    }
}
