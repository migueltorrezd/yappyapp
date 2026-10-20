import AppKit
import SwiftUI

/// Where the always-on indicator sits. Stored as `hudPosition` in config.json;
/// an unknown value reads as `.bottom`.
enum HUDPosition: String, CaseIterable, Sendable {
    case bottom
    case top
    case left
    case right
    case off

    init(configValue: String) {
        self = HUDPosition(rawValue: configValue.lowercased()) ?? .bottom
    }

    /// The stored value, repaired: anything unknown becomes "bottom".
    static func normalized(_ configValue: String) -> String {
        HUDPosition(configValue: configValue).rawValue
    }

    var isVertical: Bool {
        self == .left || self == .right
    }

    /// The indicator window for this position. Left and right are tall and
    /// thin, with room above the bar for the pet perched on its upper end;
    /// top and bottom leave room beside the bar for the live preview and the
    /// pet (above the bar at the bottom, hanging under it at the top).
    var windowSize: NSSize {
        if isVertical {
            return NSSize(
                width: IndicatorMetrics.perchWidth,
                height: IndicatorMetrics.verticalBarArea + IndicatorMetrics.perchHeadroom
            )
        }
        return NSSize(width: 200, height: 120)
    }

    /// Bottom-left origin of the indicator window on a screen whose
    /// `visibleFrame` is given. Centered on the edge it sits on; on the
    /// sides the BAR is vertically centered, the pet's headroom sits above.
    func windowOrigin(in visibleFrame: NSRect) -> NSPoint {
        let size = windowSize
        let inset = IndicatorMetrics.edgeInset
        let sideY = visibleFrame.midY - IndicatorMetrics.verticalBarArea / 2
        switch self {
        case .top:
            return NSPoint(x: visibleFrame.midX - size.width / 2, y: visibleFrame.maxY - size.height - inset)
        case .left:
            return NSPoint(x: visibleFrame.minX + inset, y: sideY)
        case .right:
            return NSPoint(x: visibleFrame.maxX - size.width - inset, y: sideY)
        case .bottom, .off:
            return NSPoint(x: visibleFrame.midX - size.width / 2, y: visibleFrame.minY + inset)
        }
    }

    /// Where the widget hugs inside its window: against the screen edge.
    var contentAlignment: Alignment {
        switch self {
        case .left: .bottomLeading
        case .right: .bottomTrailing
        case .top: .top
        case .bottom, .off: .bottom
        }
    }

    /// Where the pet lives. Bottom: standing on the bar. Top: hanging under
    /// it, upside down, so the menu bar and the notch never cut it off.
    /// Left and right: sitting on the bar's upper end, facing the screen.
    enum PetPlacement: Equatable {
        case standing
        case hanging
        case perched(HorizontalEdge)
    }

    var petPlacement: PetPlacement? {
        switch self {
        case .bottom: .standing
        case .top: .hanging
        case .left: .perched(.leading)
        case .right: .perched(.trailing)
        case .off: nil
        }
    }

    var showsPet: Bool { petPlacement != nil }

    /// FOCUS-AT-DELIVERY: the only part of the indicator window that takes
    /// clicks (stop, KEEP, RETRY), in window coordinates with a bottom-left
    /// origin. Everything else, the pet and its headroom included, stays
    /// click-through, so a click meant for the app under the indicator (a
    /// Ghostty prompt at the bottom of the screen) reaches that app.
    func interactiveRect(windowSize size: NSSize) -> NSRect {
        let long = IndicatorMetrics.length + IndicatorMetrics.drop
        let short = IndicatorMetrics.thickness + IndicatorMetrics.drop
        switch self {
        case .bottom, .off:
            return NSRect(x: (size.width - long) / 2, y: 0, width: long, height: short)
        case .top:
            return NSRect(x: (size.width - long) / 2, y: size.height - short, width: long, height: short)
        case .left:
            let y = (IndicatorMetrics.verticalBarArea - long) / 2
            return NSRect(x: IndicatorMetrics.sideBarPadding, y: y, width: short, height: long)
        case .right:
            let y = (IndicatorMetrics.verticalBarArea - long) / 2
            return NSRect(x: size.width - IndicatorMetrics.sideBarPadding - short, y: y, width: short, height: long)
        }
    }

    /// The opt-in live preview needs a line of words; a vertical bar has no
    /// room for one, so the words are hidden there (the text still pastes).
    var showsLivePreview: Bool { !isVertical }
}

/// Indicator geometry, scaled down from the Brutal tokens so the bar stays a
/// quiet object at the edge of the screen.
enum IndicatorMetrics {
    /// The long side of the active bar, frame included.
    static let length: CGFloat = 156
    /// The short side of the active bar, frame included.
    static let thickness: CGFloat = 24
    /// Hard offset shadow at indicator scale.
    static let drop: CGFloat = 3
    /// Idle pill.
    static let idleLength: CGFloat = 28
    static let idleThickness: CGFloat = 6
    /// Gap between the window and the screen edge.
    static let edgeInset: CGFloat = 6
    /// Left and right: the bar's own slot, centered on the screen edge.
    static let verticalBarArea: CGFloat = length + drop + 16
    /// Left and right: the window is wide enough for the widest pet (23
    /// sprite pixels at 2pt) sitting on the bar's upper end.
    static let perchWidth: CGFloat = 52
    /// Left and right: room above the bar's slot for the perched pet.
    static let perchHeadroom: CGFloat = 48
    /// Left and right: gap between the bar and the window's screen side.
    static let sideBarPadding: CGFloat = 2
    /// Level meter bars.
    static let meterBarCount = 18
    static let meterBarWidth: CGFloat = 3
    static let meterBarSpacing: CGFloat = 2
    static let meterMaxBar: CGFloat = 14
}

/// The flat fill and glyph of the indicator's state square. No words: the
/// state is carried by color and a symbol, and spoken by VoiceOver.
struct IndicatorState: Equatable {
    enum Fill: Equatable {
        case red, blue, green, yellow, paper, ink
    }

    enum Action: Equatable {
        case keep
        case retry
    }

    enum Meter: Equatable {
        /// Live input levels.
        case live
        /// Indeterminate sweep while the engine works.
        case sweep
        /// A flat resting line in the state's color.
        case rest
    }

    let fill: Fill
    /// SF Symbol drawn in the state square, nil for the blinking stop square.
    let symbol: String?
    let meter: Meter
    /// The compact icon button at the far end, when one is needed.
    let action: Action?

    static func make(phase: CapturePhase, isCleaning: Bool, retryAvailable: Bool) -> IndicatorState {
        switch phase {
        case .recording:
            return IndicatorState(fill: .red, symbol: nil, meter: .live, action: nil)
        case .transcribing:
            return IndicatorState(fill: .blue, symbol: isCleaning ? "wand.and.stars" : "waveform", meter: .sweep, action: nil)
        case .pasted:
            return IndicatorState(fill: .green, symbol: "checkmark", meter: .rest, action: nil)
        case .copied:
            return IndicatorState(fill: .green, symbol: "doc.on.clipboard", meter: .rest, action: nil)
        case .sentUnconfirmed:
            return IndicatorState(fill: .paper, symbol: "questionmark", meter: .rest, action: nil)
        case .notDelivered:
            return IndicatorState(fill: .yellow, symbol: "doc.on.clipboard", meter: .rest, action: nil)
        case .canceled:
            return IndicatorState(fill: .ink, symbol: "xmark", meter: .rest, action: .keep)
        case .error:
            let retry = RetryLastPresenter.offersRetry(phase: phase, retryAvailable: retryAvailable)
            return IndicatorState(fill: .yellow, symbol: "exclamationmark", meter: .rest, action: retry ? .retry : nil)
        case .idle:
            return IndicatorState(fill: .ink, symbol: "waveform", meter: .rest, action: nil)
        }
    }

    static func symbol(for action: Action) -> String {
        switch action {
        case .keep: "arrow.uturn.backward"
        case .retry: "arrow.clockwise"
        }
    }

    /// Words a sighted user reads on the bar itself. Always empty: the state
    /// lives in color, glyph and meter; the words live on MIC, the menu bar
    /// and VoiceOver.
    var visibleText: [String] { [] }
}

/// VoiceOver wording for the indicator. The bar shows no words, so this is
/// where the state, the reason and the profile badge live.
enum IndicatorAccessibility {
    static func label(for phase: CapturePhase, elapsed: Int) -> String {
        L10n.tr("Dictation indicator: %@", HUDPresenter.trailingLabel(for: phase, elapsed: elapsed).lowercased(with: L10n.locale))
    }

    /// The note, reason or countdown, then the language and model.
    static func value(caption: String?, badge: DictationBadge?, phase: CapturePhase) -> String {
        var parts: [String] = []
        if let caption, !caption.isEmpty { parts.append(caption.lowercased(with: L10n.locale)) }
        if let badge, phase == .recording || phase == .transcribing { parts.append(badge.accessibilityLabel) }
        return parts.joined(separator: ", ")
    }
}
