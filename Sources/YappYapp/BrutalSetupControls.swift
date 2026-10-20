import SwiftUI

// SETUP-CONTROLS: one representation per kind of choice. Every control shares
// the same height, 2pt ink frame and card fill, and every text uses a
// `BrutalTextStyle` role:
// - pick one of a few: `BrutalSegmented` (equal cells on one line)
// - pick one of many: `BrutalPicker` (a dropdown that floats over the card)
// - on or off: `BrutalSwitch`
// - a key combo: `BrutalShortcutField`
// - a number on a range: `BrutalSlider`
// - a secondary action: `BrutalActionButton`
// - more rows: `BrutalDisclosure`
// - a new group of rows inside a section: `BrutalGroupBreak`
// Compact controls (switch, shortcut, value) sit right of their label. Wide
// controls (segments, dropdown, slider) sit under it at full width.
//
// SETUP-RHYTHM: one spacing scale for every section. Inside a row (label,
// control, caption) things sit tight; between rows there is clearly more air,
// so a caption always reads as part of the row above it. Groups of related
// rows are split by a hairline, with a small heading when a section mixes
// different things.

enum BrutalControl {
    /// One height for every control in Setup.
    static let height: CGFloat = 26
    static let switchWidth: CGFloat = 46
    static let shortcutMinWidth: CGFloat = 112
    /// Space between rows in a section. More than three times the space
    /// inside a row, so a caption never floats between two rows.
    static let rowSpacing: CGFloat = 18
    /// Space between a row's label, its control and its caption.
    static let innerSpacing: CGFloat = 5
    /// Between two lines that read as one item, such as a name and its summary.
    static let lineSpacing: CGFloat = 2
    /// Extra air above a group heading, on top of `rowSpacing`.
    static let groupLead: CGFloat = 8
    /// How much closer a group heading sits to its own rows than `rowSpacing`.
    static let headingTuck: CGFloat = 8
    /// Space between two section cards.
    static let sectionSpacing: CGFloat = 16
    /// The group hairline.
    static let hairline: CGFloat = 1
}

// MARK: - Text pieces

/// The name of a setting.
struct BrutalRowLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .brutalText(.rowLabel)
            .foregroundStyle(Brutal.ink)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The one caption style under a row.
struct BrutalCaption: View {
    enum Tone {
        case normal
        case warning
        case success
    }

    let text: String
    var tone: Tone = .normal

    init(_ text: String, tone: Tone = .normal) {
        self.text = text
        self.tone = tone
    }

    var body: some View {
        Text(text)
            .brutalText(.caption)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var color: Color {
        switch tone {
        case .normal: Brutal.textSecondary
        case .warning: Brutal.dangerText
        case .success: Brutal.successText
        }
    }
}

/// Starts a new group of related rows inside a section card. With a title it
/// is a small heading followed by a hairline to the right edge ("KEYS ────"),
/// with extra air above and tucked close to the rows it heads. Without a
/// title it is a plain full-width hairline, centred between the two groups.
/// It sits between rows as a sibling, so sections stay flat lists. The
/// first group of a section passes `first: true`: no extra air under the bar.
struct BrutalGroupBreak: View {
    let title: String?
    var first = false

    init(_ title: String? = nil, first: Bool = false) {
        self.title = title
        self.first = first
    }

    var body: some View {
        if let title {
            HStack(spacing: 8) {
                Text(title)
                    .brutalText(.control)
                    .foregroundStyle(Brutal.textSecondary)
                    .fixedSize()
                rule
            }
            .padding(.top, first ? 0 : BrutalControl.groupLead)
            .padding(.bottom, -BrutalControl.headingTuck)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(title.capitalized))
            .accessibilityAddTraits(.isHeader)
        } else {
            rule
                .accessibilityHidden(true)
        }
    }

    private var rule: some View {
        Rectangle()
            .fill(Brutal.ink)
            .frame(height: BrutalControl.hairline)
            .frame(maxWidth: .infinity)
    }
}

/// A section: full-width ink title bar over a card body (YA-74).
struct BrutalSettingsCard<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .brutalText(.sectionTitle)
                .foregroundStyle(Brutal.paper)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                // Full-width ink bar: a text-width label left a 2pt paper
                // hairline between the frame and the drop shadow (YA-74).
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Brutal.ink)
                .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: BrutalControl.rowSpacing) {
                content
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Brutal.card)
        }
        .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))
        .background(Rectangle().fill(Brutal.ink).offset(x: Brutal.drop, y: Brutal.drop))
    }
}

// MARK: - Segmented choice

/// One option of a segmented control or dropdown. Titles are translated.
struct BrutalChoice<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    var accessibilityLabel: String?
    var hint: String?
    var disabled = false

    var id: String { title }
}

/// Pick one of a few. Equal cells on one line, the picked one filled ink.
struct BrutalSegmented<Value: Hashable>: View {
    let choices: [BrutalChoice<Value>]
    let selection: Value
    /// Spoken hint for every cell that has none of its own.
    let hint: String
    let onSelect: (Value) -> Void

    var body: some View {
        HStack(spacing: -Brutal.border) {
            ForEach(choices) { choice in
                cell(choice)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
    }

    private func cell(_ choice: BrutalChoice<Value>) -> some View {
        let selected = choice.value == selection
        return Button {
            onSelect(choice.value)
        } label: {
            Text(choice.title)
                .brutalText(.control)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity, minHeight: BrutalControl.height)
                .background(selected ? Brutal.ink : Brutal.card)
                .foregroundStyle(selected ? Brutal.paper : (choice.disabled ? Brutal.textDisabled : Brutal.ink))
                .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(choice.disabled)
        .brutalInteractive(
            label: choice.accessibilityLabel ?? choice.title,
            hint: choice.hint ?? hint,
            value: selected ? L10n.tr("Selected") : L10n.tr("Not selected"),
            selected: selected,
            hitExpansion: 3
        )
    }
}

// MARK: - Switch

/// On or off: the one boolean control.
struct BrutalSwitch: View {
    /// Translated setting name, for VoiceOver.
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Text(isOn ? L10n.tr("ON") : L10n.tr("OFF"))
                .brutalText(.control)
                .lineLimit(1)
                .frame(width: BrutalControl.switchWidth)
                .frame(minHeight: BrutalControl.height)
                .background(isOn ? Brutal.green : Brutal.card)
                .foregroundStyle(isOn ? Brutal.contentOnGreen : Brutal.textTertiary)
                .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .brutalInteractive(
            label: title,
            hint: L10n.tr("Toggles %@", title.lowercased()),
            value: isOn ? L10n.tr("On") : L10n.tr("Off"),
            selected: isOn,
            hitExpansion: 9
        )
        .accessibilityRepresentation {
            Toggle(title, isOn: $isOn)
                .accessibilityHint(L10n.tr("Toggles %@", title.lowercased()))
        }
    }
}

/// Label left, switch right, one optional caption under both.
struct BrutalSwitchRow: View {
    let title: String
    @Binding var isOn: Bool
    var caption: String?
    var captionTone: BrutalCaption.Tone = .normal

    init(_ title: String, isOn: Binding<Bool>, caption: String? = nil, captionTone: BrutalCaption.Tone = .normal) {
        self.title = title
        _isOn = isOn
        self.caption = caption
        self.captionTone = captionTone
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BrutalControl.innerSpacing) {
            HStack(spacing: 10) {
                BrutalRowLabel(title)
                Spacer(minLength: 8)
                BrutalSwitch(title: title, isOn: $isOn)
            }
            if let caption {
                BrutalCaption(caption, tone: captionTone)
            }
        }
    }
}

// MARK: - Dropdown
// DROPDOWN-FLOAT: every Brutal dropdown opens as a floating list anchored
// under its field, drawn by the window's dropdown host above everything
// else. The field keeps its height open or closed, so nothing on the card
// moves. See BrutalDropdown.swift for the list, its placement and its keys.

/// The closed dropdown: current value and a chevron in the control frame.
struct BrutalDropdownField: View {
    let title: String
    let isOpen: Bool
    let accessibilityLabel: String
    let hint: String
    var leadingSymbol: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let leadingSymbol {
                    Image(systemName: leadingSymbol)
                        .brutalText(.control)
                }
                Text(title)
                    .brutalText(.control)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                    .brutalText(.control)
            }
            .foregroundStyle(Brutal.ink)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: BrutalControl.height)
            .background(isOpen ? Brutal.yellow : Brutal.card)
            .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .brutalInteractive(
            label: accessibilityLabel,
            hint: hint,
            value: "\(title). \(L10n.tr(isOpen ? "Expanded" : "Collapsed"))",
            hitExpansion: 8
        )
    }
}

/// One row of an open dropdown. The picked row is filled ink and carries a
/// check; the row under the keyboard or pointer is filled yellow.
struct BrutalMenuRow: View {
    let title: String
    var selected = false
    var highlighted = false
    var disabled = false
    var leadingSymbol: String?
    let accessibilityLabel: String
    let hint: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let leadingSymbol {
                    Image(systemName: leadingSymbol)
                        .brutalText(.control)
                }
                Text(title)
                    .brutalText(.control)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark")
                        .brutalText(.control)
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: BrutalControl.height, alignment: .leading)
            .background(fill)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .brutalInteractive(
            label: accessibilityLabel,
            hint: hint,
            value: selected ? L10n.tr("Selected") : L10n.tr("Not selected"),
            selected: selected,
            hitExpansion: 0
        )
    }

    private var fill: Color {
        if selected { return Brutal.ink }
        return highlighted ? Brutal.yellow : Brutal.card
    }

    private var foreground: Color {
        if selected { return highlighted ? Brutal.yellow : Brutal.paper }
        return disabled ? Brutal.textDisabled : Brutal.ink
    }
}

/// Pick one of many: a field that opens a floating list under itself. A
/// native Menu popup does not match the poster skin.
struct BrutalPicker<Value: Hashable>: View {
    let choices: [BrutalChoice<Value>]
    let selection: Value
    /// Translated name of the setting, for VoiceOver.
    let accessibilityLabel: String
    let hint: String
    let onSelect: (Value) -> Void

    var body: some View {
        BrutalDropdown(
            title: choices.first { $0.value == selection }?.title ?? "",
            accessibilityLabel: accessibilityLabel,
            hint: hint
        ) {
            choices.map { choice in
                BrutalMenuItem(
                    id: choice.id,
                    title: choice.title,
                    selected: choice.value == selection,
                    disabled: choice.disabled,
                    accessibilityLabel: choice.accessibilityLabel ?? choice.title,
                    hint: choice.hint ?? hint
                ) {
                    onSelect(choice.value)
                }
            }
        }
    }
}

// MARK: - Shortcut recorder

/// One field showing the keys, such as ⌥ SPACE. Click it, then press the new
/// keys. The small x clears it.
struct BrutalShortcutField: View {
    /// Keys as shown, such as "⌥ SPACE". nil when not set.
    let keys: String?
    let isListening: Bool
    let canClear: Bool
    /// Translated action name, such as DICTATE.
    let actionTitle: String
    let spokenValue: String
    let onRecord: () -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: -Brutal.border) {
            Button(action: onRecord) {
                Text(isListening ? L10n.tr("PRESS NEW KEYS") : (keys ?? L10n.tr("NOT SET")))
                    .brutalText(.control)
                    .lineLimit(1)
                    .foregroundStyle(keys == nil && !isListening ? Brutal.textTertiary : Brutal.ink)
                    .padding(.horizontal, 10)
                    .frame(minWidth: BrutalControl.shortcutMinWidth, minHeight: BrutalControl.height)
                    .background(isListening ? Brutal.yellow : Brutal.card)
                    .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .brutalInteractive(
                label: isListening ? L10n.tr("Stop recording a shortcut") : L10n.tr("Set %@ shortcut", actionTitle.lowercased()),
                hint: isListening ? L10n.tr("Keeps the current shortcut") : L10n.tr("Waits for the shortcut you press next"),
                value: spokenValue,
                selected: isListening,
                hitExpansion: 6
            )

            if canClear, !isListening {
                Button(action: onClear) {
                    Image(systemName: "xmark")
                        .brutalText(.control)
                        .foregroundStyle(Brutal.ink)
                        .frame(width: BrutalControl.height, height: BrutalControl.height)
                        .background(Brutal.card)
                        .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.tr("Removes this shortcut"))
                .brutalInteractive(
                    label: L10n.tr("Clear %@ shortcut", actionTitle.lowercased()),
                    hint: L10n.tr("Removes this shortcut"),
                    hitExpansion: 6
                )
            }
        }
        .fixedSize()
    }
}

// MARK: - Slider

/// A number on a range: an ink-filled track and a yellow handle. Arrow keys
/// and VoiceOver adjust it one step at a time.
struct BrutalSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let accessibilityLabel: String
    let hint: String
    let valueText: String

    private let handleWidth: CGFloat = 14
    private let trackHeight: CGFloat = 10

    var body: some View {
        GeometryReader { proxy in
            let travel = max(proxy.size.width - handleWidth, 1)
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Brutal.field)
                    .frame(height: trackHeight)
                    .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))
                Rectangle()
                    .fill(Brutal.ink)
                    .frame(width: travel * fraction + handleWidth / 2, height: trackHeight)
                Rectangle()
                    .fill(Brutal.yellow)
                    .frame(width: handleWidth, height: BrutalControl.height)
                    .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))
                    .offset(x: travel * fraction)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { drag in
                    set(fraction: (drag.location.x - handleWidth / 2) / travel)
                }
            )
        }
        .frame(height: BrutalControl.height)
        .focusable()
        .focusEffectDisabled()
        .brutalFocusRing()
        .onKeyPress(.leftArrow) { nudge(-1); return .handled }
        .onKeyPress(.rightArrow) { nudge(1); return .handled }
        .accessibilityElement()
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityHint(Text(hint))
        .accessibilityValue(Text(valueText))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: nudge(1)
            case .decrement: nudge(-1)
            @unknown default: break
            }
        }
    }

    private var fraction: CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return CGFloat(min(max((value - range.lowerBound) / span, 0), 1))
    }

    private func set(fraction: CGFloat) {
        let clamped = Double(min(max(fraction, 0), 1))
        let raw = range.lowerBound + clamped * (range.upperBound - range.lowerBound)
        let stepped = (raw / step).rounded() * step
        let next = min(max(stepped, range.lowerBound), range.upperBound)
        if next != value { value = next }
    }

    private func nudge(_ steps: Double) {
        value = min(max(value + steps * step, range.lowerBound), range.upperBound)
    }
}

// MARK: - Actions and disclosure

/// A secondary action: the same frame and height as a segment.
struct BrutalActionButton: View {
    enum Tone {
        case normal
        case danger
    }

    let title: String
    let accessibilityLabel: String
    let hint: String
    var tone: Tone = .normal
    var fillsWidth = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .brutalText(.control)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: BrutalControl.height)
                .background(Brutal.card)
                .foregroundStyle(tone == .danger ? Brutal.dangerText : Brutal.ink)
                .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: !fillsWidth, vertical: true)
        .brutalInteractive(label: accessibilityLabel, hint: hint, hitExpansion: 9)
    }
}

/// The one way a section tucks away rarely changed rows.
struct BrutalDisclosure: View {
    let title: String
    let isOpen: Bool
    let accessibilityLabel: String
    let hint: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .brutalText(.rowLabel)
                Spacer(minLength: 6)
                Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                    .brutalText(.control)
            }
            .foregroundStyle(Brutal.ink)
            .frame(maxWidth: .infinity, minHeight: BrutalControl.height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .brutalInteractive(
            label: accessibilityLabel,
            hint: hint,
            value: L10n.tr(isOpen ? "Expanded" : "Collapsed"),
            hitExpansion: 6
        )
    }
}
