import AppKit
import Carbon
import SwiftUI

// SHORTCUTS: the rows of SETUP > DICTATION that rebind every global shortcut,
// pick the recording mode and the optional modifier-only trigger, plus the
// small keycap row the MIC tab shows. Lives in its own file so the shared
// settings tab only gains one line.

/// While the recorder listens, the app's own global shortcuts must stand down
/// or Carbon would swallow the very combo the user is trying to record. The
/// app delegate wires these two closures to the ShortcutCoordinator.
@MainActor
final class ShortcutRecorderGate {
    static let shared = ShortcutRecorderGate()

    var onBegin: (() -> Void)?
    var onEnd: (() -> Void)?
    private(set) var isListening = false

    func begin() {
        guard !isListening else { return }
        isListening = true
        onBegin?()
    }

    func end() {
        guard isListening else { return }
        isListening = false
        onEnd?()
    }
}

/// What one key press means to the recorder.
enum ShortcutRecorderInput: Equatable {
    case stopListening
    case chord(KeyChord)
}

@MainActor
final class ShortcutRecorderModel: ObservableObject {
    @Published private(set) var listening: ShortcutAction?
    private var monitor: Any?
    private var onInput: ((ShortcutRecorderInput) -> Void)?

    /// Esc alone backs out. Everything else is a candidate chord.
    nonisolated static func interpret(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> ShortcutRecorderInput {
        let carbon = ShortcutKeyNames.carbonModifiers(from: modifiers)
        if Int(keyCode) == kVK_Escape, carbon == 0 {
            return .stopListening
        }
        return .chord(KeyChord(keyCode: UInt32(keyCode), modifiers: carbon))
    }

    func start(_ action: ShortcutAction, onInput: @escaping (ShortcutRecorderInput) -> Void) {
        stop()
        listening = action
        self.onInput = onInput
        ShortcutRecorderGate.shared.begin()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            let input = Self.interpret(keyCode: event.keyCode, modifiers: event.modifierFlags)
            MainActor.assumeIsolated {
                ShortcutRecorderModel.deliver(input)
            }
            return nil
        }
        Self.active = self
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        onInput = nil
        listening = nil
        if Self.active === self {
            Self.active = nil
        }
        ShortcutRecorderGate.shared.end()
    }

    private static weak var active: ShortcutRecorderModel?

    private static func deliver(_ input: ShortcutRecorderInput) {
        guard let model = active else { return }
        if input == .stopListening {
            model.stop()
            return
        }
        model.onInput?(input)
    }
}

struct ShortcutSettingsSection: View {
    @Binding var settings: ShortcutSettings
    /// The stored `escCancelsRecording` switch. SETUP shows it through the
    /// CANCEL row only: NOT SET when off, SET turns it back on.
    @Binding var cancelEnabled: Bool
    let isAccessibilityTrusted: Bool

    @StateObject private var recorder = ShortcutRecorderModel()
    @State private var notice: ShortcutNotice?
    @State private var moreOpen: Bool

    init(
        settings: Binding<ShortcutSettings>,
        cancelEnabled: Binding<Bool> = .constant(true),
        isAccessibilityTrusted: Bool,
        moreOpen: Bool? = nil
    ) {
        _settings = settings
        _cancelEnabled = cancelEnabled
        self.isAccessibilityTrusted = isAccessibilityTrusted
        _moreOpen = State(initialValue: moreOpen ?? settings.wrappedValue.hasMoreShortcutsSet)
    }

    struct ShortcutNotice: Equatable {
        let action: ShortcutAction
        let text: String
        let isError: Bool
    }

    /// The shortcut rows of SETUP > DICTATION, in the order people change
    /// them: the shortcut, how it behaves, the one-key option, cancel, then
    /// the rarely used shortcuts behind one disclosure. The section card
    /// around them belongs to the Setup tab.
    var body: some View {
        VStack(alignment: .leading, spacing: BrutalControl.rowSpacing) {
            bindingRow(.toggleDictation)
            modeBlock
            holdKeyBlock
            bindingRow(.cancel)
            moreBlock
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onDisappear { recorder.stop() }
    }

    // MARK: - Mode

    private var modeBlock: some View {
        VStack(alignment: .leading, spacing: BrutalControl.innerSpacing) {
            BrutalRowLabel(L10n.tr("MODE"))
            BrutalSegmented(
                choices: RecordingMode.allCases.map { mode in
                    BrutalChoice(
                        value: mode,
                        title: mode.chipLabel,
                        accessibilityLabel: L10n.tr("%@ mode", mode.chipLabel.capitalized),
                        hint: mode.explanation
                    )
                },
                selection: settings.mode,
                hint: L10n.tr("How the dictate shortcut starts and stops")
            ) { settings.mode = $0 }
            BrutalCaption(settings.mode.explanation)
        }
    }

    // MARK: - More shortcuts

    private var moreBlock: some View {
        VStack(alignment: .leading, spacing: BrutalControl.rowSpacing) {
            BrutalDisclosure(
                title: L10n.tr("MORE SHORTCUTS"),
                isOpen: moreOpen,
                accessibilityLabel: L10n.tr("More shortcuts"),
                hint: moreOpen ? L10n.tr("Hides paste last, retry last and undo last") : L10n.tr("Shows paste last, retry last and undo last")
            ) {
                if moreOpen, let listening = recorder.listening, ShortcutAction.moreInSetup.contains(listening) {
                    recorder.stop()
                }
                moreOpen.toggle()
            }

            if moreOpen {
                ForEach(ShortcutAction.moreInSetup) { action in
                    bindingRow(action)
                }

                BrutalActionButton(
                    title: L10n.tr("RESET SHORTCUTS"),
                    accessibilityLabel: L10n.tr("Reset shortcuts"),
                    hint: L10n.tr("Back to Option Space in press mode, and Esc to cancel")
                ) {
                    recorder.stop()
                    notice = nil
                    settings = .default
                    cancelEnabled = true
                }
            }
        }
    }

    // MARK: - Bindings

    private func bindingRow(_ action: ShortcutAction) -> some View {
        let chord = action == .cancel
            ? settings.effectiveCancelChord(cancelEnabled: cancelEnabled)
            : settings.chord(for: action)
        let isListening = recorder.listening == action
        let canClear = chord != nil && (action != .toggleDictation || settings.modifierHold != nil)

        return VStack(alignment: .leading, spacing: BrutalControl.innerSpacing) {
            HStack(spacing: 10) {
                BrutalRowLabel(action.title)
                Spacer(minLength: 8)
                BrutalShortcutField(
                    keys: chord.map { ShortcutKeyNames.keycaps(for: $0).joined(separator: " ") },
                    isListening: isListening,
                    canClear: canClear,
                    actionTitle: action.title,
                    spokenValue: chord.map { ShortcutKeyNames.spokenLabel(for: $0) } ?? L10n.tr("Not set"),
                    onRecord: {
                        if isListening {
                            recorder.stop()
                        } else {
                            startListening(for: action)
                        }
                    },
                    onClear: {
                        recorder.stop()
                        notice = nil
                        settings.setChord(nil, for: action)
                        if action == .cancel { cancelEnabled = true }
                    }
                )
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(action.title.capitalized))

            BrutalCaption(isListening ? L10n.tr("Press the new shortcut. Esc keeps the old one.") : action.detail)

            if let notice, notice.action == action {
                BrutalCaption(notice.text, tone: notice.isError ? .warning : .normal)
                    .accessibilityLabel(Text(notice.isError ? L10n.tr("Can't use that. %@", notice.text) : L10n.tr("Heads up. %@", notice.text)))
            }
        }
    }

    private func startListening(for action: ShortcutAction) {
        notice = nil
        recorder.start(action) { input in
            guard case .chord(let chord) = input else { return }
            let result = ShortcutValidator.validate(chord, for: action, in: settings.effective(cancelEnabled: cancelEnabled))
            switch result {
            case .rejected(let reason):
                // Stay in listening mode so the next combo can be tried at once.
                notice = ShortcutNotice(action: action, text: reason, isError: true)
            case .accepted(let warnings):
                settings.setChord(chord, for: action)
                if action == .cancel { cancelEnabled = true }
                notice = warnings.first.map { ShortcutNotice(action: action, text: $0, isError: false) }
                recorder.stop()
            }
        }
    }

    // MARK: - Modifier-only trigger

    private var holdKeyBlock: some View {
        VStack(alignment: .leading, spacing: BrutalControl.innerSpacing) {
            BrutalRowLabel(L10n.tr("DICTATE WITH ONE KEY"))

            BrutalSegmented(
                choices: [
                    BrutalChoice<ModifierHoldKey?>(
                        value: nil,
                        title: L10n.tr("OFF"),
                        accessibilityLabel: L10n.tr("One-key dictation off"),
                        hint: L10n.tr("Uses only the dictate shortcut"),
                        disabled: settings.chord(for: .toggleDictation) == nil
                    )
                ] + ModifierHoldKey.allCases.map { key in
                    BrutalChoice<ModifierHoldKey?>(
                        value: key,
                        title: key.chipLabel,
                        accessibilityLabel: L10n.tr("Dictate with %@", key.spokenName),
                        hint: L10n.tr("Pressing %@ alone starts dictation", key.spokenName)
                    )
                },
                selection: settings.modifierHold,
                hint: L10n.tr("Uses only the dictate shortcut")
            ) { settings.modifierHold = $0 }

            if let key = settings.modifierHold {
                BrutalCaption(ShortcutValidator.modifierHoldNote(key))
                BrutalCaption(
                    ShortcutCopy.modifierHoldPermission(trusted: isAccessibilityTrusted),
                    tone: isAccessibilityTrusted ? .normal : .warning
                )
            } else {
                BrutalCaption(L10n.tr("Start dictating with one key on its own. Uses the auto-paste permission."))
            }
        }
    }
}

/// Keycaps for the active dictation trigger, shown under the MIC headline.
struct ActiveShortcutKeys: View {
    let settings: ShortcutSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                if let chord = settings.chord(for: .toggleDictation) {
                    ForEach(Array(ShortcutKeyNames.keycaps(for: chord).enumerated()), id: \.offset) { _, cap in
                        BrutalKey(cap)
                    }
                }
                if let hold = settings.modifierHold {
                    if settings.chord(for: .toggleDictation) != nil {
                        caption(L10n.tr("OR"))
                    }
                    BrutalKey(hold.chipLabel)
                }
                caption(L10n.tr("ANYWHERE"))
            }

            if let paste = settings.chord(for: .pasteLast) {
                HStack(spacing: 4) {
                    ForEach(Array(ShortcutKeyNames.keycaps(for: paste).enumerated()), id: \.offset) { _, cap in
                        BrutalKey(cap)
                    }
                    caption(L10n.tr("PASTE LAST"))
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(ShortcutCopy.spokenSummary(settings)))
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .brutalFont(size: 8.5, weight: .bold, relativeTo: .caption2)
            .kerning(0.6)
            .foregroundStyle(Brutal.textTertiary)
    }
}
