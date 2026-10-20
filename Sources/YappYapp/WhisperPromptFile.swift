import Foundation

/// YA-49: the cold whisper-cli path never puts glossary terms or the extra
/// prompt in its arguments, where `ps` shows them to every local user. The
/// prompt goes in an owner-only file inside an owner-only folder, and only a
/// whisper-cli that understands `--prompt-file` (YappYapp's patched build,
/// see scripts/patches) receives it. Any other build runs without a prompt;
/// the glossary corrections still apply to its output afterwards.
enum WhisperPromptFile {
    static let flag = "--prompt-file"

    /// Writes `prompt` to a fresh private file and returns its URL, or nil
    /// for an empty prompt. The caller deletes it with `remove(_:)`.
    static func write(_ prompt: String, in directory: URL = FileManager.default.temporaryDirectory) throws -> URL? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let folder = directory.appendingPathComponent("yappyapp-prompt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: PrivateFile.directoryPermissions]
        )
        let url = folder.appendingPathComponent("prompt.txt")
        guard FileManager.default.createFile(
            atPath: url.path,
            contents: Data(trimmed.utf8),
            attributes: [.posixPermissions: PrivateFile.filePermissions]
        ) else {
            try? FileManager.default.removeItem(at: folder)
            throw CocoaError(.fileWriteUnknown)
        }
        return url
    }

    static func remove(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// Prompt arguments for whisper-cli. Never contains the prompt text.
    static func arguments(promptFile: URL?, binarySupportsPromptFile: Bool) -> [String] {
        guard let promptFile, binarySupportsPromptFile else { return [] }
        return [flag, promptFile.path]
    }

    static func helpAdvertisesPromptFile(_ helpOutput: String) -> Bool {
        helpOutput.contains(flag)
    }

    private static let supportCache = PromptFileSupportCache()

    /// Asks the binary's own help text whether it supports `--prompt-file`.
    /// Cached per path and modification date, so a rebuilt binary is
    /// probed again. Blocking; call it off the main thread.
    static func binarySupportsPromptFile(atPath path: String) -> Bool {
        let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
        let key = "\(path)|\(modified.timeIntervalSince1970)"
        if let cached = supportCache.value(for: key) { return cached }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--help"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        var supported = false
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            supported = helpAdvertisesPromptFile(String(data: data, encoding: .utf8) ?? "")
        } catch {
            supported = false
        }

        supportCache.set(supported, for: key)
        return supported
    }
}

private final class PromptFileSupportCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Bool] = [:]

    func value(for key: String) -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    func set(_ value: Bool, for key: String) {
        lock.lock()
        values[key] = value
        lock.unlock()
    }
}
