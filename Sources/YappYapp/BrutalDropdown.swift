import SwiftUI

// DROPDOWN-FLOAT: one dropdown for the whole app. The field stays in the
// card at its normal height; the open list floats over everything, anchored
// under the field, drawn by `brutalDropdownHost()` at the window root. So:
// - nothing on the card moves when a list opens (the owner hated the shift)
// - the card, a scroll view or the tab body never clips the list
// - a click anywhere outside, or Escape, closes it
// - arrow keys move, Return picks, Tab or Escape leave
// - VoiceOver reads the list as one modal group of buttons
// The control window and the menu-bar popover both show
// `BrutalistPopoverView`, whose root is the host, so every tab and every
// onboarding step behaves the same. A dropdown drawn outside any host
// still floats, in a plain overlay over its own field.

/// One row of an open dropdown.
struct BrutalMenuItem: Identifiable {
    let id: String
    let title: String
    var selected = false
    var disabled = false
    var leadingSymbol: String?
    let accessibilityLabel: String
    let hint: String
    let action: () -> Void
}

/// What an open dropdown hands its host: where it is and what it lists.
struct BrutalOpenMenu {
    let anchor: Anchor<CGRect>
    let accessibilityLabel: String
    let items: [BrutalMenuItem]
    /// Shown instead of rows when there is nothing to pick.
    let emptyText: String?
    let close: () -> Void
}

struct BrutalOpenMenuKey: PreferenceKey {
    static var defaultValue: [BrutalOpenMenu] { [] }

    static func reduce(value: inout [BrutalOpenMenu], nextValue: () -> [BrutalOpenMenu]) {
        value.append(contentsOf: nextValue())
    }
}

private struct BrutalDropdownHostedKey: EnvironmentKey {
    static let defaultValue = false
}

private struct BrutalDropdownForcedOpenKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// True under `brutalDropdownHost()`: lists float at the window root.
    var brutalDropdownHosted: Bool {
        get { self[BrutalDropdownHostedKey.self] }
        set { self[BrutalDropdownHostedKey.self] = newValue }
    }

    /// The render gallery and the self-tests open the dropdown with this
    /// accessibility label. Nil in the app.
    var brutalDropdownForcedOpen: String? {
        get { self[BrutalDropdownForcedOpenKey.self] }
        set { self[BrutalDropdownForcedOpenKey.self] = newValue }
    }
}

// MARK: - The dropdown

/// A field that opens a floating list. `items` is read when the list opens
/// and on every redraw while it is open, so it may compute on demand.
struct BrutalDropdown: View {
    let title: String
    let accessibilityLabel: String
    let hint: String
    var leadingSymbol: String?
    var emptyText: String?
    /// Runs just before the list opens, such as reading the open apps.
    var onOpen: () -> Void = {}
    let items: () -> [BrutalMenuItem]

    @State private var open = false
    @Environment(\.brutalDropdownHosted) private var hosted
    @Environment(\.brutalDropdownForcedOpen) private var forcedOpen

    init(
        title: String,
        accessibilityLabel: String,
        hint: String,
        leadingSymbol: String? = nil,
        emptyText: String? = nil,
        onOpen: @escaping () -> Void = {},
        items: @escaping () -> [BrutalMenuItem]
    ) {
        self.title = title
        self.accessibilityLabel = accessibilityLabel
        self.hint = hint
        self.leadingSymbol = leadingSymbol
        self.emptyText = emptyText
        self.onOpen = onOpen
        self.items = items
    }

    private var isOpen: Bool {
        open || forcedOpen == accessibilityLabel
    }

    var body: some View {
        let field = BrutalDropdownField(
            title: title,
            isOpen: isOpen,
            accessibilityLabel: accessibilityLabel,
            hint: hint,
            leadingSymbol: leadingSymbol
        ) {
            if !open { onOpen() }
            open.toggle()
        }
        .onKeyPress(.downArrow) {
            guard !open else { return .ignored }
            onOpen()
            open = true
            return .handled
        }

        if hosted {
            field.anchorPreference(key: BrutalOpenMenuKey.self, value: .bounds) { anchor in
                guard isOpen else { return [] }
                return [BrutalOpenMenu(
                    anchor: anchor,
                    accessibilityLabel: accessibilityLabel,
                    items: items(),
                    emptyText: emptyText,
                    close: { open = false }
                )]
            }
        } else {
            // No host above (a tab body rendered on its own): float over
            // the field in a plain overlay. Still no layout change.
            field
                .overlay(alignment: .bottom) {
                    if isOpen {
                        BrutalMenuPanel(
                            accessibilityLabel: accessibilityLabel,
                            items: items(),
                            emptyText: emptyText,
                            close: { open = false }
                        )
                        .fixedSize(horizontal: false, vertical: true)
                        .alignmentGuide(.bottom) { $0[.top] + Brutal.border }
                    }
                }
                .zIndex(isOpen ? 10 : 0)
        }
    }
}

// MARK: - Host

extension View {
    /// Draws open dropdowns above this view. Put it on the window root.
    func brutalDropdownHost() -> some View {
        modifier(BrutalDropdownHost())
    }
}

private struct BrutalDropdownHost: ViewModifier {
    func body(content: Content) -> some View {
        content
            .environment(\.brutalDropdownHosted, true)
            .overlayPreferenceValue(BrutalOpenMenuKey.self) { menus in
                if let menu = menus.last {
                    GeometryReader { proxy in
                        BrutalMenuLayer(menu: menu, field: proxy[menu.anchor], bounds: proxy.size)
                    }
                }
            }
    }
}

/// Where the list goes: under the field, or above it when the space below
/// is too short and there is more above. Pure, so the tests can check it.
enum BrutalMenuPlacement {
    /// Space kept between the list and the window edge.
    static let margin: CGFloat = 8

    struct Frame: Equatable {
        /// True when the list opens upward.
        let above: Bool
        let x: CGFloat
        let width: CGFloat
        /// The list's top edge, or its bottom edge when `above`.
        let edge: CGFloat
        /// The most height the list may take before it scrolls.
        let maxHeight: CGFloat
    }

    static func frame(field: CGRect, bounds: CGSize, wantedHeight: CGFloat) -> Frame {
        let below = bounds.height - field.maxY - margin - Brutal.drop
        let above = field.minY - margin
        let flips = below < wantedHeight && above > below
        return Frame(
            above: flips,
            x: field.minX,
            width: field.width,
            edge: flips ? field.minY + Brutal.border : field.maxY - Brutal.border,
            maxHeight: max(BrutalControl.height * 2, flips ? above : below)
        )
    }

    /// A rough height for the full list, used only to decide the side.
    static func wantedHeight(rows: Int) -> CGFloat {
        CGFloat(max(rows, 1)) * BrutalControl.height + Brutal.border * 2
    }
}

/// The open list and the click catcher behind it, at window size.
private struct BrutalMenuLayer: View {
    let menu: BrutalOpenMenu
    let field: CGRect
    let bounds: CGSize

    var body: some View {
        let place = BrutalMenuPlacement.frame(
            field: field,
            bounds: bounds,
            wantedHeight: BrutalMenuPlacement.wantedHeight(rows: menu.items.count)
        )
        ZStack(alignment: place.above ? .bottomLeading : .topLeading) {
            // A click outside closes the list and does nothing else, like a
            // macOS menu. It also keeps a scroll from sliding the card out
            // from under the list.
            Rectangle()
                .fill(Color.white.opacity(0.001))
                .contentShape(Rectangle())
                .onTapGesture { menu.close() }
                .accessibilityHidden(true)

            BrutalMenuPanel(
                accessibilityLabel: menu.accessibilityLabel,
                items: menu.items,
                emptyText: menu.emptyText,
                close: menu.close,
                maxHeight: place.maxHeight,
                growsUp: place.above
            )
            .frame(width: place.width)
            .offset(x: place.x, y: place.above ? place.edge - bounds.height : place.edge)
        }
        .frame(width: bounds.width, height: bounds.height)
    }
}

// MARK: - The list

/// The floating list: ink frame, hard offset shadow, uppercase rows, the
/// picked row filled ink with a check. Takes keyboard focus when it opens.
struct BrutalMenuPanel: View {
    let accessibilityLabel: String
    let items: [BrutalMenuItem]
    let emptyText: String?
    let close: () -> Void
    /// The room the host gives the list. Nil outside a host: full height.
    var maxHeight: CGFloat?
    var growsUp = false

    @State private var highlighted: Int?
    @FocusState private var focused: Bool
    @Environment(\.brutalFlattensScroll) private var offscreen

    var body: some View {
        if let maxHeight {
            // Offer exactly the room there is, so a short list keeps its
            // own height and a long one scrolls inside the frame.
            panel.frame(height: maxHeight, alignment: growsUp ? .bottom : .top)
        } else {
            panel
        }
    }

    private var panel: some View {
        ViewThatFits(in: .vertical) {
            rows
            if offscreen {
                // The render gallery draws scroll views blank; show the top.
                rows.frame(maxHeight: .infinity, alignment: .top).clipped()
            } else {
                scrollingRows
            }
        }
        .background(Brutal.card)
        .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))
        .background(Rectangle().fill(Brutal.ink).offset(x: Brutal.drop, y: Brutal.drop))
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear {
            highlighted = startIndex
            focused = true
        }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.return) { pick(); return .handled }
        .onKeyPress(.space) { pick(); return .handled }
        .onKeyPress(.escape) { close(); return .handled }
        .onKeyPress(.tab) { close(); return .ignored }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) { close() }
    }

    private var scrollingRows: some View {
        ScrollViewReader { reader in
            ScrollView {
                rows
            }
            .scrollIndicators(.visible)
            .onAppear {
                if let start = startIndex { reader.scrollTo(items[start].id, anchor: .center) }
            }
            .onChange(of: highlighted) { _, index in
                if let index, items.indices.contains(index) { reader.scrollTo(items[index].id) }
            }
        }
    }

    private var rows: some View {
        VStack(spacing: 0) {
            if items.isEmpty, let emptyText {
                BrutalCaption(emptyText)
                    .padding(10)
            }
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                BrutalMenuRow(
                    title: item.title,
                    selected: item.selected,
                    highlighted: highlighted == index,
                    disabled: item.disabled,
                    leadingSymbol: item.leadingSymbol,
                    accessibilityLabel: item.accessibilityLabel,
                    hint: item.hint
                ) {
                    choose(item)
                }
                .disabled(item.disabled)
                .onHover { inside in
                    if inside, !item.disabled { highlighted = index }
                }
                .id(item.id)
            }
        }
        .padding(Brutal.border)
    }

    private var startIndex: Int? {
        items.firstIndex(where: \.selected) ?? items.firstIndex { !$0.disabled }
    }

    private func move(_ step: Int) {
        guard !items.isEmpty else { return }
        var index = highlighted ?? (step > 0 ? -1 : items.count)
        for _ in items.indices {
            index = (index + step + items.count) % items.count
            if !items[index].disabled {
                highlighted = index
                return
            }
        }
    }

    private func pick() {
        guard let highlighted, items.indices.contains(highlighted), !items[highlighted].disabled else { return }
        choose(items[highlighted])
    }

    private func choose(_ item: BrutalMenuItem) {
        close()
        item.action()
    }
}
