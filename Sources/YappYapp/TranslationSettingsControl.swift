import SwiftUI

// TRANSLATION (round 2): SETUP > DICTATION > TRANSLATE TO. One dropdown of
// target languages, then one honest line about which model does it and
// whether it is on this Mac, with the download, its progress and a cancel.
// The same status row as CleanupSettingsControl, so both read alike.
struct TranslationSettingsControl: View {
    @Binding var target: String
    let plan: TranslationPlan
    let readiness: TranslationReadiness
    let onDownload: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: BrutalControl.innerSpacing) {
            BrutalRowLabel(L10n.tr("TRANSLATE TO"))

            BrutalPicker(
                choices: TranslationCatalog.targets.map { option in
                    BrutalChoice(
                        value: option.rawValue,
                        title: option.label,
                        accessibilityLabel: option == .off ? L10n.tr("Translation off") : L10n.tr("Translate to %@", option.label.capitalized)
                    )
                },
                selection: TranslationTarget.resolve(target).rawValue,
                accessibilityLabel: L10n.tr("Translate to"),
                hint: L10n.tr("Your dictation goes out in this language")
            ) { target = $0 }

            if readiness == .off {
                BrutalCaption(readiness.detail(substitutedForWhisper: false))
            } else {
                statusRow
            }
        }
    }

    private var statusFill: Color {
        switch readiness {
        case .ready, .whisperBuiltIn: Brutal.green
        case .downloading, .verifying: Brutal.blue
        case .needsRuntime, .needsModel, .failed: Brutal.yellow
        case .off: Brutal.card
        }
    }

    private var statusText: Color {
        switch readiness {
        case .ready, .whisperBuiltIn: Brutal.contentOnGreen
        case .downloading, .verifying: Brutal.contentOnBlue
        default: Brutal.ink
        }
    }

    private var isPlainReady: Bool {
        if case .ready = readiness { return !plan.substitutedForWhisper }
        return false
    }

    private var modelName: String {
        readiness.modelID.map { TranslationCatalog.model($0).name.uppercased() } ?? ""
    }

    @ViewBuilder
    private var statusRow: some View {
        VStack(alignment: .leading, spacing: BrutalControl.innerSpacing) {
            HStack(spacing: 8) {
                // A status, not a button: flat state fill, no drop.
                Text("\(modelName) · \(readiness.headline)")
                    .brutalText(.control)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, 8)
                    .frame(minHeight: BrutalControl.height)
                    .background(statusFill)
                    .foregroundStyle(statusText)
                    .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))
                    .accessibilityLabel(L10n.tr("Translation status: %@", readiness.detail(substitutedForWhisper: plan.substitutedForWhisper)))

                Spacer(minLength: 0)

                if readiness.canCancel {
                    BrutalActionButton(
                        title: L10n.tr("CANCEL"),
                        accessibilityLabel: L10n.tr("CANCEL").capitalized,
                        hint: L10n.tr("Stops the translation model download"),
                        action: onCancel
                    )
                } else if readiness.canDownload {
                    BrutalActionButton(
                        title: readiness.isFailed ? L10n.tr("RETRY") : L10n.tr("DOWNLOAD"),
                        accessibilityLabel: (readiness.isFailed ? L10n.tr("RETRY") : L10n.tr("DOWNLOAD")).capitalized,
                        hint: L10n.tr("Downloads the translation model"),
                        action: onDownload
                    )
                }
            }

            if case .downloading(_, let fraction) = readiness {
                CleanupProgressBar(fraction: fraction)
                    .frame(height: 8)
                    .accessibilityLabel(L10n.tr("Translation model download"))
                    .accessibilityValue(fraction.map { L10n.tr("%@ percent", "\(Int($0 * 100))") } ?? L10n.tr("Starting"))
            }

            // Like the cleanup row: a ready badge says it all, unless the
            // caption explains that a model stands in for Whisper.
            if !isPlainReady {
                BrutalCaption(
                    readiness.detail(substitutedForWhisper: plan.substitutedForWhisper),
                    tone: readiness == .needsRuntime(readiness.modelID ?? .hyMT2Fast) ? .warning : .normal
                )
            }
        }
    }
}
