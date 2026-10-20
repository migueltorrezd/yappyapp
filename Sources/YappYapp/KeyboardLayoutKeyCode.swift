import Carbon
import CoreGraphics
import Foundation

/// YA-59: the synthetic paste must press the key that types "v" on the
/// user's current layout, not the ANSI position. On Dvorak the ANSI V key
/// types "k", so a hardcoded 0x09 sends Cmd+K.
enum KeyboardLayoutKeyCode {
    static let ansiV: CGKeyCode = 0x09

    /// Scans every virtual key and returns the first one the translator maps
    /// to `character`. Pure so the self-tests can feed a fake layout.
    static func keyCode(for character: Character, translate: (CGKeyCode) -> String?) -> CGKeyCode? {
        let wanted = String(character).lowercased()
        for code in 0..<128 {
            let keyCode = CGKeyCode(code)
            if translate(keyCode)?.lowercased() == wanted {
                return keyCode
            }
        }
        return nil
    }

    /// The key that produces "v" while Command is held on the current layout.
    /// Translating with Command down matters for layouts such as
    /// "Dvorak - QWERTY Cmd", whose shortcuts stay on the QWERTY positions.
    static func commandVKeyCode() -> CGKeyCode {
        guard let translate = currentLayoutTranslator(commandHeld: true) else { return ansiV }
        return keyCode(for: "v", translate: translate) ?? ansiV
    }

    static func currentLayoutTranslator(commandHeld: Bool) -> ((CGKeyCode) -> String?)? {
        guard let layoutData = currentLayoutData() else { return nil }
        let modifierState: UInt32 = commandHeld ? UInt32((cmdKey >> 8) & 0xFF) : 0
        let keyboardType = UInt32(LMGetKbdType())

        return { keyCode in
            layoutData.withUnsafeBytes { raw -> String? in
                guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                    return nil
                }
                var deadKeyState: UInt32 = 0
                var characters = [UniChar](repeating: 0, count: 4)
                var length = 0
                let status = UCKeyTranslate(
                    layout,
                    UInt16(keyCode),
                    UInt16(kUCKeyActionDown),
                    modifierState,
                    keyboardType,
                    OptionBits(kUCKeyTranslateNoDeadKeysBit),
                    &deadKeyState,
                    characters.count,
                    &length,
                    &characters
                )
                guard status == noErr, length > 0 else { return nil }
                return String(utf16CodeUnits: characters, count: length)
            }
        }
    }

    private static func currentLayoutData() -> Data? {
        if let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
           let data = layoutData(of: source) {
            return data
        }
        // Input methods (Japanese, Chinese) have no Unicode layout data; their
        // ASCII-capable companion layout decides what Cmd+V means.
        if let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue() {
            return layoutData(of: source)
        }
        return nil
    }

    private static func layoutData(of source: TISInputSource) -> Data? {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
        return data as Data
    }
}
