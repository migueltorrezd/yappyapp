import Foundation

// HELPER-BINARY-POLICY (YA-63): whisper-cli, whisper-server and llama-cli run
// as children of an app that holds Microphone and Accessibility grants, so
// they inherit that trust. Only run a helper that ships inside the app bundle
// or sits at an absolute path the user chose in Settings, and only when the
// file itself is safe: a real executable that nobody else can rewrite.

enum HelperBinarySource: Equatable, Sendable {
    /// Ships inside YappYapp.app.
    case appBundle
    /// An absolute path from config.json (Settings or the stock default).
    case userChosen
}

enum HelperBinaryRefusal: Equatable, Sendable {
    case empty
    case relativePath
    case parentTraversal
    case missing
    case notRegularFile
    case notExecutable
    case writableByOthers
    case untrustedOwner

    var reason: String {
        switch self {
        case .empty:
            L10n.tr("no path is set")
        case .relativePath:
            L10n.tr("relative paths are not allowed, use a full path")
        case .parentTraversal:
            L10n.tr("paths with .. are not allowed")
        case .missing:
            L10n.tr("nothing is there")
        case .notRegularFile:
            L10n.tr("it is not a file")
        case .notExecutable:
            L10n.tr("it is not executable")
        case .writableByOthers:
            L10n.tr("other users can modify it")
        case .untrustedOwner:
            L10n.tr("it belongs to another user")
        }
    }
}

enum HelperBinaryValidation: Equatable, Sendable {
    case allowed(path: String, source: HelperBinarySource)
    case refused(HelperBinaryRefusal)

    var allowedPath: String? {
        if case .allowed(let path, _) = self { return path }
        return nil
    }
}

/// File facts the policy needs. Injectable so tests never depend on the
/// host's real binaries.
struct HelperFileFacts: Equatable, Sendable {
    var exists: Bool
    var isRegularFile: Bool
    var isExecutable: Bool
    var posixPermissions: Int
    var ownerID: UInt32
}

enum HelperBinaryPolicy {
    /// Validates `configuredPath` for launch. The returned path keeps the
    /// user's spelling (symlinks such as Homebrew's bin/ links are fine), but
    /// the checks run on the file it resolves to.
    static func validate(
        _ configuredPath: String,
        bundleURL: URL? = Bundle.main.bundleURL,
        currentUserID: UInt32 = getuid(),
        facts: (String) -> HelperFileFacts? = HelperBinaryPolicy.fileFacts(atPath:)
    ) -> HelperBinaryValidation {
        let trimmed = configuredPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .refused(.empty) }

        let expanded = trimmed.expandingTildeInPath
        guard expanded.hasPrefix("/") else { return .refused(.relativePath) }
        guard !expanded.split(separator: "/").contains("..") else {
            return .refused(.parentTraversal)
        }

        let resolved = URL(fileURLWithPath: expanded).resolvingSymlinksInPath().path
        guard let info = facts(resolved), info.exists else { return .refused(.missing) }
        guard info.isRegularFile else { return .refused(.notRegularFile) }
        guard info.isExecutable else { return .refused(.notExecutable) }
        // Group- or world-writable means another account could swap the code.
        guard info.posixPermissions & 0o022 == 0 else { return .refused(.writableByOthers) }
        guard info.ownerID == 0 || info.ownerID == currentUserID else {
            return .refused(.untrustedOwner)
        }

        return .allowed(path: expanded, source: source(of: resolved, bundleURL: bundleURL))
    }

    /// Convenience for launch sites: the path to run, or nil to refuse.
    static func launchablePath(_ configuredPath: String) -> String? {
        let validation = validate(configuredPath)
        if case .refused(let refusal) = validation,
           refusal != .missing, refusal != .empty {
            FileHandle.standardError.write(Data(
                "YappYapp non-fatal: refused helper binary \(configuredPath): \(refusal.reason)\n".utf8
            ))
        }
        return validation.allowedPath
    }

    static func source(of resolvedPath: String, bundleURL: URL?) -> HelperBinarySource {
        guard let bundleURL, bundleURL.pathExtension == "app" else { return .userChosen }
        let bundlePath = bundleURL.resolvingSymlinksInPath().path
        return resolvedPath.hasPrefix(bundlePath + "/") ? .appBundle : .userChosen
    }

    static func fileFacts(atPath path: String) -> HelperFileFacts? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
            return nil
        }
        let type = attributes[.type] as? FileAttributeType
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        let owner = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value ?? UInt32.max
        return HelperFileFacts(
            exists: true,
            isRegularFile: type == .typeRegular,
            isExecutable: FileManager.default.isExecutableFile(atPath: path),
            posixPermissions: permissions,
            ownerID: owner
        )
    }
}

extension WhisperError {
    /// Missing when nothing is there, refused when something unsafe is.
    static func binaryProblem(for configuredPath: String) -> WhisperError {
        let display = configuredPath.expandingTildeInPath
        switch HelperBinaryPolicy.validate(configuredPath) {
        case .refused(let refusal) where refusal != .missing && refusal != .empty:
            return .binaryRefused(display, refusal.reason)
        default:
            return .binaryMissing(display)
        }
    }
}
