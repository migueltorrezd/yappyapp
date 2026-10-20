import SwiftUI

/// The active indicator: a compact Brutal bar with no words in it. A state
/// square (flat color plus one glyph), the level meter, and an icon button
/// only when an action is waiting (KEEP after a cancel, RETRY after a failed
/// transcription). Horizontal at the top or bottom of the screen, vertical
/// on the left or right edge. VoiceOver reads the state, reason and badge.
struct BrutalistHUDView: View {
    @ObservedObject var state: YappYappState
    let vertical: Bool
    let onStopRecording: () -> Void
    let onUndoCancel: () -> Void
    let onRetry: () -> Void

    init(
        state: YappYappState,
        vertical: Bool = false,
        onStopRecording: @escaping () -> Void = {},
        onUndoCancel: @escaping () -> Void = {},
        onRetry: @escaping () -> Void = {}
    ) {
        self.state = state
        self.vertical = vertical
        self.onStopRecording = onStopRecording
        self.onUndoCancel = onUndoCancel
        self.onRetry = onRetry
    }

    /// The bar's frame, hard shadow included.
    static func size(vertical: Bool) -> CGSize {
        let long = IndicatorMetrics.length + IndicatorMetrics.drop
        let short = IndicatorMetrics.thickness + IndicatorMetrics.drop
        return vertical ? CGSize(width: short, height: long) : CGSize(width: long, height: short)
    }

    // YA-54: seconds left before the time-limit auto-stop, inside the last ten.
    private var countdown: Int? {
        guard state.phase == .recording else { return nil }
        return HUDPresenter.countdown(
            elapsed: state.recordingSeconds,
            limit: HUDPresenter.limitSeconds(for: state.config)
        )
    }

    // YA-03 / YA-19 / YA-54: the reason or note, spoken, never drawn.
    private var caption: String? {
        HUDPresenter.caption(
            for: state.phase,
            escCancels: state.config.escCancelsRecording && state.config.shortcuts.chord(for: .cancel) != nil,
            countdown: countdown,
            note: state.hudNote,
            retryShown: RetryLastPresenter.offersRetry(phase: state.phase, retryAvailable: state.retryAvailable),
            pastedIn: state.pastedElapsedLabel
        )
    }

    private var model: IndicatorState {
        IndicatorState.make(
            phase: state.phase,
            isCleaning: HomeScreenPresenter.isCleaning(phase: state.phase, hudNote: state.hudNote),
            retryAvailable: state.retryAvailable
        )
    }

    private var stack: AnyLayout {
        vertical ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
    }

    var body: some View {
        let model = model
        let thickness = IndicatorMetrics.thickness
        let size = Self.size(vertical: vertical)

        stack {
            stateSquare(model)
                .frame(width: thickness, height: thickness)

            meter(model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Brutal.ink)
                .contentShape(Rectangle())
                .onTapGesture {
                    // The whole bar is a stop target while listening.
                    if state.phase == .recording { onStopRecording() }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(IndicatorAccessibility.label(for: state.phase, elapsed: state.recordingSeconds))
                .accessibilityValue(IndicatorAccessibility.value(caption: caption, badge: state.dictationBadge, phase: state.phase))
                .accessibilityAddTraits(state.phase == .recording ? .updatesFrequently : [])

            if let action = model.action {
                actionButton(action)
                    .frame(width: thickness, height: thickness)
            }
        }
        .frame(width: size.width - IndicatorMetrics.drop, height: size.height - IndicatorMetrics.drop)
        .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))
        .background(Rectangle().fill(Brutal.ink).offset(x: IndicatorMetrics.drop, y: IndicatorMetrics.drop))
        .padding(.trailing, IndicatorMetrics.drop)
        .padding(.bottom, IndicatorMetrics.drop)
        .frame(width: size.width, height: size.height)
        .accessibilityElement(children: .contain)
    }

    // MARK: - State square

    @ViewBuilder
    private func stateSquare(_ model: IndicatorState) -> some View {
        ZStack {
            Self.color(model.fill)

            if state.phase == .recording {
                Button(action: onStopRecording) {
                    BlinkingSquare()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help(L10n.tr("Stop recording"))
                .accessibilityLabel(L10n.tr("Stop recording"))
                .accessibilityHint(L10n.tr("Stops dictation and transcribes the recorded audio"))
                .accessibilityValue(formatted(state.recordingSeconds))
            } else if let symbol = model.symbol {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(Self.content(on: model.fill))
                    .accessibilityHidden(true)
            }
        }
    }

    // MARK: - Meter

    @ViewBuilder
    private func meter(_ model: IndicatorState) -> some View {
        switch model.meter {
        case .live:
            IndicatorLevelMeter(
                levels: state.levelHistory,
                tint: countdown == nil ? Brutal.yellow : Brutal.red,
                vertical: vertical
            )
        case .sweep:
            IndicatorSweep(tint: Brutal.yellow, vertical: vertical)
        case .rest:
            IndicatorLevelMeter(levels: [], tint: Self.restTint(model.fill), vertical: vertical)
        }
    }

    // MARK: - Action

    private func actionButton(_ action: IndicatorState.Action) -> some View {
        let title: String
        let hint: String
        let run: () -> Void
        switch action {
        case .keep:
            // YA-19: the canceled audio is kept for a few seconds; KEEP
            // transcribes it after all.
            title = L10n.tr("Keep it")
            hint = L10n.tr("Transcribes and pastes the dictation you canceled")
            run = onUndoCancel
        case .retry:
            // COMMANDS: the failed dictation's audio was kept; RETRY runs it again.
            title = L10n.tr("Retry")
            hint = L10n.tr("Transcribes the failed dictation again")
            run = onRetry
        }
        return Button(action: run) {
            ZStack {
                Brutal.blue
                Image(systemName: IndicatorState.symbol(for: action))
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(Brutal.contentOnBlue)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(title)
        .accessibilityLabel(title)
        .accessibilityHint(hint)
    }

    // MARK: - Colors

    static func color(_ fill: IndicatorState.Fill) -> Color {
        switch fill {
        case .red: Brutal.red
        case .blue: Brutal.blue
        case .green: Brutal.green
        case .yellow: Brutal.yellow
        case .paper: Brutal.paper
        case .ink: Brutal.ink
        }
    }

    static func content(on fill: IndicatorState.Fill) -> Color {
        switch fill {
        case .red: Brutal.contentOnRed
        case .blue: Brutal.contentOnBlue
        case .green: Brutal.contentOnGreen
        case .yellow: Brutal.contentOnYellow
        case .paper: Brutal.ink
        case .ink: Brutal.paper
        }
    }

    /// The resting line repeats the state color, so the whole bar reads as
    /// one state at a glance. Ink states rest in faint paper.
    private static func restTint(_ fill: IndicatorState.Fill) -> Color {
        switch fill {
        case .ink, .paper: Brutal.paper.opacity(0.45)
        default: color(fill)
        }
    }

    private func formatted(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// Square level bars that grow across the bar's short side. Empty levels
/// draw the flat resting line.
private struct IndicatorLevelMeter: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let levels: [Double]
    let tint: Color
    let vertical: Bool

    private let count = IndicatorMetrics.meterBarCount
    private let minBar: CGFloat = 2

    var body: some View {
        let visible = Array(levels.suffix(count))
        let padded = Array(repeating: 0.0, count: max(0, count - visible.count)) + visible
        bars(padded.map(length))
            .animation(reduceMotion || levels.isEmpty ? nil : .linear(duration: 1.0 / 24.0), value: levels)
    }

    private func length(_ level: Double) -> CGFloat {
        let amplified = min(1.0, pow(max(0, level), 0.7) * 1.25)
        return minBar + CGFloat(amplified) * (IndicatorMetrics.meterMaxBar - minBar)
    }

    @ViewBuilder
    private func bars(_ lengths: [CGFloat]) -> some View {
        if vertical {
            VStack(spacing: IndicatorMetrics.meterBarSpacing) {
                ForEach(Array(lengths.enumerated()), id: \.offset) { _, value in
                    Rectangle().fill(tint).frame(width: value, height: IndicatorMetrics.meterBarWidth)
                }
            }
        } else {
            HStack(spacing: IndicatorMetrics.meterBarSpacing) {
                ForEach(Array(lengths.enumerated()), id: \.offset) { _, value in
                    Rectangle().fill(tint).frame(width: IndicatorMetrics.meterBarWidth, height: value)
                }
            }
        }
    }
}

/// Indeterminate work: a pulse travels along the meter. Reduce Motion keeps
/// the pulse but freezes it in the middle.
private struct IndicatorSweep: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let tint: Color
    let vertical: Bool

    private let count = IndicatorMetrics.meterBarCount

    var body: some View {
        if reduceMotion {
            sweep(center: Double(count - 1) / 2)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                let time = context.date.timeIntervalSinceReferenceDate
                sweep(center: (time * 14).truncatingRemainder(dividingBy: Double(count)))
            }
        }
    }

    private func sweep(center: Double) -> some View {
        let lengths: [CGFloat] = (0..<count).map { index in
            let raw = abs(Double(index) - center)
            let distance = min(raw, Double(count) - raw)
            let pulse = exp(-distance * distance / 5.0)
            return 2 + CGFloat(pulse) * (IndicatorMetrics.meterMaxBar - 2)
        }
        return Group {
            if vertical {
                VStack(spacing: IndicatorMetrics.meterBarSpacing) {
                    ForEach(0..<count, id: \.self) { index in
                        Rectangle().fill(tint).frame(width: lengths[index], height: IndicatorMetrics.meterBarWidth)
                    }
                }
            } else {
                HStack(spacing: IndicatorMetrics.meterBarSpacing) {
                    ForEach(0..<count, id: \.self) { index in
                        Rectangle().fill(tint).frame(width: IndicatorMetrics.meterBarWidth, height: lengths[index])
                    }
                }
            }
        }
    }
}

private struct BlinkingSquare: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = true

    var body: some View {
        Rectangle()
            .fill(Brutal.contentOnRed)
            .frame(width: 8, height: 8)
            .opacity(visible ? 1 : 0.15)
            .onAppear {
                visible = reduceMotion
            }
            .onChange(of: reduceMotion) { _, shouldReduceMotion in
                visible = shouldReduceMotion
            }
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.5).repeatForever(autoreverses: true),
                value: visible
            )
    }
}
