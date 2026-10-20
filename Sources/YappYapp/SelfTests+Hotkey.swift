#if DEBUG
import AppKit
import Carbon
import Foundation
import SwiftUI

// Self-tests owned by the "hotkey" work track. Keep this track's new
// assertions here so parallel tracks never edit the same test lines.
//
// Everything here runs on fakes: no Carbon hot key is registered, no event
// monitor is installed and no pasteboard is touched. Time comes from a fake
// clock passed to each state machine.
extension SelfTests {
    static func hotkeyTrackTests() {
        hotkeyIntegrationTests()
        hotkeyRepeatFilterTests()
        hotkeyGestureTests()
        hotkeyModifierDetectorTests()
        hotkeySettingsTests()
        hotkeyValidationTests()
        hotkeyCoordinatorTests()
        hotkeyCopyTests()
        hotkeyPasteLastTests()
        hotkeyRenderTests()
    }

    /// Wave 1 merge: shortcuts meet YA-72 (dead shortcut), YA-19 (optional
    /// Esc) and YA-05 (retry).
    private static func hotkeyIntegrationTests() {
        test("hotkeyIntegration.unavailableOnlyWithoutAnotherTrigger") {
            var settings = ShortcutSettings.default
            expect(HotkeyAvailability.isUnavailable(settings: settings, failed: [.toggleDictation]), "a dead dictation chord is unavailable")
            expect(!HotkeyAvailability.isUnavailable(settings: settings, failed: [.pasteLast]), "a paste-last failure keeps dictation reachable")
            settings.modifierHold = .rightOption
            expect(!HotkeyAvailability.isUnavailable(settings: settings, failed: [.toggleDictation]), "the one-key trigger still works")
        }

        test("hotkeyIntegration.listeningStatusFollowsEscSetting") {
            let settings = ShortcutSettings.default
            expect(ShortcutCopy.listeningStatus(settings).contains("to cancel"), "Esc on names the cancel key")
            expect(!ShortcutCopy.listeningStatus(settings, cancelEnabled: false).contains("cancel"), "Esc off never offers cancel")
            expect(!HotkeyStatusCopy.listeningStatus(hotkeyAvailable: true, escCancels: false).lowercased().contains("esc"), "no esc when it is off")
            expectEqual(ShortcutCopy.listeningStatus(settings), "Listening. Press ⌥ space to stop, Esc to cancel.", "Esc reads as a key name")
            expect(HotkeyStatusCopy.listeningStatus(hotkeyAvailable: false, escCancels: true).contains("Esc to cancel"), "Esc still offered")
        }

        test("hotkeyIntegration.deadShortcutCopyNamesTheRealShortcut") {
            var settings = ShortcutSettings.default
            settings.modifierHold = .rightCommand
            settings.bindings = settings.bindings.map { binding in
                var copy = binding
                if copy.action == .toggleDictation { copy.chord = nil }
                return copy
            }
            let detail = ShortcutCopy.personalize(HotkeyStatusCopy.unavailableDetail, settings)
            expect(!detail.contains("⌥ space"), "a rebound user never reads the old shortcut: \(detail)")
        }
    }

    // MARK: - YA-16 repeat filter

    private static func hotkeyRepeatFilterTests() {
        test("hotkey.repeatFilter.firstPressAndRepeats") {
            var filter = HotKeyRepeatFilter(repeatDelay: 0.5, repeatInterval: 0.083)
            expect(filter.press(id: 1, at: 10.0), "first press fires")
            expect(!filter.press(id: 1, at: 10.5), "first repeat after the delay is swallowed")
            var time = 10.5
            for _ in 0..<40 {
                time += 0.083
                expect(!filter.press(id: 1, at: time), "steady repeats are swallowed")
            }
            expect(filter.release(id: 1), "release matches a delivered press")
            expect(!filter.isDown(1), "release clears the down flag")
            expect(filter.press(id: 1, at: time + 0.2), "the next press after a release fires")
        }

        test("hotkey.repeatFilter.lostReleaseFirstRealPressFires") {
            // YA-16: the release for the first press never arrives. The user
            // lets go and presses again a second later. That first real
            // press must fire, not be swallowed while the key is held.
            var filter = HotKeyRepeatFilter(repeatDelay: 0.5, repeatInterval: 0.083)
            expect(filter.press(id: 7, at: 100.0), "first press fires")
            expect(!filter.press(id: 7, at: 100.5), "repeat swallowed")
            expect(!filter.press(id: 7, at: 100.583), "repeat swallowed")
            expect(filter.isDown(7), "lost release leaves the flag set")
            expect(filter.press(id: 7, at: 101.6), "fresh press after a lost release fires at once")
            expect(!filter.press(id: 7, at: 102.1), "its own repeats are still swallowed (self-heal kept)")
            // Releases lost every time: each fresh press still fires.
            expect(filter.press(id: 7, at: 104.0), "second lost release, press fires")
            expect(filter.press(id: 7, at: 106.0), "third lost release, press fires")
        }

        test("hotkey.repeatFilter.windowAndEdges") {
            var filter = HotKeyRepeatFilter(repeatDelay: 0.5, repeatInterval: 0.083)
            let firstWindow = filter.repeatWindow(afterRepeat: false)
            let laterWindow = filter.repeatWindow(afterRepeat: true)
            expect(firstWindow > 0.5 && firstWindow < 1.0, "first repeat window covers the delay with slack, got \(firstWindow)")
            expect(laterWindow > 0.083 && laterWindow < 0.3, "later window covers the interval with slack, got \(laterWindow)")

            expect(filter.press(id: 2, at: 5.0), "press fires")
            expect(filter.press(id: 2, at: 4.0), "clock going backwards counts as fresh, never wedges")
            filter.forget(id: 2)
            expect(!filter.isDown(2), "forget clears the id")
            expect(!filter.release(id: 2), "release of an unknown id reports false")

            expect(filter.press(id: 3, at: 1.0), "id 3 fires")
            expect(filter.press(id: 4, at: 1.01), "ids are independent")
            filter.reset()
            expect(!filter.isDown(3) && !filter.isDown(4), "reset clears every id")

            // A slow repeat delay (the slowest System Settings value) still
            // swallows its first repeat: the window tracks the live setting.
            var slow = HotKeyRepeatFilter(repeatDelay: 2.0, repeatInterval: 0.5)
            expect(slow.press(id: 9, at: 0), "press fires")
            expect(!slow.press(id: 9, at: 2.05), "slow first repeat swallowed")
            expect(!slow.press(id: 9, at: 2.6), "slow later repeat swallowed")
        }
    }

    // MARK: - Recording modes

    private static func hotkeyGestureTests() {
        test("hotkey.gesture.toggle") {
            var machine = DictationGestureMachine(mode: .toggle)
            expectEqual(machine.press(at: 0, isRecording: false), .start)
            expectEqual(machine.release(at: 2, isRecording: true), nil, "toggle ignores release")
            expectEqual(machine.press(at: 5, isRecording: true), .stop)
            expectEqual(machine.release(at: 5.1, isRecording: false), nil)
        }

        test("hotkey.gesture.hold") {
            var machine = DictationGestureMachine(mode: .hold)
            expectEqual(machine.press(at: 0, isRecording: false), .start)
            expectEqual(machine.release(at: 1.5, isRecording: true), .stop, "release stops")
            expectEqual(machine.press(at: 3, isRecording: false), .start)
            expectEqual(machine.release(at: 3.05, isRecording: true), .cancel, "a slip shorter than minimumHold is thrown away")
            // Lost release in hold mode: the next press stops the recording.
            expectEqual(machine.press(at: 10, isRecording: false), .start)
            expectEqual(machine.press(at: 20, isRecording: true), .stop, "next press recovers a lost release")
            expectEqual(machine.release(at: 20.1, isRecording: false), nil, "its release does nothing")
            // Recording started from the MIC button: release without a press.
            expectEqual(machine.release(at: 30, isRecording: true), nil, "release without our press is ignored")
            // Start failed (prerequisite missing): release does nothing.
            expectEqual(machine.press(at: 40, isRecording: false), .start)
            expectEqual(machine.release(at: 41, isRecording: false), nil)
        }

        test("hotkey.gesture.hybrid") {
            var machine = DictationGestureMachine(mode: .hybrid, hybridThreshold: 0.3)
            expectEqual(machine.press(at: 0, isRecording: false), .start)
            expectEqual(machine.release(at: 0.12, isRecording: true), nil, "tap latches the recording")
            expectEqual(machine.press(at: 4, isRecording: true), .stop, "second tap stops")
            expectEqual(machine.release(at: 4.1, isRecording: false), nil)

            expectEqual(machine.press(at: 10, isRecording: false), .start)
            expectEqual(machine.release(at: 12, isRecording: true), .stop, "hold acts as push to talk")

            expectEqual(machine.press(at: 20, isRecording: false), .start)
            expectEqual(machine.release(at: 20.3, isRecording: true), .stop, "threshold itself counts as a hold")
            expectEqual(machine.press(at: 30, isRecording: false), .start)
            expectEqual(machine.release(at: 30.299, isRecording: true), nil, "just under the threshold is a tap")
        }

        test("hotkey.gesture.interrupt") {
            var machine = DictationGestureMachine(mode: .hold)
            expectEqual(machine.press(at: 0, isRecording: false), .start)
            expectEqual(machine.interrupt(isRecording: true), .cancel, "typing a shortcut cancels the fresh recording")
            expectEqual(machine.release(at: 1, isRecording: false), nil, "release after the interrupt is inert")
            expectEqual(machine.interrupt(isRecording: true), nil, "no interrupt without a press")
            expectEqual(machine.press(at: 5, isRecording: true), .stop)
            expectEqual(machine.interrupt(isRecording: false), nil, "a stopping press is never turned into a cancel")
        }
    }

    // MARK: - Modifier-only trigger

    private static func hotkeyModifierDetectorTests() {
        let option = ModifierHoldDetector.optionFlag
        let command = ModifierHoldDetector.commandFlag

        test("hotkey.modifier.rightOption") {
            var detector = ModifierHoldDetector(key: .rightOption)
            expectEqual(detector.flagsChanged(keyCode: UInt16(kVK_RightOption), flags: option | 0x40), .pressed)
            expectEqual(detector.flagsChanged(keyCode: UInt16(kVK_RightOption), flags: 0), .released)
            expectEqual(detector.flagsChanged(keyCode: UInt16(kVK_Option), flags: option | 0x20), nil, "left option is ignored")
            expectEqual(detector.flagsChanged(keyCode: UInt16(kVK_Option), flags: 0), nil)
        }

        test("hotkey.modifier.interruptions") {
            var detector = ModifierHoldDetector(key: .rightOption)
            expectEqual(detector.flagsChanged(keyCode: UInt16(kVK_RightOption), flags: option | 0x40), .pressed)
            expectEqual(detector.keyDown(), .interrupted, "typing while held is an accent or shortcut")
            expectEqual(detector.keyDown(), nil, "only one interrupt per hold")
            expectEqual(detector.flagsChanged(keyCode: UInt16(kVK_RightOption), flags: 0), nil, "release after interrupt is silent")
            expectEqual(detector.keyDown(), nil, "keys typed while not held are ignored")

            expectEqual(detector.flagsChanged(keyCode: UInt16(kVK_RightOption), flags: option | 0x40), .pressed)
            expectEqual(detector.flagsChanged(keyCode: UInt16(kVK_Command), flags: option | 0x40 | command | 0x08), .interrupted, "another modifier joining is a chord")
            expectEqual(detector.flagsChanged(keyCode: UInt16(kVK_RightOption), flags: command | 0x08), nil)

            var chord = ModifierHoldDetector(key: .rightCommand)
            expectEqual(chord.flagsChanged(keyCode: UInt16(kVK_RightCommand), flags: command | 0x10 | option | 0x20), .interrupted, "pressed on top of another modifier")
            chord.reset()
            expect(!chord.isDown, "reset clears the held state")
        }

        test("hotkey.modifier.function") {
            var detector = ModifierHoldDetector(key: .function)
            expectEqual(detector.flagsChanged(keyCode: UInt16(kVK_Function), flags: ModifierHoldDetector.functionFlag), .pressed)
            expectEqual(detector.flagsChanged(keyCode: UInt16(kVK_Function), flags: 0), .released)
        }
    }

    // MARK: - Settings and persistence

    private static func hotkeySettingsTests() {
        test("hotkey.settings.defaultsMatchShippedBehavior") {
            let settings = ShortcutSettings.default
            expectEqual(settings.mode, .toggle)
            expectEqual(settings.chord(for: .toggleDictation), .optionSpace)
            expectEqual(settings.chord(for: .cancel), .escape)
            expectEqual(settings.chord(for: .pasteLast), nil)
            expectEqual(settings.chord(for: .retryLast), nil)
            expectEqual(settings.modifierHold, nil, "one-key trigger is opt-in")
            expectEqual(settings.hybridThreshold, 0.3)
            expectEqual(settings.bindings.map(\.action), ShortcutAction.allCases)
            expectEqual(AppConfig.defaultConfig.shortcuts, .default)
        }

        test("hotkey.settings.legacyConfigDecodesToDefaults") {
            let encoded = try JSONEncoder().encode(AppConfig.defaultConfig)
            var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] ?? [:]
            expect(object["shortcuts"] != nil, "shortcuts are persisted")
            object.removeValue(forKey: "shortcuts")
            let legacy = try JSONSerialization.data(withJSONObject: object)
            let decoded = try JSONDecoder().decode(AppConfig.self, from: legacy)
            expectEqual(decoded.shortcuts, .default, "older config.json keeps Option+Space toggle")

            object["shortcuts"] = "garbage"
            let damaged = try JSONSerialization.data(withJSONObject: object)
            let recovered = try JSONDecoder().decode(AppConfig.self, from: damaged)
            expectEqual(recovered.shortcuts, .default, "a damaged block falls back instead of failing the config")
        }

        test("hotkey.settings.roundTripAndLenience") {
            var custom = ShortcutSettings(mode: .hybrid, modifierHold: .rightOption, hybridThreshold: 0.45)
            custom.setChord(KeyChord(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(controlKey | optionKey)), for: .pasteLast)
            var config = AppConfig.defaultConfig
            config.shortcuts = custom
            let decoded = try JSONDecoder().decode(AppConfig.self, from: try JSONEncoder().encode(config))
            expectEqual(decoded.shortcuts, custom, "round trip keeps every field")

            let newer = """
            {"mode":"whisper","modifierHold":"leftPinky","hybridThreshold":99,
             "bindings":[{"action":"teleport","chord":{"keyCode":1,"modifiers":256}},
                         {"action":"pasteLast","chord":{"keyCode":9,"modifiers":2304}},
                         {"action":"pasteLast","chord":{"keyCode":11,"modifiers":2304}}]}
            """
            let lenient = try JSONDecoder().decode(ShortcutSettings.self, from: Data(newer.utf8))
            expectEqual(lenient.mode, .toggle, "unknown mode falls back to toggle")
            expectEqual(lenient.modifierHold, nil, "unknown hold key is dropped")
            expectEqual(lenient.hybridThreshold, 1.0, "threshold is clamped")
            expectEqual(lenient.chord(for: .pasteLast)?.keyCode, 9, "first duplicate wins")
            expectEqual(lenient.chord(for: .toggleDictation), .optionSpace, "missing actions get defaults")
            expectEqual(lenient.bindings.count, ShortcutAction.allCases.count, "one binding per action")

            let empty = try JSONDecoder().decode(ShortcutSettings.self, from: Data("{}".utf8))
            expectEqual(empty, .default, "empty block is the default")
            expectEqual(ShortcutSettings.clampedThreshold(.nan), 0.3)
            expectEqual(ShortcutSettings.clampedThreshold(0.01), 0.15)
        }

        test("hotkey.settings.setChordNormalizes") {
            var settings = ShortcutSettings.default
            settings.setChord(KeyChord(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(controlKey) | 0x8000), for: .toggleDictation)
            expectEqual(settings.chord(for: .toggleDictation), KeyChord(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(controlKey)), "stray bits are masked")
            settings.setChord(nil, for: .cancel)
            expectEqual(settings.chord(for: .cancel), nil)
            expectEqual(settings.bindings.count, ShortcutAction.allCases.count)
        }

        test("hotkey.settings.ya71Headline") {
            expect(RecordingMode.toggle.headline != "PUSH TO TALK", "toggle never claims push to talk")
            expectEqual(RecordingMode.toggle.headline, "PRESS TO TALK")
            expectEqual(RecordingMode.hold.headline, "HOLD TO TALK")
            expectEqual(RecordingMode.hybrid.headline, "TAP OR HOLD")
        }
    }

    // MARK: - Recorder validation

    private static func hotkeyValidationTests() {
        let settings = ShortcutSettings.default
        func chord(_ key: Int, _ modifiers: Int = 0) -> KeyChord {
            KeyChord(keyCode: UInt32(key), modifiers: UInt32(modifiers))
        }

        test("hotkey.validation.rejectsBareKeys") {
            expect(!ShortcutValidator.validate(chord(kVK_ANSI_D), for: .toggleDictation, in: settings).isAccepted, "plain letter rejected")
            expect(!ShortcutValidator.validate(chord(kVK_ANSI_D, shiftKey), for: .toggleDictation, in: settings).isAccepted, "shift plus letter rejected")
            expect(!ShortcutValidator.validate(chord(kVK_Space), for: .pasteLast, in: settings).isAccepted, "bare space rejected")
            expect(!ShortcutValidator.validate(chord(kVK_LeftArrow), for: .pasteLast, in: settings).isAccepted, "bare arrow rejected")
            expect(!ShortcutValidator.validate(chord(kVK_Escape), for: .toggleDictation, in: settings).isAccepted, "bare Esc is kept for cancel")
            expect(ShortcutValidator.validate(chord(kVK_F5), for: .toggleDictation, in: settings).isAccepted, "a function key alone is fine")
            expect(ShortcutValidator.validate(chord(kVK_Escape), for: .cancel, in: settings).isAccepted, "Esc alone is fine for cancel")
            let message = ShortcutValidator.validate(chord(kVK_ANSI_D), for: .toggleDictation, in: settings).message ?? ""
            expect(message.contains("block typing"), "says why, got \(message)")
            expect(!message.contains("\u{2014}"), "no em dash in copy")
        }

        test("hotkey.validation.reservedAndConflicts") {
            let spotlight = ShortcutValidator.validate(chord(kVK_Space, cmdKey), for: .toggleDictation, in: settings)
            expect(!spotlight.isAccepted, "Command Space belongs to Spotlight")
            expect(spotlight.message?.contains("Spotlight") == true, "names the owner")
            expect(!ShortcutValidator.validate(chord(kVK_ANSI_V, cmdKey), for: .pasteLast, in: settings).isAccepted, "Command V is Paste")
            let clash = ShortcutValidator.validate(.optionSpace, for: .pasteLast, in: settings)
            expect(!clash.isAccepted, "already used by dictate")
            expect(clash.message?.contains("dictate") == true, "names the clashing action, got \(clash.message ?? "")")
            expect(ShortcutValidator.validate(.optionSpace, for: .toggleDictation, in: settings).isAccepted, "re-recording the same action is fine")
        }

        test("hotkey.validation.knownCollisionWarnings") {
            guard case .accepted(let warnings) = ShortcutValidator.validate(.optionSpace, for: .toggleDictation, in: settings) else {
                expect(false, "Option Space must stay allowed")
                return
            }
            let joined = warnings.joined(separator: " ")
            for name in ["Alfred", "Raycast", "ChatGPT", "French", "non-breaking space"] {
                expect(joined.contains(name), "Option Space warning mentions \(name)")
            }
            guard case .accepted(let accent) = ShortcutValidator.validate(chord(kVK_ANSI_E, optionKey), for: .pasteLast, in: settings) else {
                expect(false, "Option E is allowed with a warning")
                return
            }
            expect(accent.first?.contains("accent") == true, "Option letter warns about accents")
            expectEqual(
                ShortcutValidator.validate(chord(kVK_ANSI_D, controlKey | optionKey), for: .toggleDictation, in: settings),
                .accepted(warnings: []),
                "a quiet combo has no warnings"
            )
            for key in ModifierHoldKey.allCases {
                expect(!ShortcutValidator.modifierHoldNote(key).isEmpty, "\(key) has a note")
            }
        }

        test("hotkey.recorder.interpret") {
            expectEqual(ShortcutRecorderModel.interpret(keyCode: UInt16(kVK_Escape), modifiers: []), .stopListening)
            expectEqual(
                ShortcutRecorderModel.interpret(keyCode: UInt16(kVK_Escape), modifiers: [.command]),
                .chord(KeyChord(keyCode: UInt32(kVK_Escape), modifiers: UInt32(cmdKey)))
            )
            expectEqual(ShortcutRecorderModel.interpret(keyCode: UInt16(kVK_Space), modifiers: [.option, .capsLock]), .chord(.optionSpace), "caps lock is ignored")
            expectEqual(ShortcutKeyNames.carbonModifiers(from: ShortcutKeyNames.eventModifiers(from: UInt32(cmdKey | shiftKey))), UInt32(cmdKey | shiftKey))
            expectEqual(ShortcutKeyNames.keycaps(for: .optionSpace), ["⌥", "SPACE"])
            expectEqual(ShortcutKeyNames.keycaps(for: chord(kVK_ANSI_K, cmdKey | controlKey | optionKey | shiftKey)), ["⌃", "⌥", "⇧", "⌘", "K"])
            expectEqual(ShortcutKeyNames.spokenLabel(for: .optionSpace), "Option Space")
            expectEqual(ShortcutKeyNames.menuKeyEquivalent(for: .optionSpace), " ")
            expectEqual(ShortcutKeyNames.menuKeyEquivalent(for: chord(kVK_ANSI_V, cmdKey)), "v")
            expectEqual(ShortcutKeyNames.menuKeyEquivalent(for: chord(kVK_F5)), nil)

            let item = NSMenuItem(title: "Start Dictation", action: nil, keyEquivalent: "")
            ShortcutKeyNames.decorate(item, with: .optionSpace)
            expectEqual(item.keyEquivalent, " ")
            expectEqual(item.keyEquivalentModifierMask, [.option])
            ShortcutKeyNames.decorate(item, with: nil)
            expectEqual(item.keyEquivalent, "", "no chord clears the equivalent")
        }
    }

    // MARK: - Coordinator on fakes

    private final class FakeRegistrar: HotKeyRegistering {
        struct Entry {
            let chord: KeyChord
            let onPress: () -> Void
            let onRelease: (() -> Void)?
        }

        var entries: [UInt32: Entry] = [:]
        var refused: Set<KeyChord> = []
        var nextID: UInt32 = 1
        var unregisterCount = 0

        func register(chord: KeyChord, onPress: @escaping () -> Void, onRelease: (() -> Void)?) -> UInt32? {
            guard !refused.contains(chord) else { return nil }
            let id = nextID
            nextID += 1
            entries[id] = Entry(chord: chord, onPress: onPress, onRelease: onRelease)
            return id
        }

        func unregister(id: UInt32) {
            unregisterCount += 1
            entries.removeValue(forKey: id)
        }

        var chords: Set<KeyChord> { Set(entries.values.map(\.chord)) }

        func press(_ chord: KeyChord) {
            entries.values.first(where: { $0.chord == chord })?.onPress()
        }

        func release(_ chord: KeyChord) {
            entries.values.first(where: { $0.chord == chord })?.onRelease?()
        }
    }

    @MainActor
    private final class FakeModifierMonitor: ModifierEventMonitoring {
        var handler: (@MainActor (ModifierMonitorEvent) -> Void)?
        var startCount = 0

        func start(_ handler: @escaping @MainActor (ModifierMonitorEvent) -> Void) -> Bool {
            startCount += 1
            self.handler = handler
            return true
        }

        func stop() {
            handler = nil
        }

        func send(_ event: ModifierMonitorEvent) {
            handler?(event)
        }
    }

    @MainActor
    private final class CoordinatorHarness {
        let registrar = FakeRegistrar()
        let monitor = FakeModifierMonitor()
        var clock: TimeInterval = 1000
        var isRecording = false
        var intents: [DictationIntent] = []
        var pasteLastCount = 0
        var retryCount = 0
        var cancelCount = 0
        lazy var coordinator = ShortcutCoordinator(
            registrar: registrar,
            modifierMonitor: monitor,
            now: { [unowned self] in self.clock },
            handlers: ShortcutCoordinator.Handlers(
                isRecording: { [unowned self] in self.isRecording },
                onDictation: { [unowned self] intent in
                    self.intents.append(intent)
                    switch intent {
                    case .start: self.isRecording = true
                    case .stop, .cancel: self.isRecording = false
                    }
                },
                onPasteLast: { [unowned self] in self.pasteLastCount += 1 },
                onRetryLast: { [unowned self] in self.retryCount += 1 },
                onCancel: { [unowned self] in self.cancelCount += 1 }
            )
        )
    }

    private static func hotkeyCoordinatorTests() {
        test("hotkey.coordinator.defaultRegistration") {
            let harness = CoordinatorHarness()
            let failed = harness.coordinator.apply(.default)
            expectEqual(failed, [], "default registers cleanly")
            expectEqual(harness.registrar.chords, [.optionSpace], "only Option Space is grabbed while idle")
            expectEqual(harness.monitor.startCount, 0, "no key monitor unless opted in")

            harness.registrar.press(.optionSpace)
            expectEqual(harness.intents, [.start])
            harness.registrar.release(.optionSpace)
            expectEqual(harness.intents, [.start], "toggle ignores the release")

            harness.coordinator.armCancel()
            expectEqual(harness.registrar.chords, [.optionSpace, .escape], "Esc is grabbed while recording")
            harness.registrar.press(.escape)
            expectEqual(harness.cancelCount, 1)
            harness.coordinator.disarmCancel()
            expectEqual(harness.registrar.chords, [.optionSpace], "Esc is released after recording")

            harness.registrar.press(.optionSpace)
            expectEqual(harness.intents, [.start, .stop])
        }

        test("hotkey.coordinator.holdModeAndActions") {
            let harness = CoordinatorHarness()
            var settings = ShortcutSettings(mode: .hold)
            let paste = KeyChord(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(controlKey | optionKey))
            let retry = KeyChord(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(controlKey | optionKey))
            settings.setChord(paste, for: .pasteLast)
            settings.setChord(retry, for: .retryLast)
            harness.coordinator.apply(settings)
            expectEqual(harness.registrar.chords, [.optionSpace, paste, retry])

            harness.registrar.press(.optionSpace)
            harness.clock += 1.2
            harness.registrar.release(.optionSpace)
            expectEqual(harness.intents, [.start, .stop], "hold to record, release to stop")

            harness.registrar.press(.optionSpace)
            harness.clock += 0.05
            harness.registrar.release(.optionSpace)
            expectEqual(harness.intents, [.start, .stop, .start, .cancel], "a slip is canceled, not transcribed")

            harness.registrar.press(paste)
            harness.registrar.press(retry)
            expectEqual(harness.pasteLastCount, 1)
            expectEqual(harness.retryCount, 1)
        }

        test("hotkey.coordinator.failuresSuspendAndReapply") {
            let harness = CoordinatorHarness()
            harness.registrar.refused = [.optionSpace]
            expectEqual(harness.coordinator.apply(.default), [.toggleDictation], "a refused chord is reported")
            let message = ShortcutCopy.registrationFailure(.default, failed: [.toggleDictation]) ?? ""
            expect(message.contains("⌥ space"), "failure names the shortcut, got \(message)")
            expectEqual(ShortcutCopy.registrationFailure(.default, failed: []), nil)

            harness.registrar.refused = []
            harness.coordinator.apply(.default)
            harness.coordinator.armCancel()
            harness.coordinator.suspend()
            expectEqual(harness.registrar.chords, [], "recorder listening frees every shortcut")
            harness.coordinator.armCancel()
            expectEqual(harness.registrar.chords, [], "nothing registers while suspended")

            var rebound = ShortcutSettings.default
            let newChord = KeyChord(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(controlKey | optionKey))
            rebound.setChord(newChord, for: .toggleDictation)
            expectEqual(harness.coordinator.apply(rebound), [], "apply while suspended defers")
            expectEqual(harness.registrar.chords, [])
            harness.coordinator.resume()
            expectEqual(harness.registrar.chords, [newChord, .escape], "resume registers the new chord and the armed cancel")
            harness.coordinator.stop()
            expectEqual(harness.registrar.chords, [], "stop releases everything")
        }

        test("hotkey.coordinator.modifierHold") {
            let harness = CoordinatorHarness()
            let settings = ShortcutSettings(mode: .hybrid, modifierHold: .rightOption)
            harness.coordinator.apply(settings)
            expectEqual(harness.monitor.startCount, 1, "monitor starts only when opted in")
            expect(harness.coordinator.modifierMonitorRunning, "monitor reported running")

            let down = ModifierMonitorEvent.flagsChanged(keyCode: UInt16(kVK_RightOption), flags: ModifierHoldDetector.optionFlag | 0x40)
            let up = ModifierMonitorEvent.flagsChanged(keyCode: UInt16(kVK_RightOption), flags: 0)

            harness.monitor.send(down)
            harness.clock += 0.1
            harness.monitor.send(up)
            expectEqual(harness.intents, [.start], "tap latches in hybrid")
            harness.monitor.send(down)
            harness.monitor.send(up)
            expectEqual(harness.intents, [.start, .stop], "second tap stops")

            harness.monitor.send(down)
            harness.monitor.send(.keyDown)
            harness.monitor.send(up)
            expectEqual(harness.intents, [.start, .stop, .start, .cancel], "Right Option plus a key is typing, so the recording is dropped")

            harness.monitor.send(down)
            harness.clock += 2
            harness.monitor.send(up)
            expectEqual(harness.intents.suffix(2), [.start, .stop], "hold to talk on one key")

            harness.coordinator.apply(.default)
            expect(!harness.coordinator.modifierMonitorRunning, "turning it off stops the monitor")
            harness.monitor.send(down)
            expectEqual(harness.intents.count, 6, "no events after stop")
        }
    }

    // MARK: - Copy

    private static func hotkeyCopyTests() {
        test("hotkey.copy.defaultWordingUnchanged") {
            expectEqual(ShortcutCopy.listeningStatus(.default), "Listening. Press ⌥ space to stop, Esc to cancel.")
            expectEqual(ShortcutCopy.tooltip(.default), "YappYapp (⌥ space to dictate, right-click for menu)")
            let idle = StatusFlavor.idlePrompt[0]
            expectEqual(ShortcutCopy.personalize(idle, .default), idle, "default users see the shipped prompt")
            expectEqual(ShortcutCopy.menuTitle("Start Dictation", settings: .default), "Start Dictation")
        }

        test("hotkey.copy.reboundWording") {
            var settings = ShortcutSettings(mode: .hold)
            settings.setChord(KeyChord(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(controlKey | optionKey)), for: .toggleDictation)
            expectEqual(ShortcutCopy.listeningStatus(settings), "Listening. Release ⌃⌥ d to stop, Esc to cancel.")
            expectEqual(ShortcutCopy.personalize("Press ⌥ space in any app and start talking.", settings), "Press ⌃⌥ d in any app and start talking.")
            expectEqual(ShortcutCopy.personalize("Press Option Space anywhere.", settings), "Press Control Option D anywhere.")

            var holdOnly = ShortcutSettings(mode: .toggle, modifierHold: .rightOption)
            holdOnly.setChord(nil, for: .toggleDictation)
            holdOnly.setChord(nil, for: .cancel)
            expectEqual(ShortcutCopy.listeningStatus(holdOnly), "Listening. Press right option to stop.")
            expectEqual(ShortcutCopy.menuTitle("Start Dictation", settings: holdOnly), "Start Dictation (Right Option)")
            expect(ShortcutCopy.spokenSummary(holdOnly).contains("Right Option"), "VoiceOver names the one-key trigger")

            var none = ShortcutSettings.default
            none.setChord(nil, for: .toggleDictation)
            expect(ShortcutCopy.listeningStatus(none).hasPrefix("Listening. Click stop"), "no trigger falls back to the button")
            expectEqual(ShortcutCopy.spokenSummary(none).hasPrefix("No dictation shortcut"), true)
            expectEqual(ShortcutCopy.retryUnavailable(), "Nothing to retry yet. Dictate something first.")

            let hybrid = ShortcutSettings(mode: .hybrid)
            expect(ShortcutCopy.listeningStatus(hybrid).contains("Release or press"), "hybrid explains both exits")
            for text in [ShortcutCopy.modifierHoldPermission(trusted: true), ShortcutCopy.modifierHoldPermission(trusted: false)] {
                expect(!text.contains("\u{2014}"), "no em dash")
            }
        }
    }

    // MARK: - Paste last

    private static func hotkeyPasteLastTests() {
        let newest = TranscriptEntry(text: "second take", date: Date())
        let older = TranscriptEntry(text: "first take", date: Date(timeIntervalSinceNow: -60))

        test("hotkey.pasteLast.decide") {
            expectEqual(PasteLastController.decide(history: [], phase: .idle, pasteInFlight: false), .nothingYet)
            expectEqual(PasteLastController.decide(history: [newest, older], phase: .idle, pasteInFlight: false), .paste("second take"), "newest first")
            expectEqual(PasteLastController.decide(history: [newest], phase: .pasted, pasteInFlight: false), .paste("second take"))
            expectEqual(PasteLastController.decide(history: [newest], phase: .error("x"), pasteInFlight: false), .paste("second take"))
            expectEqual(PasteLastController.decide(history: [newest], phase: .recording, pasteInFlight: false), .busyRecording)
            expectEqual(PasteLastController.decide(history: [newest], phase: .transcribing, pasteInFlight: false), .busyTranscribing)
            expectEqual(PasteLastController.decide(history: [newest], phase: .idle, pasteInFlight: true), .busyPasting)
            let blank = TranscriptEntry(text: "  \n", date: Date())
            expectEqual(PasteLastController.decide(history: [blank], phase: .idle, pasteInFlight: false), .nothingYet)
            expectEqual(PasteLastDecision.paste("x").statusText, nil)
            expect(PasteLastDecision.nothingYet.statusText?.isEmpty == false, "explains an empty history")
        }

        test("hotkey.pasteLast.runUsesDeliverOnceAndBlocksReentry") {
            let controller = PasteLastController()
            var delivered: [String] = []
            var reports: [PasteLastDecision] = []
            var reentrant: PasteLastDecision?
            controller.run(
                history: [newest],
                phase: .idle,
                otherPasteInFlight: false,
                deliver: { text in
                    delivered.append(text)
                    expect(controller.isPasting, "flag is up while the paste spins")
                    controller.run(
                        history: [newest],
                        phase: .idle,
                        otherPasteInFlight: false,
                        deliver: { _ in PasteStatusSnapshot(phase: .pasted, statusText: "dup") },
                        report: { decision, _ in reentrant = decision }
                    )
                    return PasteStatusSnapshot(phase: .pasted, statusText: "Pasted.")
                },
                report: { decision, snapshot in
                    reports.append(decision)
                    expectEqual(snapshot?.statusText, "Pasted.")
                }
            )
            expectEqual(delivered, ["second take"], "delivered exactly once")
            expectEqual(reentrant, .busyPasting, "a second press during the paste is dropped")
            expectEqual(reports, [.paste("second take")])
            expect(!controller.isPasting, "flag drops after the paste")

            var skipped: PasteLastDecision?
            controller.run(
                history: [],
                phase: .idle,
                otherPasteInFlight: false,
                deliver: { _ in
                    expect(false, "nothing to deliver")
                    return PasteStatusSnapshot(phase: .idle, statusText: "")
                },
                report: { decision, snapshot in
                    skipped = decision
                    expectEqual(snapshot, nil)
                }
            )
            expectEqual(skipped, .nothingYet)
        }
    }

    // MARK: - Rendering

    private static func hotkeyRenderTests() {
        test("hotkey.render.settingsSectionAndKeys") {
            var custom = ShortcutSettings(mode: .hybrid, modifierHold: .function)
            custom.setChord(KeyChord(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(controlKey | optionKey)), for: .pasteLast)
            for settings in [ShortcutSettings.default, custom] {
                let section = ShortcutSettingsSection(settings: .constant(settings), isAccessibilityTrusted: false)
                    .frame(width: 400)
                    .background(Brutal.paper)
                expect(renderImage(section, width: 420, height: 720) != nil, "shortcut section renders")
                let keys = ActiveShortcutKeys(settings: settings).padding(8).background(Brutal.card)
                expect(renderImage(keys, width: 300, height: 80) != nil, "active shortcut keys render")
            }
            expect(!ShortcutRecorderGate.shared.isListening, "rendering never starts the recorder")
        }
    }
}
#endif
