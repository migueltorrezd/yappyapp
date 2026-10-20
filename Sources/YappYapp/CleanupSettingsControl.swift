import SwiftUI

// LLM-CLEANUP (missing feature 4): the cleanup mode picker in SETUP, with one
// honest status line under it: whether the runtime and model are there, the
// download with its progress and a cancel, or why cleanup cannot run. Lives
// in its own file so the shared settings tab only swaps two rows for one.
struct CleanupSettingsControl: View {
    @Binding var mode: CleanupMode
    let readiness: CleanupReadiness
    let onDownload: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: BrutalControl.innerSpacing) {
            BrutalRowLabel(L10n.tr("CLEANUP"))

            // CLEANUP-EXPLAINED: what cleanup is, before the choice.
            BrutalCaption(CleanupMode.explainer)

            BrutalSegmented(
                choices: CleanupMode.allCases.map { option in
                    BrutalChoice(
                        value: option,
                        title: option.label,
                        accessibilityLabel: L10n.tr("Cleanup %@", option.label.lowercased()),
                        hint: option.summary
                    )
                },
                selection: mode,
                hint: mode.summary
            ) { mode = $0 }

            CleanupModeExplainer(mode: mode)

            if mode.usesModel {
                statusRow
            }
        }
        .help(L10n.tr("Cleans up your text on this Mac with a small local model (Qwen 1.5B). Adds 1 to 2 seconds and about 1.3 GB of memory while it works. If anything looks off, you get your words as spoken."))
    }

    private var statusFill: Color {
        switch readiness {
        case .ready: Brutal.green
        case .downloading, .verifying: Brutal.blue
        case .needsRuntime, .needsModel, .failed: Brutal.yellow
        case .off: Brutal.card
        }
    }

    private var statusText: Color {
        switch readiness {
        case .ready: Brutal.contentOnGreen
        case .downloading, .verifying: Brutal.contentOnBlue
        default: Brutal.ink
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        VStack(alignment: .leading, spacing: BrutalControl.innerSpacing) {
            HStack(spacing: 8) {
                // A status, not a button: flat state fill, no drop.
                Text(readiness.headline)
                    .brutalText(.control)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, 8)
                    .frame(minHeight: BrutalControl.height)
                    .background(statusFill)
                    .foregroundStyle(statusText)
                    .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))
                    .accessibilityLabel(L10n.tr("Cleanup status: %@", readiness.detail))

                Spacer(minLength: 0)

                if readiness.canCancel {
                    BrutalActionButton(title: L10n.tr("CANCEL"), accessibilityLabel: L10n.tr("CANCEL").capitalized, hint: L10n.tr("Stops the cleanup model download"), action: onCancel)
                } else if readiness.canDownload {
                    BrutalActionButton(
                        title: isFailed ? L10n.tr("RETRY") : L10n.tr("DOWNLOAD"),
                        accessibilityLabel: (isFailed ? L10n.tr("RETRY") : L10n.tr("DOWNLOAD")).capitalized,
                        hint: L10n.tr("Downloads the cleanup model"),
                        action: onDownload
                    )
                }
            }

            if case .downloading(let fraction) = readiness {
                CleanupProgressBar(fraction: fraction)
                    .frame(height: 8)
                    .accessibilityLabel(L10n.tr("Cleanup model download"))
                    .accessibilityValue(fraction.map { L10n.tr("%@ percent", "\(Int($0 * 100))") } ?? L10n.tr("Starting"))
            }

            if readiness != .ready {
                BrutalCaption(readiness.detail, tone: readiness == .needsRuntime ? .warning : .normal)
            }
        }
    }

    private var isFailed: Bool {
        if case .failed = readiness { return true }
        return false
    }
}

/// CLEANUP-EXPLAINED: what the chosen mode does in one line, then a tiny
/// "you say, it writes" example. Shared by SETUP and onboarding.
struct CleanupModeExplainer: View {
    let mode: CleanupMode

    var body: some View {
        SaidWrittenExplainer(summary: mode.summary, example: mode.example)
    }
}

/// One caption line, then a tiny "you say, it writes" box. Used by the
/// cleanup modes and the NUMBERS choices.
struct SaidWrittenExplainer: View {
    let summary: String
    let example: (said: String, written: String)

    var body: some View {
        VStack(alignment: .leading, spacing: BrutalControl.innerSpacing) {
            BrutalCaption(summary)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: BrutalControl.lineSpacing + 2) {
                GridRow {
                    exampleLabel(L10n.tr("YOU SAY"))
                    exampleText("\u{201C}\(example.said)\u{201D}", emphasized: false)
                }
                GridRow {
                    exampleLabel(L10n.tr("IT WRITES"))
                    exampleText(example.written, emphasized: true)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, BrutalControl.innerSpacing)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Brutal.card)
            .overlay(Rectangle().strokeBorder(Brutal.ink.opacity(0.25), lineWidth: 1))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.tr("Example: you say %@. It writes %@.", example.said, example.written.replacingOccurrences(of: "\n", with: ", ")))
        }
    }

    private func exampleLabel(_ text: String) -> some View {
        Text(text)
            .brutalText(.control)
            .foregroundStyle(Brutal.textSecondary)
            .fixedSize()
    }

    private func exampleText(_ text: String, emphasized: Bool) -> some View {
        Text(text)
            .brutalText(.caption)
            .foregroundStyle(emphasized ? Brutal.ink : Brutal.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Flat fill inside a 2pt ink frame. No animation, no gradient.
struct CleanupProgressBar: View {
    let fraction: Double?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle().fill(Brutal.card)
                Rectangle()
                    .fill(Brutal.blue)
                    .frame(width: proxy.size.width * CGFloat(min(max(fraction ?? 0, 0), 1)))
            }
            .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))
        }
    }
}
