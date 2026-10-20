import SwiftUI

/// Canonical Brutal palette and geometry. These primitives preserve the
/// shipped warm-paper, saturated-ink identity.
enum Brutal {
    static let paper = Color(red: 0.96, green: 0.94, blue: 0.88)
    static let card = Color(red: 0.99, green: 0.98, blue: 0.94)
    static let field = Color(red: 0.995, green: 0.985, blue: 0.95)
    static let ink = Color(red: 0.035, green: 0.027, blue: 0.020)
    static let yellow = Color(red: 1.0, green: 0.83, blue: 0.10)
    static let red = Color(red: 1.0, green: 0.29, blue: 0.16)
    static let blue = Color(red: 0.16, green: 0.35, blue: 1.0)
    static let green = Color(red: 0.05, green: 0.65, blue: 0.40)

    // Readable semantic roles. Fill primitives above remain unchanged so the
    // shipped palette and resting visuals retain their identity.
    static let textPrimary = ink
    static let textSecondary = ink.opacity(0.68)
    // 0.6 keeps small tertiary text at WCAG AA on paper as well as on card.
    static let textTertiary = ink.opacity(0.6)
    static let textDisabled = textTertiary
    static let dangerText = Color(red: 0.71, green: 0.165, blue: 0.086)
    static let successText = Color(red: 0.02, green: 0.43, blue: 0.22)
    static let successOnInk = green
    static let contentOnYellow = ink
    static let contentOnRed = ink
    static let contentOnBlue = paper
    static let contentOnGreen = ink

    static let border: CGFloat = 2
    static let drop: CGFloat = 4
    static let minimumHitTarget: CGFloat = 44
}

private struct BrutalScaledFontModifier: ViewModifier {
    @Environment(\.brutalTextSize) private var textSize
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design

    func body(content: Content) -> some View {
        content.font(.system(
            size: BrutalTypeScale.pointSize(base: size, textSize: textSize, dynamicTypeSize: dynamicTypeSize),
            weight: weight,
            design: design
        ))
    }
}

private struct BrutalInteractiveModifier: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false
    @FocusState private var isFocused: Bool
    @State private var focusedByPointer = false

    let label: String
    let hint: String
    let value: String
    let selected: Bool
    let hitExpansion: CGFloat

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle().inset(by: -hitExpansion))
            // Like a native button: in the key loop only when the Mac's
            // keyboard navigation is on, so opening a window never parks
            // focus on the first tab.
            .focusable(interactions: .activate)
            .focused($isFocused)
            .focusEffectDisabled()
            .overlay {
                if BrutalFocusRing.isVisible(
                    focused: isFocused,
                    focusedByPointer: focusedByPointer,
                    keyboardNavigation: BrutalFocusRing.keyboardNavigationEnabled
                ) {
                    BrutalFocusRingShape()
                }
            }
            .zIndex(isFocused ? 1 : 0)
            .onChange(of: isFocused) { _, focused in
                focusedByPointer = focused && isHovering
            }
            .brightness(isEnabled && isHovering ? 0.025 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: isHovering)
            .onHover { isHovering = $0 }
            // L10N: call sites pass the English text; it is translated here.
            .accessibilityLabel(Text(L10n.tr(label)))
            .accessibilityHint(Text(L10n.tr(hint)))
            .accessibilityValue(Text(L10n.tr(value)))
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct BrutalKeyboardActionModifier: ViewModifier {
    @FocusState private var isFocused: Bool
    @State private var isHovering = false
    @State private var focusedByPointer = false

    let label: String
    let hint: String
    let value: String
    let action: () -> Void

    func body(content: Content) -> some View {
        content
            // Like a native button: in the key loop only when the Mac's
            // keyboard navigation is on, so opening a window never parks
            // focus on the first tab.
            .focusable(interactions: .activate)
            .focused($isFocused)
            .focusEffectDisabled()
            .overlay {
                if BrutalFocusRing.isVisible(
                    focused: isFocused,
                    focusedByPointer: focusedByPointer,
                    keyboardNavigation: BrutalFocusRing.keyboardNavigationEnabled
                ) {
                    BrutalFocusRingShape()
                }
            }
            .onHover { isHovering = $0 }
            .onChange(of: isFocused) { _, focused in
                focusedByPointer = focused && isHovering
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(Text(L10n.tr(label)))
            .accessibilityHint(Text(L10n.tr(hint)))
            .accessibilityValue(Text(L10n.tr(value)))
            .accessibilityAction(named: Text(L10n.tr(label)), action)
            .onKeyPress(keys: BrutalKeyboardActivation.keys) { _ in
                BrutalKeyboardActivation.perform(action)
            }
    }
}

/// Shared keyboard contract for disclosure-style controls. Keeping the key set
/// and action result in one testable unit prevents a future split from silently
/// dropping either Return or Space activation.
enum BrutalKeyboardActivation {
    static let keys: Set<KeyEquivalent> = [.return, .space]

    static func perform(_ action: () -> Void) -> KeyPress.Result {
        action()
        return .handled
    }
}

extension View {
    func brutalFont(
        size: CGFloat,
        weight: Font.Weight,
        design: Font.Design = .default,
        relativeTo textStyle: Font.TextStyle
    ) -> some View {
        // textStyle documents the role; sizing comes from BrutalTypeScale.
        modifier(BrutalScaledFontModifier(size: size, weight: weight, design: design))
    }

    func brutalInteractive(
        label: String,
        hint: String,
        value: String = "",
        selected: Bool = false,
        hitExpansion: CGFloat = 5
    ) -> some View {
        modifier(
            BrutalInteractiveModifier(
                label: label,
                hint: hint,
                value: value,
                selected: selected,
                hitExpansion: hitExpansion
            )
        )
    }

    func brutalKeyboardAction(
        label: String,
        hint: String,
        value: String,
        action: @escaping () -> Void
    ) -> some View {
        modifier(BrutalKeyboardActionModifier(label: label, hint: hint, value: value, action: action))
    }
}

enum TranscriptHistoryLayout {
    static let latestCompactLineLimit = 6
    static let olderCompactLineLimit = 2
    static let expandedTextMaxHeight: CGFloat = 132
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

struct GlossaryEntryDraft: Identifiable {
    let id = UUID()
    var canonical: String
    var variantsText: String
    var notes: String
    /// The saved spelling this row came from, nil for a new row. Deleting
    /// the row deletes that saved word right away.
    var savedCanonical: String?
    /// LEARN-FROM-FIXES: the saved word was learned from a fix. The mark
    /// stays while its spelling is unchanged.
    var learned = false

    init(entry: GlossaryEntry) {
        savedCanonical = entry.canonical
        learned = entry.isLearned
        canonical = entry.canonical
        variantsText = entry.variants.joined(separator: ", ")
        notes = entry.notes ?? ""
    }

    init(canonical: String, variantsText: String, notes: String) {
        self.canonical = canonical
        self.variantsText = variantsText
        self.notes = notes
    }

    var entry: GlossaryEntry {
        GlossaryEntry(
            canonical: canonical,
            variants: variantsText
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty },
            notes: notes.isEmpty ? nil : notes,
            learned: showsLearnedMark ? true : nil
        )
    }

    /// The LEARNED tag shows while the row still holds the learned spelling.
    var showsLearnedMark: Bool {
        learned && canonical.trimmingCharacters(in: .whitespacesAndNewlines) == savedCanonical
    }
}

struct LiveWaveform: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let levels: [Double]
    let isActive: Bool
    let tint: Color
    var maxBarHeight: CGFloat = 30
    var barCount: Int = YappYappState.levelSampleCount
    var barWidth: CGFloat = 3
    var barSpacing: CGFloat = 3
    var squared = false
    var inactiveOpacity: Double = 0.3

    var body: some View {
        HStack(alignment: .center, spacing: barSpacing) {
            ForEach(Array(visibleLevels.enumerated()), id: \.offset) { _, level in
                Group {
                    if squared {
                        Rectangle().fill(tint.opacity(isActive ? 1 : inactiveOpacity))
                    } else {
                        Capsule(style: .continuous).fill(tint.opacity(isActive ? 0.92 : inactiveOpacity))
                    }
                }
                .frame(width: barWidth, height: barHeight(level))
            }
        }
        .frame(maxWidth: .infinity)
        .animation(reduceMotion ? nil : .linear(duration: 1.0 / 24.0), value: levels)
    }

    private var visibleLevels: [Double] { Array(levels.suffix(barCount)) }

    private func barHeight(_ level: Double) -> CGFloat {
        let minHeight: CGFloat = 3
        guard isActive else { return minHeight }
        let amplified = min(1.0, pow(level, 0.7) * 1.25)
        return minHeight + CGFloat(amplified) * (maxBarHeight - minHeight)
    }
}

struct BrutalIconButton: View {
    let symbol: String
    let title: String
    let help: String
    let action: () -> Void

    init(_ symbol: String, title: String, help: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.title = title
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: symbol)
                    .brutalFont(size: 8.5, weight: .black, relativeTo: .caption2)

                Text(L10n.tr(title))
                    .brutalFont(size: 8, weight: .black, relativeTo: .caption2)
                    .kerning(0.4)
            }
            .foregroundStyle(Brutal.ink)
            .padding(.horizontal, 6)
            .frame(minHeight: 22)
            .background(Brutal.paper)
            .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .help(L10n.tr(help))
        .brutalInteractive(label: title, hint: help, hitExpansion: 11)
    }
}

struct BrutalKey: View {
    let label: String

    init(_ label: String) {
        self.label = label
    }

    var body: some View {
        Text(L10n.tr(label))
            .brutalFont(size: 9, weight: .black, relativeTo: .caption)
            .kerning(0.5)
            .foregroundStyle(Brutal.ink)
            .padding(.horizontal, 5)
            .frame(minWidth: 20, minHeight: 18)
            .background(Brutal.paper)
            .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: 1.5))
            .accessibilityHidden(true)
    }
}

struct BrutalField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    @Environment(\.brutalFlattensScroll) private var offscreen

    var body: some View {
        input
            .brutalFont(size: 11.5, weight: .semibold, design: .monospaced, relativeTo: .callout)
            .foregroundStyle(Brutal.ink)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Brutal.field)
            .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))
            .focusEffectDisabled()
            .brutalFocusRing()
            .contentShape(Rectangle().inset(by: -6))
            .accessibilityLabel(Text(L10n.tr(label)))
    }

    @ViewBuilder
    private var input: some View {
        if offscreen {
            // The render gallery cannot draw an AppKit text field; show the
            // text or the placeholder the field would show.
            Text(text.isEmpty ? L10n.tr(placeholder) : text)
                .foregroundStyle(text.isEmpty ? Brutal.textTertiary : Brutal.ink)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            TextField(L10n.tr(label), text: $text, prompt: Text(L10n.tr(placeholder)).foregroundStyle(Brutal.textTertiary))
                .textFieldStyle(.plain)
        }
    }
}

struct BrutalButtonStyle: ButtonStyle {
    let fill: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(fill)
            .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))
            .background(
                Rectangle()
                    .fill(Brutal.ink)
                    .offset(
                        x: configuration.isPressed ? 0 : Brutal.drop,
                        y: configuration.isPressed ? 0 : Brutal.drop
                    )
            )
            .offset(
                x: configuration.isPressed ? Brutal.drop : 0,
                y: configuration.isPressed ? Brutal.drop : 0
            )
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

struct BrutalTextButtonStyle: ButtonStyle {
    let fill: Color
    let text: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brutalText(.action)
            .foregroundStyle(text)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 34)
            .background(fill)
            .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))
            .background(
                Rectangle()
                    .fill(Brutal.ink)
                    .offset(
                        x: configuration.isPressed ? 0 : Brutal.drop,
                        y: configuration.isPressed ? 0 : Brutal.drop
                    )
            )
            .offset(
                x: configuration.isPressed ? Brutal.drop : 0,
                y: configuration.isPressed ? Brutal.drop : 0
            )
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

// MARK: - Type scale (SETUP-TYPE)

/// The six text roles. One family (the system sans) in two weights: black for
/// everything you scan or press, medium for the sentences you read. Each role
/// has one case rule, so a screen never mixes caps and sentence case for the
/// same job. Sizes go through `brutalFont`, so TEXT SIZE and the 9pt floor
/// still apply.
enum BrutalTextStyle: CaseIterable, Sendable {
    /// The ink header bar of a section. Caps.
    case sectionTitle
    /// The name of a setting, left of or above its control. Caps.
    case rowLabel
    /// Text inside a control: segments, switches, buttons, menus, fields. Caps.
    case control
    /// A live reading beside a label, such as 5MIN or GOOD. Caps.
    case value
    /// Help and status lines under a row. Sentence case.
    case caption
    /// The label of a primary action button (START TEST). Caps.
    case action

    var size: CGFloat {
        switch self {
        case .sectionTitle: 9.5
        case .rowLabel: 10
        case .control: 9
        case .value: 10
        case .caption: 9.5
        case .action: 11
        }
    }

    var weight: Font.Weight {
        self == .caption ? .medium : .black
    }

    var tracking: CGFloat {
        switch self {
        case .sectionTitle: 1.2
        case .rowLabel, .action: 0.8
        case .control, .value: 0.6
        case .caption: 0
        }
    }

    var isUppercase: Bool {
        self != .caption
    }

    /// Documents the role for `brutalFont`; sizing comes from BrutalTypeScale.
    var textStyle: Font.TextStyle {
        switch self {
        case .sectionTitle, .control, .action: .caption
        case .rowLabel, .value: .callout
        case .caption: .caption2
        }
    }
}

extension View {
    /// The only way Setup sets type: one of the six `BrutalTextStyle` roles.
    func brutalText(_ style: BrutalTextStyle) -> some View {
        brutalFont(size: style.size, weight: style.weight, relativeTo: style.textStyle)
            .kerning(style.tracking)
            .textCase(style.isUppercase ? .uppercase : nil)
    }
}
