import Carbon
import Foundation

// SHORTCUTS: persisted shortcut configuration. Every field decodes leniently so
// an older config.json (no "shortcuts" key) or a partial one written by a newer
// build still loads, and the defaults reproduce the shipped behavior exactly:
// Option+Space toggles dictation, Esc cancels while recording.

/// What a global shortcut does.
enum ShortcutAction: String, Codable, CaseIterable, Sendable, Identifiable {
    case toggleDictation
    case pasteLast
    case retryLast
    // COMMANDS: removes the last dictation from the app it went into.
    case undoLast
    case cancel

    var id: String { rawValue }

    var title: String {
        switch self {
        case .toggleDictation: L10n.tr("DICTATE")
        case .pasteLast: L10n.tr("PASTE LAST")
        case .retryLast: L10n.tr("RETRY LAST")
        case .undoLast: L10n.tr("UNDO LAST")
        case .cancel: L10n.tr("CANCEL")
        }
    }

    var detail: String {
        switch self {
        case .toggleDictation: L10n.tr("Starts and stops dictation from any app.")
        case .pasteLast: L10n.tr("Pastes your last dictation again at the cursor.")
        case .retryLast: L10n.tr("Transcribes your last dictation again.")
        case .undoLast: L10n.tr("Removes your last pasted text from the app.")
        case .cancel: L10n.tr("Active only while you dictate, so the key works as usual the rest of the time.")
        }
    }

    /// Cancel is grabbed only while a recording runs, so a bare key (Esc) is
    /// fine there. Every other action is grabbed system-wide all the time.
    var isAlwaysRegistered: Bool { self != .cancel }

    /// SETUP > SHORTCUTS shows these rows up front.
    static let primaryInSetup: [ShortcutAction] = [.toggleDictation, .cancel]
    /// SETUP > SHORTCUTS keeps these behind MORE SHORTCUTS.
    static let moreInSetup: [ShortcutAction] = [.pasteLast, .retryLast, .undoLast]
}

/// How the dictation shortcut maps presses to start and stop.
enum RecordingMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case toggle
    case hold
    case hybrid

    var id: String { rawValue }

    var chipLabel: String {
        switch self {
        case .toggle: L10n.tr("PRESS")
        case .hold: L10n.tr("HOLD")
        case .hybrid: L10n.tr("BOTH")
        }
    }

    var explanation: String {
        switch self {
        case .toggle: L10n.tr("Press to start, press again to stop.")
        case .hold: L10n.tr("Hold to talk, release to stop.")
        case .hybrid: L10n.tr("Tap to start and stop, or hold and release.")
        }
    }

    /// The MIC tab headline (YA-71: never claim push to talk on a toggle).
    var headline: String {
        switch self {
        case .toggle: L10n.tr("PRESS TO TALK")
        case .hold: L10n.tr("HOLD TO TALK")
        case .hybrid: L10n.tr("TAP OR HOLD")
        }
    }
}

/// A key plus Carbon modifier flags (cmdKey, optionKey, controlKey, shiftKey).
struct KeyChord: Codable, Equatable, Hashable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let optionSpace = KeyChord(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey))
    static let escape = KeyChord(keyCode: UInt32(kVK_Escape), modifiers: 0)

    static let modifierMask = UInt32(cmdKey | optionKey | controlKey | shiftKey)

    var normalized: KeyChord {
        KeyChord(keyCode: keyCode, modifiers: modifiers & Self.modifierMask)
    }

    var hasCommand: Bool { modifiers & UInt32(cmdKey) != 0 }
    var hasOption: Bool { modifiers & UInt32(optionKey) != 0 }
    var hasControl: Bool { modifiers & UInt32(controlKey) != 0 }
    var hasShift: Bool { modifiers & UInt32(shiftKey) != 0 }
}

/// A modifier key that can act alone as a hold-to-talk trigger.
enum ModifierHoldKey: String, Codable, CaseIterable, Sendable, Identifiable {
    case rightOption
    case rightCommand
    case rightControl
    case function

    var id: String { rawValue }

    var chipLabel: String {
        switch self {
        case .rightOption: L10n.tr("RIGHT ⌥")
        case .rightCommand: L10n.tr("RIGHT ⌘")
        case .rightControl: L10n.tr("RIGHT ⌃")
        case .function: L10n.tr("FN")
        }
    }

    var spokenName: String {
        switch self {
        case .rightOption: L10n.tr("Right Option")
        case .rightCommand: L10n.tr("Right Command")
        case .rightControl: L10n.tr("Right Control")
        case .function: L10n.tr("Fn")
        }
    }

    /// Virtual key code reported in the flagsChanged event for this key.
    var keyCode: UInt16 {
        switch self {
        case .rightOption: UInt16(kVK_RightOption)
        case .rightCommand: UInt16(kVK_RightCommand)
        case .rightControl: UInt16(kVK_RightControl)
        case .function: UInt16(kVK_Function)
        }
    }

    /// Device-dependent bit (IOLLEvent NX_DEVICER*KEYMASK) or, for Fn, the
    /// secondary-fn flag. Tells this exact key apart from its left twin.
    var deviceFlag: UInt64 {
        switch self {
        case .rightOption: 0x0000_0040
        case .rightCommand: 0x0000_0010
        case .rightControl: 0x0000_2000
        case .function: 0x0080_0000
        }
    }
}

struct ShortcutBinding: Codable, Equatable, Sendable {
    var action: ShortcutAction
    var chord: KeyChord?
}

struct ShortcutSettings: Codable, Equatable, Sendable {
    static let defaultHybridThreshold: Double = 0.3

    var mode: RecordingMode
    var bindings: [ShortcutBinding]
    /// Opt-in modifier-only trigger. nil keeps the old behavior.
    var modifierHold: ModifierHoldKey?
    var hybridThreshold: Double

    init(
        mode: RecordingMode = .toggle,
        bindings: [ShortcutBinding] = ShortcutSettings.defaultBindings,
        modifierHold: ModifierHoldKey? = nil,
        hybridThreshold: Double = ShortcutSettings.defaultHybridThreshold
    ) {
        self.mode = mode
        self.bindings = Self.normalizedBindings(bindings)
        self.modifierHold = modifierHold
        self.hybridThreshold = hybridThreshold
    }

    static let defaultBindings: [ShortcutBinding] = [
        ShortcutBinding(action: .toggleDictation, chord: .optionSpace),
        ShortcutBinding(action: .pasteLast, chord: nil),
        ShortcutBinding(action: .retryLast, chord: nil),
        ShortcutBinding(action: .undoLast, chord: nil),
        ShortcutBinding(action: .cancel, chord: .escape)
    ]

    static let `default` = ShortcutSettings()

    private enum CodingKeys: String, CodingKey {
        case mode, bindings, modifierHold, hybridThreshold
    }

    /// Unknown actions or modes from a newer build are skipped, not fatal.
    private struct LossyBinding: Decodable {
        let value: ShortcutBinding?

        init(from decoder: Decoder) throws {
            value = try? ShortcutBinding(from: decoder)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawMode = try? container.decodeIfPresent(String.self, forKey: .mode)
        mode = rawMode.flatMap { RecordingMode(rawValue: $0) } ?? .toggle
        let decoded = (try? container.decodeIfPresent([LossyBinding].self, forKey: .bindings)) ?? nil
        bindings = Self.normalizedBindings(decoded?.compactMap(\.value) ?? Self.defaultBindings)
        let rawHold = try? container.decodeIfPresent(String.self, forKey: .modifierHold)
        modifierHold = rawHold.flatMap { ModifierHoldKey(rawValue: $0) }
        let threshold = (try? container.decodeIfPresent(Double.self, forKey: .hybridThreshold)) ?? nil
        hybridThreshold = Self.clampedThreshold(threshold ?? Self.defaultHybridThreshold)
    }

    static func clampedThreshold(_ value: Double) -> Double {
        guard value.isFinite else { return defaultHybridThreshold }
        return min(1.0, max(0.15, value))
    }

    /// Exactly one binding per action, in canonical order. A missing action
    /// gets its default; a duplicate keeps the first entry.
    static func normalizedBindings(_ bindings: [ShortcutBinding]) -> [ShortcutBinding] {
        ShortcutAction.allCases.map { action in
            if let existing = bindings.first(where: { $0.action == action }) {
                return ShortcutBinding(action: action, chord: existing.chord?.normalized)
            }
            return defaultBindings.first(where: { $0.action == action })
                ?? ShortcutBinding(action: action, chord: nil)
        }
    }

    func chord(for action: ShortcutAction) -> KeyChord? {
        bindings.first(where: { $0.action == action })?.chord
    }

    mutating func setChord(_ chord: KeyChord?, for action: ShortcutAction) {
        bindings = Self.normalizedBindings(bindings.map { binding in
            binding.action == action ? ShortcutBinding(action: action, chord: chord?.normalized) : binding
        })
    }
}

extension ShortcutSettings {
    /// SETUP has one cancel control. Cancel works only while the stored
    /// `escCancelsRecording` switch is on and a cancel chord is bound
    /// (AppDelegate.registerEscapeToCancel, BrutalHUDView), so an off switch
    /// shows as NOT SET.
    func effectiveCancelChord(cancelEnabled: Bool) -> KeyChord? {
        cancelEnabled ? chord(for: .cancel) : nil
    }

    /// The bindings as they behave: a switched-off cancel chord claims no keys.
    func effective(cancelEnabled: Bool) -> ShortcutSettings {
        guard !cancelEnabled else { return self }
        var copy = self
        copy.setChord(nil, for: .cancel)
        return copy
    }

    /// Whether MORE SHORTCUTS starts open: any of its rows already has keys.
    var hasMoreShortcutsSet: Bool {
        ShortcutAction.moreInSetup.contains { chord(for: $0) != nil }
    }
}
