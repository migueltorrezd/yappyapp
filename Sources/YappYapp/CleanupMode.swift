import Foundation

// LLM-CLEANUP (missing feature 4): what the optional cleanup pass does to a
// transcript. Verbatim means off: the transcript is pasted as transcribed and
// the model never loads. Every other mode runs the local Qwen model through
// the bundled llama.cpp runtime. Other code (per-app profiles, for example)
// picks a mode and calls `LLMCleaner.cleanup(text:mode:)`.
enum CleanupMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case verbatim
    case clean
    case email
    case list
    case notes

    var id: String { rawValue }

    /// Whether the mode runs the local model at all.
    var usesModel: Bool { self != .verbatim }

    var label: String {
        switch self {
        case .verbatim: L10n.tr("AS SPOKEN")
        case .clean: L10n.tr("CLEAN")
        case .email: L10n.tr("EMAIL")
        case .list: L10n.tr("LIST")
        case .notes: L10n.tr("NOTES")
        }
    }

    /// CLEANUP-EXPLAINED: what cleanup is, in one breath, above the picker
    /// in SETUP and on the onboarding CLEANUP row.
    static var explainer: String {
        L10n.tr("Cleanup is optional. A small model on this Mac tidies what you said before it's pasted. Nothing leaves your Mac.")
    }

    /// One short line under the picker: what this mode really does (the
    /// rules in LLMCleaner+Modes and SelfCorrection, nothing more).
    var summary: String {
        switch self {
        case .verbatim:
            L10n.tr("No model. You get exactly what you said.")
        case .clean:
            L10n.tr("Removes um and uh, adds punctuation and capitals, applies \"no wait\" corrections. Keeps your words.")
        case .email:
            L10n.tr("Like CLEAN, then laid out as an email: short paragraphs, your greeting and sign-off on their own lines.")
        case .list:
            L10n.tr("Like CLEAN, then one item per line, each starting with a dash.")
        case .notes:
            L10n.tr("Short note lines, one idea each. Keeps every fact, name and number.")
        }
    }

    /// A tiny before and after: what you say, what gets pasted.
    var example: (said: String, written: String) {
        switch self {
        case .verbatim:
            (L10n.tr("um ship it Monday no wait Tuesday"), L10n.tr("um ship it Monday no wait Tuesday"))
        case .clean:
            (L10n.tr("um ship it Monday no wait Tuesday"), L10n.tr("Ship it Tuesday."))
        case .email:
            (L10n.tr("hi Sam the report is ready thanks Ana"), L10n.tr("Hi Sam,\nThe report is ready.\nThanks, Ana"))
        case .list:
            (L10n.tr("eggs um milk bread"), L10n.tr("- Eggs\n- Milk\n- Bread"))
        case .notes:
            (L10n.tr("so um the call moved to Friday at 3 with Lea"), L10n.tr("- Call moved to Friday at 3\n- With Lea"))
        }
    }

    /// Mode stored in config.json. Configs from before modes existed only
    /// carry the old on/off switch: on meant what Clean does now.
    static func resolve(stored: String?, legacyEnabled: Bool) -> CleanupMode {
        if let stored, let mode = CleanupMode(rawValue: stored) {
            return mode
        }
        return legacyEnabled ? .clean : .verbatim
    }
}

extension AppConfig {
    /// The effective cleanup mode. Setting it keeps the legacy `llmCleanup`
    /// flag in step, so older builds reading the same file stay consistent.
    var cleanup: CleanupMode {
        get { CleanupMode.resolve(stored: cleanupMode, legacyEnabled: llmCleanup) }
        set {
            cleanupMode = newValue.rawValue
            llmCleanup = newValue.usesModel
        }
    }
}

extension CleanupMode {
    /// HUD caption while the model runs.
    var hudNote: String {
        self == .clean ? L10n.tr("CLEANING UP") : L10n.tr("CLEANING UP · %@", label)
    }
}
