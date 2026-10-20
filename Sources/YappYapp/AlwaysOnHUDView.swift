import SwiftUI

/// The always-on indicator shown at the edge of every display while YappYapp
/// runs: a small quiet pill when idle that grows into the compact bar the
/// moment dictation starts. Bottom and top are horizontal: the pet stands on
/// the bar at the bottom and hangs under it at the top. Left and right are
/// vertical, centered on the edge, with the pet sitting on the bar's upper
/// end and no live preview.
struct AlwaysOnHUDView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var state: YappYappState
    let onToggleRecording: () -> Void
    let onUndoCancel: () -> Void
    let onRetry: () -> Void

    init(
        state: YappYappState,
        onToggleRecording: @escaping () -> Void = {},
        onUndoCancel: @escaping () -> Void = {},
        onRetry: @escaping () -> Void = {}
    ) {
        self.state = state
        self.onToggleRecording = onToggleRecording
        self.onUndoCancel = onUndoCancel
        self.onRetry = onRetry
    }

    /// The indicator window for a stored `hudPosition`.
    static func windowSize(for hudPosition: String) -> NSSize {
        HUDPosition(configValue: hudPosition).windowSize
    }

    private var position: HUDPosition {
        HUDPosition(configValue: state.config.hudPosition)
    }

    private var expanded: Bool {
        if case .idle = state.phase {
            return false
        }
        return true
    }

    // LIVE-PREVIEW: the words heard so far, only while recording, only where
    // a line of words fits.
    private var previewText: String? {
        guard position.showsLivePreview,
              state.phase == .recording,
              let text = state.livePreviewText, !text.isEmpty else { return nil }
        return text
    }

    private var previewHeight: CGFloat {
        previewText == nil ? 0 : LivePreviewStrip.height + Brutal.border
    }

    /// Height of the visible widget so the pet can stand on its top edge.
    /// The bar's hard shadow sits below its visual top edge.
    private var widgetHeight: CGFloat {
        expanded ? IndicatorMetrics.thickness + previewHeight : IndicatorMetrics.idleThickness + 2
    }

    /// Width of whatever the pet currently stands on.
    private var platformWidth: CGFloat {
        expanded ? IndicatorMetrics.length : IndicatorMetrics.idleLength
    }

    var body: some View {
        let position = position
        let size = position.windowSize
        Group {
            if position.isVertical {
                verticalBody(position)
            } else {
                horizontalBody(hanging: position == .top)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: expanded)
        .focusEffectDisabled()
        .frame(width: size.width, height: size.height, alignment: position.contentAlignment)
    }

    /// Bottom: the bar on the window's bottom edge, the preview above it and
    /// the pet standing on top. Top: the same, mirrored: the bar on the top
    /// edge, the preview under it and the pet hanging upside down below, so
    /// nothing reaches up into the menu bar or the notch.
    private func horizontalBody(hanging: Bool) -> some View {
        let edge: Edge.Set = hanging ? .top : .bottom
        return ZStack(alignment: hanging ? .top : .bottom) {
            Group {
                if expanded {
                    VStack(spacing: 0) {
                        if let previewText, !hanging {
                            previewStrip(previewText, gap: .bottom)
                        }
                        bar(vertical: false)
                        if let previewText, hanging {
                            previewStrip(previewText, gap: .top)
                        }
                    }
                } else {
                    idlePill(vertical: false, edge: edge)
                }
            }
            .transition(expansionTransition(anchor: hanging ? .top : .bottom))

            // The pet stands ON TOP of the pill or bar (or hangs under it),
            // rides the edge when it expands, and never walks past the
            // platform's ends.
            PetView(state: state, kind: state.overlayPet, pixel: 2, platformWidth: platformWidth, hanging: hanging)
                .frame(maxWidth: .infinity)
                .frame(height: 70)
                .padding(edge, widgetHeight)
        }
    }

    private func previewStrip(_ text: String, gap: Edge.Set) -> some View {
        LivePreviewStrip(text: text)
            .frame(width: IndicatorMetrics.length)
            .padding(.trailing, IndicatorMetrics.drop)
            .padding(gap, Brutal.border)
    }

    /// Left and right: the bar centered in its slot at the window's bottom,
    /// hugging the screen edge, and the pet sitting on its upper end facing
    /// the screen.
    private func verticalBody(_ position: HUDPosition) -> some View {
        let side: HorizontalEdge = position == .left ? .leading : .trailing
        let slot = IndicatorMetrics.verticalBarArea
        // Visual length of what the pet sits on, shadow included.
        let platform = expanded
            ? IndicatorMetrics.length + IndicatorMetrics.drop
            : IndicatorMetrics.idleLength
        return ZStack(alignment: .bottom) {
            Group {
                if expanded {
                    bar(vertical: true)
                } else {
                    idlePill(vertical: true, edge: [])
                }
            }
            .padding(side == .leading ? .leading : .trailing, IndicatorMetrics.sideBarPadding)
            .frame(maxWidth: .infinity, alignment: side == .leading ? .leading : .trailing)
            .frame(height: slot)
            .transition(expansionTransition(anchor: side == .leading ? .leading : .trailing))

            PetView(state: state, kind: state.overlayPet, pixel: 2, perch: side)
                .frame(maxWidth: .infinity)
                .frame(height: IndicatorMetrics.perchHeadroom + (slot - IndicatorMetrics.length - IndicatorMetrics.drop) / 2)
                .padding(.bottom, slot / 2 + platform / 2)
        }
    }

    private func bar(vertical: Bool) -> some View {
        BrutalistHUDView(
            state: state,
            vertical: vertical,
            onStopRecording: onToggleRecording,
            onUndoCancel: onUndoCancel,
            onRetry: onRetry
        )
    }

    private func expansionTransition(anchor: UnitPoint) -> AnyTransition {
        reduceMotion
            ? .identity
            : .opacity.combined(with: .scale(scale: 0.6, anchor: anchor))
    }

    // The idle pill is deliberately tiny and faint: just enough to show the
    // app is alive without claiming screen space. `edge` is the window edge
    // a horizontal pill keeps its 2pt gap from.
    private func idlePill(vertical: Bool, edge: Edge.Set) -> some View {
        let dots = ForEach(0..<3, id: \.self) { _ in
            Rectangle()
                .fill(Brutal.yellow)
                .frame(width: 2, height: 2)
        }
        let long = IndicatorMetrics.idleLength
        let short = IndicatorMetrics.idleThickness
        return Group {
            if vertical {
                VStack(spacing: 3) { dots }
            } else {
                HStack(spacing: 3) { dots }
            }
        }
        .frame(width: vertical ? short : long, height: vertical ? long : short)
        .background(Brutal.ink)
        .opacity(0.8)
        .padding(edge, vertical ? 0 : 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(IndicatorAccessibility.label(for: .idle, elapsed: 0))
    }
}
