import AppKit
import Foundation

// SHORTCUTS: owns every global shortcut. It registers the configured chords,
// runs the optional modifier-only trigger, feeds both through the recording
// mode state machine and hands plain intents to the app. Real hot keys and
// event monitors sit behind two small protocols so the self-tests can drive
// the whole path with fakes and a fake clock.

protocol HotKeyRegistering: AnyObject {
    func register(chord: KeyChord, onPress: @escaping () -> Void, onRelease: (() -> Void)?) -> UInt32?
    func unregister(id: UInt32)
}

extension HotKeyManager: HotKeyRegistering {}

/// Raw keyboard events the modifier-only trigger cares about.
enum ModifierMonitorEvent: Equatable, Sendable {
    case flagsChanged(keyCode: UInt16, flags: UInt64)
    case keyDown
}

@MainActor
protocol ModifierEventMonitoring: AnyObject {
    /// Returns false when monitoring could not start.
    func start(_ handler: @escaping @MainActor (ModifierMonitorEvent) -> Void) -> Bool
    func stop()
}

/// Watches modifier keys system-wide with NSEvent monitors. Global key event
/// monitors only receive events while YappYapp is trusted for Accessibility,
/// the same permission auto-paste already uses, so no extra prompt appears.
@MainActor
final class NSEventModifierMonitor: ModifierEventMonitoring {
    private var globalMonitor: Any?
    private var localMonitor: Any?

    func start(_ handler: @escaping @MainActor (ModifierMonitorEvent) -> Void) -> Bool {
        stop()
        let convert: @Sendable (NSEvent) -> ModifierMonitorEvent? = { event in
            switch event.type {
            case .flagsChanged:
                return .flagsChanged(keyCode: event.keyCode, flags: UInt64(event.modifierFlags.rawValue))
            case .keyDown:
                return event.isARepeat ? nil : .keyDown
            default:
                return nil
            }
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { event in
            guard let converted = convert(event) else { return }
            MainActor.assumeIsolated { handler(converted) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { event in
            if let converted = convert(event) {
                MainActor.assumeIsolated { handler(converted) }
            }
            return event
        }
        return globalMonitor != nil
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }
}

@MainActor
final class ShortcutCoordinator {
    struct Handlers {
        var isRecording: () -> Bool
        var onDictation: (DictationIntent) -> Void
        var onPasteLast: () -> Void
        var onRetryLast: () -> Void
        var onCancel: () -> Void
        // COMMANDS: undo the last insertion.
        var onUndoLast: () -> Void = {}
    }

    private let registrar: HotKeyRegistering
    private let modifierMonitor: ModifierEventMonitoring
    private let now: () -> TimeInterval
    private let handlers: Handlers

    private(set) var settings = ShortcutSettings.default
    private(set) var registeredIDs: [ShortcutAction: UInt32] = [:]
    private(set) var failedActions: [ShortcutAction] = []
    private(set) var isCancelArmed = false
    private(set) var isSuspended = false
    private(set) var modifierMonitorRunning = false

    private var chordMachine = DictationGestureMachine(mode: .toggle)
    private var modifierMachine = DictationGestureMachine(mode: .toggle)
    private var modifierDetector: ModifierHoldDetector?

    init(
        registrar: HotKeyRegistering,
        modifierMonitor: ModifierEventMonitoring,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        handlers: Handlers
    ) {
        self.registrar = registrar
        self.modifierMonitor = modifierMonitor
        self.now = now
        self.handlers = handlers
    }

    /// Re-registers everything for new settings. Returns the actions whose
    /// chord could not be registered so the caller can say so.
    @discardableResult
    func apply(_ newSettings: ShortcutSettings) -> [ShortcutAction] {
        tearDown()
        settings = newSettings
        chordMachine = DictationGestureMachine(mode: newSettings.mode, hybridThreshold: newSettings.hybridThreshold)
        modifierMachine = DictationGestureMachine(mode: newSettings.mode, hybridThreshold: newSettings.hybridThreshold)
        guard !isSuspended else { return [] }
        buildUp()
        return failedActions
    }

    /// While the shortcut recorder listens, our own hot keys must not fire.
    func suspend() {
        guard !isSuspended else { return }
        tearDown()
        isSuspended = true
    }

    func resume() {
        guard isSuspended else { return }
        isSuspended = false
        buildUp()
    }

    /// The cancel chord (Esc by default) is grabbed only while recording.
    func armCancel() {
        isCancelArmed = true
        registerCancelIfNeeded()
    }

    func disarmCancel() {
        isCancelArmed = false
        if let id = registeredIDs.removeValue(forKey: .cancel) {
            registrar.unregister(id: id)
        }
    }

    func stop() {
        tearDown()
    }

    // MARK: - Registration

    private func buildUp() {
        failedActions = []
        for action in ShortcutAction.allCases where action.isAlwaysRegistered {
            guard let chord = settings.chord(for: action) else { continue }
            if let id = registrar.register(
                chord: chord,
                onPress: { [weak self] in self?.handlePress(action) },
                onRelease: action == .toggleDictation ? { [weak self] in self?.handleChordRelease() } : nil
            ) {
                registeredIDs[action] = id
            } else {
                failedActions.append(action)
            }
        }
        if isCancelArmed {
            registerCancelIfNeeded()
        }
        startModifierHoldIfNeeded()
    }

    private func tearDown() {
        for id in registeredIDs.values {
            registrar.unregister(id: id)
        }
        registeredIDs.removeAll()
        modifierMonitor.stop()
        modifierMonitorRunning = false
        modifierDetector = nil
        chordMachine.reset()
        modifierMachine.reset()
    }

    private func registerCancelIfNeeded() {
        guard !isSuspended, registeredIDs[.cancel] == nil, let chord = settings.chord(for: .cancel) else { return }
        registeredIDs[.cancel] = registrar.register(
            chord: chord,
            onPress: { [weak self] in self?.handlePress(.cancel) },
            onRelease: nil
        )
    }

    private func startModifierHoldIfNeeded() {
        guard let key = settings.modifierHold else { return }
        modifierDetector = ModifierHoldDetector(key: key)
        modifierMonitorRunning = modifierMonitor.start { [weak self] event in
            self?.handleModifierEvent(event)
        }
    }

    // MARK: - Events

    private func handlePress(_ action: ShortcutAction) {
        switch action {
        case .toggleDictation:
            if let intent = chordMachine.press(at: now(), isRecording: handlers.isRecording()) {
                handlers.onDictation(intent)
            }
        case .pasteLast:
            handlers.onPasteLast()
        case .retryLast:
            handlers.onRetryLast()
        case .undoLast:
            handlers.onUndoLast()
        case .cancel:
            handlers.onCancel()
        }
    }

    private func handleChordRelease() {
        if let intent = chordMachine.release(at: now(), isRecording: handlers.isRecording()) {
            handlers.onDictation(intent)
        }
    }

    func handleModifierEvent(_ event: ModifierMonitorEvent) {
        guard var detector = modifierDetector else { return }
        let edge: ModifierHoldEdge?
        switch event {
        case .flagsChanged(let keyCode, let flags):
            edge = detector.flagsChanged(keyCode: keyCode, flags: flags)
        case .keyDown:
            edge = detector.keyDown()
        }
        modifierDetector = detector

        let intent: DictationIntent?
        switch edge {
        case .pressed:
            intent = modifierMachine.press(at: now(), isRecording: handlers.isRecording())
        case .released:
            intent = modifierMachine.release(at: now(), isRecording: handlers.isRecording())
        case .interrupted:
            intent = modifierMachine.interrupt(isRecording: handlers.isRecording())
        case nil:
            intent = nil
        }
        if let intent {
            handlers.onDictation(intent)
        }
    }
}
