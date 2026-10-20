import AppKit
import Carbon
import Foundation

// SHORTCUTS: human labels and validation for recorded chords. Pure logic so the
// self-test suite can cover every rule without touching real hot keys.

enum ShortcutKeyNames {
    /// Labels for keys whose name does not depend on the keyboard layout. Letter
    /// and digit keys use the ANSI positions, which is what Carbon registers.
    private static let names: [Int: String] = [
        kVK_Space: "SPACE", kVK_Return: "RETURN", kVK_Tab: "TAB", kVK_Escape: "ESC",
        kVK_Delete: "DELETE", kVK_ForwardDelete: "FWD DEL", kVK_Home: "HOME", kVK_End: "END",
        kVK_PageUp: "PG UP", kVK_PageDown: "PG DN", kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Help: "HELP",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
        kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E",
        kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J",
        kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O",
        kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y",
        kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
        kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[",
        kVK_ANSI_RightBracket: "]", kVK_ANSI_Backslash: "\\", kVK_ANSI_Semicolon: ";",
        kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/",
        kVK_ANSI_Grave: "`"
    ]

    static let functionKeyCodes: Set<Int> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20
    ]

    /// Keys that type a character (or whitespace) when pressed with no
    /// modifier or with Shift only.
    static func typesCharacter(_ keyCode: UInt32) -> Bool {
        let code = Int(keyCode)
        if functionKeyCodes.contains(code) { return false }
        let nonTyping: Set<Int> = [
            kVK_Escape, kVK_Delete, kVK_ForwardDelete, kVK_Home, kVK_End, kVK_PageUp,
            kVK_PageDown, kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow, kVK_Help
        ]
        return !nonTyping.contains(code)
    }

    static func keyName(_ keyCode: UInt32) -> String {
        names[Int(keyCode)].map(L10n.tr) ?? L10n.tr("KEY %@", "\(keyCode)")
    }

    /// Keycaps in macOS order: ⌃ ⌥ ⇧ ⌘, then the key.
    static func keycaps(for chord: KeyChord) -> [String] {
        var caps: [String] = []
        if chord.hasControl { caps.append("⌃") }
        if chord.hasOption { caps.append("⌥") }
        if chord.hasShift { caps.append("⇧") }
        if chord.hasCommand { caps.append("⌘") }
        caps.append(keyName(chord.keyCode))
        return caps
    }

    /// Short inline form used in status lines, e.g. "⌥ space".
    static func inlineLabel(for chord: KeyChord) -> String {
        let caps = keycaps(for: chord)
        let modifiers = caps.dropLast().joined()
        let key = keyName(chord.keyCode).lowercased()
        return modifiers.isEmpty ? key : "\(modifiers) \(key)"
    }

    /// Spoken form for VoiceOver, e.g. "Option Space".
    static func spokenLabel(for chord: KeyChord) -> String {
        var words: [String] = []
        if chord.hasControl { words.append(L10n.tr("Control")) }
        if chord.hasOption { words.append(L10n.tr("Option")) }
        if chord.hasShift { words.append(L10n.tr("Shift")) }
        if chord.hasCommand { words.append(L10n.tr("Command")) }
        words.append(keyName(chord.keyCode).capitalized)
        return words.joined(separator: " ")
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    static func eventModifiers(from carbon: UInt32) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbon & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if carbon & UInt32(optionKey) != 0 { flags.insert(.option) }
        if carbon & UInt32(controlKey) != 0 { flags.insert(.control) }
        if carbon & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        return flags
    }

    /// NSMenuItem keyEquivalent string for display in the status menu. nil
    /// when the key has no printable equivalent we can show.
    /// Shows a chord on a status menu item, or clears it when there is none.
    @MainActor
    static func decorate(_ item: NSMenuItem, with chord: KeyChord?) {
        guard let chord, let key = menuKeyEquivalent(for: chord) else {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
            return
        }
        item.keyEquivalent = key
        item.keyEquivalentModifierMask = eventModifiers(from: chord.modifiers)
    }

    static func menuKeyEquivalent(for chord: KeyChord) -> String? {
        switch Int(chord.keyCode) {
        case kVK_Space: return " "
        case kVK_Return: return "\r"
        case kVK_Tab: return "\t"
        case kVK_Escape: return "\u{1B}"
        default:
            if let name = names[Int(chord.keyCode)], name.count == 1 {
                return name.lowercased()
            }
            return nil
        }
    }
}

enum ShortcutValidation: Equatable {
    case accepted(warnings: [String])
    case rejected(String)

    var isAccepted: Bool {
        if case .accepted = self { return true }
        return false
    }

    var message: String? {
        switch self {
        case .accepted(let warnings): warnings.first
        case .rejected(let reason): reason
        }
    }
}

enum ShortcutValidator {
    private struct Reserved {
        let chord: KeyChord
        let owner: String
    }

    private static func chord(_ key: Int, _ modifiers: Int) -> KeyChord {
        KeyChord(keyCode: UInt32(key), modifiers: UInt32(modifiers))
    }

    /// Combos macOS or every app already owns. Registering them would either
    /// fail or steal a shortcut people use all day.
    private static let reserved: [Reserved] = [
        Reserved(chord: chord(kVK_Space, cmdKey), owner: "Spotlight"),
        Reserved(chord: chord(kVK_Space, controlKey), owner: "the input source switcher"),
        Reserved(chord: chord(kVK_Space, cmdKey | optionKey), owner: "Finder search"),
        Reserved(chord: chord(kVK_Space, controlKey | cmdKey), owner: "the emoji picker"),
        Reserved(chord: chord(kVK_Tab, cmdKey), owner: "the app switcher"),
        Reserved(chord: chord(kVK_ANSI_Q, cmdKey), owner: "Quit"),
        Reserved(chord: chord(kVK_ANSI_W, cmdKey), owner: "Close Window"),
        Reserved(chord: chord(kVK_ANSI_H, cmdKey), owner: "Hide"),
        Reserved(chord: chord(kVK_ANSI_M, cmdKey), owner: "Minimize"),
        Reserved(chord: chord(kVK_ANSI_C, cmdKey), owner: "Copy"),
        Reserved(chord: chord(kVK_ANSI_V, cmdKey), owner: "Paste"),
        Reserved(chord: chord(kVK_ANSI_X, cmdKey), owner: "Cut"),
        Reserved(chord: chord(kVK_ANSI_Z, cmdKey), owner: "Undo"),
        Reserved(chord: chord(kVK_ANSI_A, cmdKey), owner: "Select All"),
        Reserved(chord: chord(kVK_ANSI_S, cmdKey), owner: "Save"),
        Reserved(chord: chord(kVK_ANSI_3, cmdKey | shiftKey), owner: "screenshots"),
        Reserved(chord: chord(kVK_ANSI_4, cmdKey | shiftKey), owner: "screenshots"),
        Reserved(chord: chord(kVK_ANSI_5, cmdKey | shiftKey), owner: "screenshots"),
        Reserved(chord: chord(kVK_Escape, cmdKey | optionKey), owner: "Force Quit")
    ]

    /// Combos that work but collide with popular apps or with typing.
    private static let knownCollisions: [Reserved] = [
        Reserved(
            chord: chord(kVK_Space, optionKey),
            owner: "Alfred, Raycast and ChatGPT by default, and it types a non-breaking space on French layouts"
        ),
        Reserved(chord: chord(kVK_Space, cmdKey | shiftKey), owner: "some launchers and the ChatGPT app"),
        Reserved(chord: chord(kVK_Space, controlKey | optionKey), owner: "the previous input source switcher")
    ]

    /// Validates a chord for an action against the other current bindings.
    static func validate(
        _ candidate: KeyChord,
        for action: ShortcutAction,
        in settings: ShortcutSettings
    ) -> ShortcutValidation {
        let chord = candidate.normalized
        let name = ShortcutKeyNames.spokenLabel(for: chord)

        if chord.keyCode == UInt32(kVK_Escape), chord.modifiers == 0, action != .cancel {
            return .rejected(L10n.tr("Esc alone is kept for canceling. Add ⌘, ⌥ or ⌃."))
        }

        let isFunctionKey = ShortcutKeyNames.functionKeyCodes.contains(Int(chord.keyCode))
        let hasRealModifier = chord.hasCommand || chord.hasOption || chord.hasControl
        if action.isAlwaysRegistered, !isFunctionKey, !hasRealModifier {
            if ShortcutKeyNames.typesCharacter(chord.keyCode) {
                return .rejected(L10n.tr("%@ would block typing. Add ⌘, ⌥ or ⌃.", name))
            }
            return .rejected(L10n.tr("%@ alone is too easy to hit. Add ⌘, ⌥ or ⌃.", name))
        }

        if let reserved = reserved.first(where: { $0.chord == chord }) {
            return .rejected(L10n.tr("%@ belongs to %@. Pick another.", name, L10n.tr(reserved.owner)))
        }

        if let clash = settings.bindings.first(where: { $0.action != action && $0.chord?.normalized == chord }) {
            return .rejected(L10n.tr("%@ is already used for %@. Pick another.", name, clash.action.title.lowercased()))
        }

        var warnings: [String] = []
        if let collision = knownCollisions.first(where: { $0.chord == chord }) {
            warnings.append(L10n.tr("%@ is also used by %@.", name, L10n.tr(collision.owner)))
        }
        let optionTypes = chord.hasOption && !chord.hasCommand && !chord.hasControl
            && ShortcutKeyNames.typesCharacter(chord.keyCode)
            && chord.keyCode != UInt32(kVK_Space)
        if optionTypes {
            warnings.append(L10n.tr("%@ types an accent or symbol on many layouts. You will lose that character.", name))
        }
        return .accepted(warnings: warnings)
    }

    /// Advisory for the modifier-only trigger.
    static func modifierHoldNote(_ key: ModifierHoldKey) -> String {
        switch key {
        case .function:
            L10n.tr("Set \"Press Globe key to\" to Do Nothing in Keyboard settings, or macOS opens its own menu too.")
        case .rightOption:
            L10n.tr("Right ⌥ plus a letter still types accents. Pressing another key cancels the dictation.")
        case .rightCommand, .rightControl:
            L10n.tr("Pressing another key while holding it cancels the dictation, so shortcuts keep working.")
        }
    }
}
