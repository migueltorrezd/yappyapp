import Foundation

/// Centralizes the permissions contract for local user data. YappYapp stores
/// configuration, glossary terms, and usage statistics under Application
/// Support; those files can reveal private vocabulary and work patterns even
/// though transcript history itself stays in memory.
enum PrivateFile {
    static let filePermissions = 0o600
    static let directoryPermissions = 0o700

    static func ensureDirectory(at url: URL, hardenExisting: Bool = true) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw CocoaError(.fileWriteFileExists)
            }
            if hardenExisting {
                try hardenDirectoryIfPresent(at: url)
            }
            return
        }

        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try hardenDirectoryIfPresent(at: url)
    }

    static func hardenDirectoryIfPresent(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.setAttributes(
            [.posixPermissions: directoryPermissions],
            ofItemAtPath: url.path
        )
    }

    static func write(_ data: Data, to url: URL) throws {
        // A store may be pointed at a caller-owned directory (for example an
        // isolated test root). Create and harden a missing parent, but never
        // chmod an existing parent whose ownership contract is not ours. The
        // application-support bootstrap explicitly hardens YappYapp's own
        // directories through `ensureDirectory(at:)`.
        try ensureDirectory(at: url.deletingLastPathComponent(), hardenExisting: false)
        try data.write(to: url, options: .atomic)
        try hardenFileIfPresent(at: url)
    }

    static func hardenFileIfPresent(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.setAttributes(
            [.posixPermissions: filePermissions],
            ofItemAtPath: url.path
        )
    }
}
