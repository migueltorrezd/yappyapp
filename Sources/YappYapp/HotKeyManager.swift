import AppKit
import Carbon
import Foundation

/// Carbon invokes the handler outside Swift's concurrency model. Mutable state
/// is registered and consumed on the main queue; the callback only transfers
/// the manager reference onto that queue.
final class HotKeyManager: @unchecked Sendable {
    private var handlerRef: EventHandlerRef?
    private var callbacks: [UInt32: () -> Void] = [:]
    // SHORTCUTS: optional release handlers for hold and hybrid modes.
    private var releaseCallbacks: [UInt32: () -> Void] = [:]
    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var nextID: UInt32 = 1
    // FIX(handlerStatus): false when InstallEventHandler failed. Registering a
    // hot key while the dispatcher is dead would succeed at the Carbon level but
    // never deliver an event, so register() refuses instead of lying.
    private var handlerInstalled = false
    // FIX(autorepeatRelease): repeat suppression is now RELEASE-based, not
    // time-based. Carbon re-delivers kEventHotKeyPressed at the system key-repeat
    // rate while a key is held; we fire only the FIRST press and swallow the rest
    // until kEventHotKeyReleased clears the pressed flag. The old 0.75s window
    // both under-suppressed (slow key-repeat delay can exceed 0.75s, so held
    // repeats leaked through) and over-suppressed (a legitimate fresh press
    // within 0.75s of a MISSED release was swallowed, indefinitely under
    // systematically dropped releases).
    // YA-16: a press that arrives while the id is still marked down is told
    // apart from a key-repeat by EVENT TIME, not by asking the window server
    // whether the key is physically down. The physical check ran while the user
    // held the key for the new press, so the first real press after a lost
    // release was swallowed. See HotKeyRepeatFilter.
    private var repeatFilter = HotKeyRepeatFilter()

    init() {
        installHandler()
    }

    deinit {
        unregisterAll()

        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
    }

    @discardableResult
    func registerOptionSpace(_ callback: @escaping () -> Void) -> UInt32? {
        register(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey), callback: callback)
    }

    @discardableResult
    func registerEscape(_ callback: @escaping () -> Void) -> UInt32? {
        register(keyCode: UInt32(kVK_Escape), modifiers: 0, callback: callback)
    }

    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32, callback: @escaping () -> Void) -> UInt32? {
        register(keyCode: keyCode, modifiers: modifiers, onPress: callback, onRelease: nil)
    }

    /// SHORTCUTS: registers a chord that reports both edges, for hold-to-talk.
    @discardableResult
    func register(chord: KeyChord, onPress: @escaping () -> Void, onRelease: (() -> Void)?) -> UInt32? {
        register(keyCode: chord.keyCode, modifiers: chord.modifiers, onPress: onPress, onRelease: onRelease)
    }

    @discardableResult
    private func register(
        keyCode: UInt32,
        modifiers: UInt32,
        onPress callback: @escaping () -> Void,
        onRelease: (() -> Void)?
    ) -> UInt32? {
        // FIX(handlerStatus): a hot key without a live dispatcher is silently
        // dead. Fail visibly instead of handing back a working-looking id.
        guard handlerInstalled else { return nil }

        let id = nextID
        nextID += 1

        let hotKeyID = EventHotKeyID(signature: fourCharCode("LFLW"), id: id)
        var hotKeyRef: EventHotKeyRef?

        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        guard status == noErr, let hotKeyRef else { return nil }

        // FIX(autorepeatRelease): defensively clear any stale pressed-state for
        // this id so a fresh registration can never inherit a wedged "held" flag.
        repeatFilter.forget(id: id)
        callbacks[id] = callback
        releaseCallbacks[id] = onRelease
        hotKeyRefs[id] = hotKeyRef
        return id
    }

    func unregister(id: UInt32) {
        if let hotKeyRef = hotKeyRefs.removeValue(forKey: id) {
            UnregisterEventHotKey(hotKeyRef)
        }
        callbacks.removeValue(forKey: id)
        releaseCallbacks.removeValue(forKey: id)
        // FIX(autorepeatRelease): drop pressed-state on unregister so a
        // re-registered id starts clean and a missed release can never survive
        // the cycle.
        repeatFilter.forget(id: id)
    }

    func unregisterAll() {
        for id in Array(hotKeyRefs.keys) {
            unregister(id: id)
        }
        repeatFilter.reset()
    }

    private func installHandler() {
        // FIX(autorepeatRelease): watch BOTH pressed and released so we can gate
        // the key-repeat storm Carbon emits while ⌥space is held. The release
        // clears the held-flag; a pressed event that arrives while the flag is
        // still set self-heals a MISSED release by its timestamp (YA-16, see
        // HotKeyRepeatFilter), so this cannot recreate the old stuck-hotkey
        // wedge nor the old time-window's leaked/swallowed presses.
        var eventTypes = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            ),
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyReleased)
            )
        ]

        let selfPointer = Unmanaged.passUnretained(self).toOpaque()

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let userData, let event else { return noErr }

                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )

                guard status == noErr else { return noErr }

                let manager = Unmanaged<HotKeyManager>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                let id = hotKeyID.id
                let eventKind = GetEventKind(event)
                // YA-16: the event's own timestamp (seconds since boot), taken
                // here so main-queue latency cannot blur repeat spacing.
                let eventTime = GetEventTime(event)

                // All pressed-state lives on main so the filter is single-threaded.
                if eventKind == UInt32(kEventHotKeyReleased) {
                    DispatchQueue.main.async {
                        if manager.repeatFilter.release(id: id) {
                            manager.releaseCallbacks[id]?()
                        }
                    }
                    return noErr
                }

                guard eventKind == UInt32(kEventHotKeyPressed) else {
                    return noErr
                }

                DispatchQueue.main.async {
                    // FIX(autorepeatRelease): fire only the FIRST press. While the
                    // key is held Carbon re-delivers kEventHotKeyPressed; the
                    // filter swallows every repeat that lands inside the system
                    // repeat window. YA-16: a press that comes slower than any
                    // repeat could is a fresh press after a lost release, so it
                    // fires and heals the stale flag instead of being swallowed.
                    manager.repeatFilter.repeatDelay = NSEvent.keyRepeatDelay
                    manager.repeatFilter.repeatInterval = NSEvent.keyRepeatInterval
                    guard manager.repeatFilter.press(id: id, at: eventTime) else { return }
                    manager.callbacks[id]?()
                }

                return noErr
            },
            eventTypes.count,
            &eventTypes,
            selfPointer,
            &handlerRef
        )

        // FIX(handlerStatus): remember whether the dispatcher actually installed
        // so register() can refuse to hand out silently-dead hot keys.
        handlerInstalled = (status == noErr)
        if !handlerInstalled {
            FileHandle.standardError.write(
                Data("YappYapp non-fatal: hotkey dispatcher install failed (OSStatus \(status))\n".utf8)
            )
        }
    }
}

private func fourCharCode(_ string: String) -> OSType {
    var result: OSType = 0

    for scalar in string.unicodeScalars.prefix(4) {
        result = (result << 8) + OSType(scalar.value)
    }

    return result
}
