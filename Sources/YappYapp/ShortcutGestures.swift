import Foundation

// SHORTCUTS: pure state machines behind the global shortcuts. No AppKit, no
// Carbon, no clocks: every input carries its own timestamp so the self-tests
// can drive them with a fake clock.

/// YA-16: tells a key-repeat from a fresh press by event timestamps.
///
/// Carbon re-delivers "pressed" at the system key-repeat rate while a hot key
/// is held. The old self-heal asked the window server whether the key was
/// physically down, but that check runs while the user is already holding the
/// key for the NEW press, so the first real press after a lost release was
/// swallowed. Timing does not have that blind spot: a repeat arrives within
/// the repeat delay (first repeat) or the repeat interval (later repeats) of
/// the previous event. Anything slower is a fresh press after a lost release,
/// so it fires and the stale "down" flag heals itself.
struct HotKeyRepeatFilter {
    struct KeyState {
        var lastEventAt: TimeInterval
        var sawRepeat: Bool
    }

    /// Delay before the first repeat (NSEvent.keyRepeatDelay).
    var repeatDelay: TimeInterval
    /// Gap between later repeats (NSEvent.keyRepeatInterval).
    var repeatInterval: TimeInterval
    private(set) var downKeys: [UInt32: KeyState] = [:]

    init(repeatDelay: TimeInterval = 0.5, repeatInterval: TimeInterval = 0.083) {
        self.repeatDelay = repeatDelay
        self.repeatInterval = repeatInterval
    }

    /// Generous slack: the run loop can be late, never early. 1.5x plus 80ms
    /// still sits well below the time a human needs to lift and press again.
    func repeatWindow(afterRepeat: Bool) -> TimeInterval {
        let base = afterRepeat ? repeatInterval : repeatDelay
        return max(0.05, base) * 1.5 + 0.08
    }

    /// Returns true when this press should fire the shortcut.
    mutating func press(id: UInt32, at time: TimeInterval) -> Bool {
        guard let state = downKeys[id] else {
            downKeys[id] = KeyState(lastEventAt: time, sawRepeat: false)
            return true
        }

        let gap = time - state.lastEventAt
        if gap >= 0, gap <= repeatWindow(afterRepeat: state.sawRepeat) {
            downKeys[id] = KeyState(lastEventAt: time, sawRepeat: true)
            return false
        }

        // Too slow to be a repeat (or the clock went backwards): the release
        // was lost. Heal the flag and treat this as a fresh press.
        downKeys[id] = KeyState(lastEventAt: time, sawRepeat: false)
        return true
    }

    /// Returns true when the release matches a press we delivered.
    mutating func release(id: UInt32) -> Bool {
        downKeys.removeValue(forKey: id) != nil
    }

    mutating func forget(id: UInt32) {
        downKeys.removeValue(forKey: id)
    }

    mutating func reset() {
        downKeys.removeAll()
    }

    func isDown(_ id: UInt32) -> Bool {
        downKeys[id] != nil
    }
}

/// What the dictation shortcut asks the app to do.
enum DictationIntent: Equatable, Sendable {
    case start
    case stop
    case cancel
}

/// Maps press and release of the dictation trigger to start and stop for the
/// three recording modes. One machine per physical trigger (chord or modifier).
struct DictationGestureMachine {
    /// In hold mode a release sooner than this is a slip, not a dictation:
    /// the recording is thrown away instead of transcribing a click.
    static let minimumHold: TimeInterval = 0.2

    var mode: RecordingMode
    var hybridThreshold: TimeInterval

    /// When the current press started a recording, the time it went down.
    private(set) var pressStartedRecordingAt: TimeInterval?
    private(set) var isPressed = false

    init(mode: RecordingMode, hybridThreshold: TimeInterval = ShortcutSettings.defaultHybridThreshold) {
        self.mode = mode
        self.hybridThreshold = hybridThreshold
    }

    /// `isRecording` is the app's real state, so a recording started from the
    /// menu or the MIC button is stopped by the shortcut in every mode, and a
    /// lost release in hold mode is recovered by the next press.
    mutating func press(at time: TimeInterval, isRecording: Bool) -> DictationIntent? {
        isPressed = true
        if isRecording {
            pressStartedRecordingAt = nil
            return .stop
        }
        pressStartedRecordingAt = time
        return .start
    }

    mutating func release(at time: TimeInterval, isRecording: Bool) -> DictationIntent? {
        defer {
            isPressed = false
            pressStartedRecordingAt = nil
        }
        guard isPressed, let startedAt = pressStartedRecordingAt, isRecording else { return nil }

        switch mode {
        case .toggle:
            return nil
        case .hold:
            return time - startedAt < Self.minimumHold ? .cancel : .stop
        case .hybrid:
            // A tap latches the recording on; a hold ends it on release.
            return time - startedAt >= hybridThreshold ? .stop : nil
        }
    }

    /// Another key went down while a modifier-only trigger was held: the user
    /// is typing a shortcut, not dictating. Throw the fresh recording away.
    mutating func interrupt(isRecording: Bool) -> DictationIntent? {
        defer {
            isPressed = false
            pressStartedRecordingAt = nil
        }
        guard isPressed, pressStartedRecordingAt != nil, isRecording else { return nil }
        return .cancel
    }

    mutating func reset() {
        isPressed = false
        pressStartedRecordingAt = nil
    }
}

/// Edges reported by the modifier-only trigger.
enum ModifierHoldEdge: Equatable, Sendable {
    case pressed
    case released
    case interrupted
}

/// Turns raw flagsChanged / keyDown events into press, release and interrupt
/// edges for one modifier key held on its own.
struct ModifierHoldDetector {
    let key: ModifierHoldKey
    private(set) var isDown = false
    private(set) var wasInterrupted = false

    /// Device-independent modifier bits (NSEvent.ModifierFlags raw values).
    static let commandFlag: UInt64 = 1 << 20
    static let optionFlag: UInt64 = 1 << 19
    static let controlFlag: UInt64 = 1 << 18
    static let shiftFlag: UInt64 = 1 << 17
    static let functionFlag: UInt64 = 1 << 23

    init(key: ModifierHoldKey) {
        self.key = key
    }

    private var ownFlag: UInt64 {
        switch key {
        case .rightOption: Self.optionFlag
        case .rightCommand: Self.commandFlag
        case .rightControl: Self.controlFlag
        case .function: Self.functionFlag
        }
    }

    /// Other modifiers held together with ours mean a chord, not a hold.
    private func hasOtherModifiers(_ flags: UInt64) -> Bool {
        let all = Self.commandFlag | Self.optionFlag | Self.controlFlag | Self.shiftFlag | Self.functionFlag
        return flags & all & ~ownFlag != 0
    }

    mutating func flagsChanged(keyCode: UInt16, flags: UInt64) -> ModifierHoldEdge? {
        if keyCode == key.keyCode {
            let down = flags & key.deviceFlag != 0 || (key == .function && flags & Self.functionFlag != 0)
            if down, !isDown {
                isDown = true
                wasInterrupted = false
                return hasOtherModifiers(flags) ? interruptIfNeeded() : .pressed
            }
            if !down, isDown {
                isDown = false
                if wasInterrupted {
                    wasInterrupted = false
                    return nil
                }
                return .released
            }
            return nil
        }

        // A different modifier joined while ours is held: treat as a chord.
        if isDown, hasOtherModifiers(flags) {
            return interruptIfNeeded()
        }
        return nil
    }

    mutating func keyDown() -> ModifierHoldEdge? {
        guard isDown else { return nil }
        return interruptIfNeeded()
    }

    private mutating func interruptIfNeeded() -> ModifierHoldEdge? {
        guard !wasInterrupted else { return nil }
        wasInterrupted = true
        return .interrupted
    }

    mutating func reset() {
        isDown = false
        wasInterrupted = false
    }
}
