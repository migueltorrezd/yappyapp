import AppKit
import SwiftUI

// MARK: - Text size

/// In-app text size. macOS never feeds Dynamic Type to SwiftUI, so the popover
/// carries its own multiplier through the design system's type scale.
enum BrutalTextSize: String, CaseIterable, Identifiable, Sendable {
    case small
    case standard = "default"
    case large
    case larger

    var id: String { rawValue }

    /// Unknown or missing stored values fall back to the shipped default.
    init(configValue: String) {
        self = BrutalTextSize(rawValue: configValue) ?? .standard
    }

    var multiplier: CGFloat {
        switch self {
        case .small: 0.9
        case .standard: 1.0
        case .large: 1.15
        case .larger: 1.3
        }
    }

    var label: String {
        switch self {
        case .small: L10n.tr("SMALL")
        case .standard: L10n.tr("DEFAULT")
        case .large: L10n.tr("LARGE")
        case .larger: L10n.tr("LARGER")
        }
    }
}

/// Single source of truth for rendered point sizes. Every `brutalFont` call
/// goes through `pointSize`, so the floor and the multipliers apply everywhere.
enum BrutalTypeScale {
    /// Smallest rendered size for any label, at every text size setting.
    static let minimumPointSize: CGFloat = 9
    /// Upper bound for the combined multiplier so the fixed popover stays usable.
    static let maximumMultiplier: CGFloat = 1.6

    static func pointSize(
        base: CGFloat,
        textSize: BrutalTextSize,
        dynamicTypeSize: DynamicTypeSize = .large
    ) -> CGFloat {
        let combined = min(maximumMultiplier, textSize.multiplier * dynamicTypeMultiplier(dynamicTypeSize))
        return max(minimumPointSize, (base * combined * 2).rounded() / 2)
    }

    /// macOS leaves the environment at `.large`, which maps to 1. Explicit
    /// values (tests, previews, future system support) still scale the type.
    static func dynamicTypeMultiplier(_ size: DynamicTypeSize) -> CGFloat {
        switch size {
        case .xSmall: 0.85
        case .small: 0.9
        case .medium: 0.95
        case .large: 1.0
        case .xLarge: 1.1
        case .xxLarge: 1.2
        case .xxxLarge: 1.3
        case .accessibility1: 1.4
        case .accessibility2: 1.45
        case .accessibility3: 1.5
        case .accessibility4: 1.55
        case .accessibility5: 1.6
        @unknown default: 1.0
        }
    }
}

private struct BrutalTextSizeKey: EnvironmentKey {
    static let defaultValue: BrutalTextSize = .standard
}

private struct BrutalFlattensScrollKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var brutalTextSize: BrutalTextSize {
        get { self[BrutalTextSizeKey.self] }
        set { self[BrutalTextSizeKey.self] = newValue }
    }

    /// Self-test render flag. ImageRenderer draws ScrollView content blank, so
    /// the offscreen pass swaps every `BrutalScroll` for a plain stack.
    var brutalFlattensScroll: Bool {
        get { self[BrutalFlattensScrollKey.self] }
        set { self[BrutalFlattensScrollKey.self] = newValue }
    }
}

// MARK: - Scroll container

/// Vertical scroll container for tab bodies and long lists. Tabs own vertical
/// scrolling so larger text sizes stay reachable inside the fixed popover.
struct BrutalScroll<Content: View>: View {
    @Environment(\.brutalFlattensScroll) private var flattens
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        if flattens {
            // Ideal height, pinned to the top and clipped to the offered
            // height like a scroll view at rest, so the offscreen render shows
            // the first screen of the tab and never pushes siblings away.
            VStack(spacing: 0) {
                content
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
            .clipped()
        } else {
            // Call sites set scroll indicator visibility, as before.
            ScrollView {
                content
            }
        }
    }
}

// MARK: - Focus ring

/// Brutal keyboard focus: a hard 2pt ink frame offset outside the control,
/// with a paper gap. No glow, blur, or rounded corners, and never the macOS
/// blue: the owner read the blue frame around the first tab as clutter.
enum BrutalFocusRing {
    static let lineWidth: CGFloat = 2
    /// Distance from the control edge to the outer edge of the ring.
    static let outset: CGFloat = 4
    static let color = Brutal.ink

    /// Pointer clicks also move focus on macOS. The ring marks keyboard focus,
    /// so focus that arrived under the pointer stays unpainted. It also only
    /// paints when the Mac's "Keyboard navigation" setting is on: without it,
    /// focus only lands on a control because the window opened or the view
    /// moved it there, and a frame around the first tab is noise.
    static func isVisible(focused: Bool, focusedByPointer: Bool, keyboardNavigation: Bool) -> Bool {
        focused && !focusedByPointer && keyboardNavigation
    }

    /// The system "Keyboard navigation" switch (Full Keyboard Access).
    @MainActor
    static var keyboardNavigationEnabled: Bool {
        NSApp?.isFullKeyboardAccessEnabled ?? false
    }
}

struct BrutalFocusRingShape: View {
    var body: some View {
        Rectangle()
            .strokeBorder(BrutalFocusRing.color, lineWidth: BrutalFocusRing.lineWidth)
            .padding(-BrutalFocusRing.outset)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Paints the ring for views that already manage their own focus (native
/// sliders, text fields). Buttons get it through `brutalInteractive`.
private struct BrutalFocusRingModifier: ViewModifier {
    @FocusState private var isFocused: Bool
    @State private var isHovering = false
    @State private var focusedByPointer = false

    func body(content: Content) -> some View {
        content
            .focused($isFocused)
            .onHover { isHovering = $0 }
            .onChange(of: isFocused) { _, focused in
                focusedByPointer = focused && isHovering
            }
            .overlay {
                if BrutalFocusRing.isVisible(
                    focused: isFocused,
                    focusedByPointer: focusedByPointer,
                    keyboardNavigation: BrutalFocusRing.keyboardNavigationEnabled
                ) {
                    BrutalFocusRingShape()
                }
            }
    }
}

extension View {
    func brutalFocusRing() -> some View {
        modifier(BrutalFocusRingModifier())
    }
}

// MARK: - VoiceOver announcements

/// One route for every VoiceOver announcement. The poster is nil during the
/// self-test so offscreen runs never talk to the accessibility server.
@MainActor
final class AccessibilityAnnouncer {
    typealias Poster = @MainActor (String) -> Void

    static let shared = AccessibilityAnnouncer(poster: defaultPoster())

    private let poster: Poster?
    private var lastPhase: CapturePhase?

    init(poster: Poster?) {
        self.poster = poster
    }

    static func defaultPoster(arguments: [String] = ProcessInfo.processInfo.arguments) -> Poster? {
        guard !arguments.contains("--self-test") else { return nil }
        return { message in
            guard let app = NSApp else { return }
            NSAccessibility.post(
                element: app,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: message,
                    .priority: NSAccessibilityPriorityLevel.high.rawValue
                ]
            )
        }
    }

    /// Spoken text for a phase change, or nil when the phase is announced
    /// elsewhere (paste outcomes) or needs no speech (idle).
    static func message(for phase: CapturePhase) -> String? {
        switch phase {
        case .recording:
            return L10n.tr("Listening.")
        case .transcribing:
            return L10n.tr("Transcribing.")
        case .error(let detail):
            let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? L10n.tr("Needs attention.") : L10n.tr("Needs attention. %@", trimmed)
        case .canceled:
            return L10n.tr("Dictation canceled.")
        case .idle, .copied, .pasted, .sentUnconfirmed, .notDelivered:
            return nil
        }
    }

    func announcePhase(_ phase: CapturePhase) {
        guard phase != lastPhase else { return }
        lastPhase = phase
        guard let message = Self.message(for: phase) else { return }
        announce(message)
    }

    func announcePasteOutcome(_ status: PasteStatusSnapshot) {
        lastPhase = status.phase
        announce(status.statusText)
    }

    func announce(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        poster?(trimmed)
    }
}
