import SwiftUI

// MODELS (round 2): the SCAN MY MAC card at the top of the tab and the rows
// of the TRANSLATION family. Same anatomy as the speech model rows: a choice
// mark, the name and its badge, one summary line, and the status or action
// on the right as a sibling control.

// MARK: - SCAN MY MAC

/// Whether a recommended choice is already the one in use.
enum RecommendationStatus {
    static func isInUse(_ choice: RecommendedChoice, config: AppConfig, selectedModelID: String) -> Bool {
        switch choice {
        case .speech(let id): selectedModelID == id
        case .cleanup(let mode): config.cleanup == mode
        case .translation(let id): config.translationModelID == id
        case .none: false
        }
    }
}

struct ModelScanCard: View {
    let scan: HardwareScan?
    let config: AppConfig
    let selectedModelID: String
    let onScan: () -> Void
    let onApply: (RecommendedChoice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let scan {
                header(scan.profile.summaryLine.uppercased())
                ForEach(Array(scan.recommendations.enumerated()), id: \.offset) { index, recommendation in
                    if index > 0 {
                        Rectangle().fill(Brutal.ink).frame(height: Brutal.border)
                    }
                    RecommendationRow(
                        recommendation: recommendation,
                        inUse: RecommendationStatus.isInUse(recommendation.choice, config: config, selectedModelID: selectedModelID),
                        onApply: { onApply(recommendation.choice) }
                    )
                }
            } else {
                HStack(alignment: .center, spacing: 10) {
                    scanButton(L10n.tr("SCAN MY MAC"))
                    Text(L10n.tr("Reads the chip, memory and free space, then picks models that fit. Nothing leaves this Mac."))
                        .brutalFont(size: 10.5, weight: .semibold, relativeTo: .caption)
                        .foregroundStyle(Brutal.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(11)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brutal.card)
        .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))
        .background(Rectangle().fill(Brutal.ink).offset(x: Brutal.drop, y: Brutal.drop))
    }

    /// What was detected, in the ink bar, with SCAN AGAIN beside it.
    private func header(_ detected: String) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(detected)
                .brutalText(.sectionTitle)
                .foregroundStyle(Brutal.paper)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(L10n.tr("Detected: %@", detected))
            Button(action: onScan) {
                Text(L10n.tr("SCAN AGAIN"))
                    .brutalText(.control)
                    .foregroundStyle(Brutal.yellow)
                    .fixedSize()
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .brutalInteractive(
                label: L10n.tr("Scan my Mac again"),
                hint: L10n.tr("Reads this Mac again and updates the picks"),
                hitExpansion: 10
            )
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        .background(Brutal.ink)
    }

    private func scanButton(_ title: String) -> some View {
        Button(action: onScan) {
            Text(title)
                .brutalText(.control)
                .foregroundStyle(Brutal.paper)
                .padding(.horizontal, 10)
                .frame(minHeight: BrutalControl.height)
                .background(Brutal.blue)
                .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))
                .fixedSize()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .brutalInteractive(
            label: L10n.tr("Scan my Mac"),
            hint: L10n.tr("Reads this Mac and suggests a speech, cleanup and translation model"),
            hitExpansion: 9
        )
    }
}

private struct RecommendationRow: View {
    let recommendation: ModelRecommendation
    let inUse: Bool
    let onApply: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(recommendation.kind.label)
                        .brutalFont(size: 8, weight: .black, relativeTo: .caption2)
                        .kerning(0.5)
                        .foregroundStyle(Brutal.paper)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Brutal.ink)
                        .fixedSize()
                    Text(recommendation.title.uppercased())
                        .brutalFont(size: 12, weight: .black, relativeTo: .callout)
                        .kerning(0.5)
                        .foregroundStyle(Brutal.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(recommendation.reason)
                    .brutalFont(size: 10.5, weight: .semibold, relativeTo: .caption)
                    .foregroundStyle(Brutal.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !inUse, recommendation.choice != .none, let bytes = recommendation.downloadBytes {
                    Text(L10n.tr("DOWNLOADS %@", ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)))
                        .brutalFont(size: 9, weight: .black, relativeTo: .caption2)
                        .foregroundStyle(Brutal.textTertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)

            trailing
        }
        .padding(11)
    }

    @ViewBuilder
    private var trailing: some View {
        if recommendation.choice == .none {
            EmptyView()
        } else if inUse {
            Text(L10n.tr("IN USE"))
                .brutalFont(size: 9, weight: .black, design: .monospaced, relativeTo: .caption)
                .foregroundStyle(Brutal.successText)
                .fixedSize()
        } else {
            Button(action: onApply) {
                Text(L10n.tr("USE THIS"))
                    .brutalText(.control)
                    .foregroundStyle(Brutal.paper)
                    .padding(.horizontal, 8)
                    .frame(minHeight: BrutalControl.height)
                    .background(Brutal.blue)
                    .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))
                    .fixedSize()
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .brutalInteractive(
                label: L10n.tr("Use %@", recommendation.title),
                hint: recommendation.downloadBytes == nil
                    ? L10n.tr("Switches to this pick")
                    : L10n.tr("Switches to this pick and downloads it"),
                hitExpansion: 10
            )
        }
    }
}

// MARK: - TRANSLATION rows

/// One chip vocabulary for a translation row.
enum TranslationRowChip: Equatable {
    case builtIn
    case download
    case downloading(percent: Int?)
    case verifying
    case downloaded
    case inUse
    case failed
    case downloadsOff

    static func state(
        model: TranslationModel,
        isSelected: Bool,
        snapshot: TranslationModelsSnapshot,
        downloadsAllowed: Bool
    ) -> TranslationRowChip {
        guard model.download != nil else { return isSelected ? .inUse : .builtIn }
        switch snapshot.phase(model.id) {
        case .downloading(let fraction): return .downloading(percent: fraction.map { Int($0 * 100) })
        case .verifying: return .verifying
        case .failed: return .failed
        case .idle: break
        }
        if snapshot.verified.contains(model.id) { return isSelected ? .inUse : .downloaded }
        if snapshot.installed.contains(model.id) { return .verifying }
        return downloadsAllowed ? .download : .downloadsOff
    }

    var text: String {
        switch self {
        case .builtIn: L10n.tr("NO DOWNLOAD")
        case .download: L10n.tr("DOWNLOAD")
        case .downloading(let percent): percent.map { "\($0)%" } ?? L10n.tr("DOWNLOADING")
        case .verifying: L10n.tr("VERIFYING")
        case .downloaded: L10n.tr("DOWNLOADED")
        case .inUse: L10n.tr("IN USE")
        case .failed: L10n.tr("FAILED")
        case .downloadsOff: L10n.tr("Downloads off").uppercased()
        }
    }

    /// A downloaded model can be deleted to get the space back.
    var canDelete: Bool { self == .downloaded || self == .inUse }
}

struct TranslationModelRow: View {
    let model: TranslationModel
    let isSelected: Bool
    let chip: TranslationRowChip
    var failure: String?
    let onSelect: () -> Void
    let onDownload: () -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void

    @State private var confirmingDelete = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: onSelect) {
                HStack(alignment: .top, spacing: 10) {
                    ModelChoiceMark(isSelected: isSelected)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(model.name.uppercased())
                                .brutalFont(size: 12, weight: .black, relativeTo: .callout)
                                .kerning(0.5)
                                .foregroundStyle(Brutal.ink)
                            Text(L10n.tr(model.badge))
                                .brutalFont(size: 8, weight: .black, relativeTo: .caption2)
                                .kerning(0.5)
                                .foregroundStyle(Brutal.paper)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(model.id == .hyMT2Best ? Brutal.blue : Brutal.ink)
                            Spacer()
                        }
                        Text(L10n.tr(model.summary))
                            .brutalFont(size: 10.5, weight: .semibold, relativeTo: .caption)
                            .foregroundStyle(Brutal.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if chip == .failed, let failure {
                            Text(failure)
                                .brutalFont(size: 9, weight: .black, relativeTo: .caption2)
                                .foregroundStyle(Brutal.dangerText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .brutalInteractive(
                label: model.name,
                hint: L10n.tr("Translates your dictations with this model"),
                value: "\(isSelected ? L10n.tr("Selected") : L10n.tr("Not selected")), \(chip.text)",
                selected: isSelected,
                hitExpansion: 0
            )

            VStack(alignment: .trailing, spacing: 4) {
                trailing
                if let size = model.sizeLabel {
                    Text(size)
                        .brutalFont(size: 8.5, weight: .bold, design: .monospaced, relativeTo: .caption2)
                        .foregroundStyle(Brutal.textTertiary)
                }
                if chip.canDelete {
                    deleteButton
                }
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Brutal.yellow : Brutal.card)
        .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))
        .background(Rectangle().fill(Brutal.ink).offset(x: Brutal.drop, y: Brutal.drop))
    }

    private func chipText(_ color: Color) -> some View {
        Text(chip.text)
            .brutalFont(size: 9, weight: .black, design: .monospaced, relativeTo: .caption)
            .foregroundStyle(color)
            .multilineTextAlignment(.trailing)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var trailing: some View {
        switch chip {
        case .builtIn, .verifying:
            chipText(isSelected ? Brutal.contentOnYellow : Brutal.textTertiary)
        case .inUse:
            chipText(isSelected ? Brutal.contentOnYellow : Brutal.successText)
        case .downloaded:
            chipText(Brutal.successText)
        case .downloadsOff:
            chipText(Brutal.textTertiary)
                .frame(maxWidth: 84, alignment: .trailing)
        case .downloading(let percent):
            HStack(spacing: 5) {
                chipText(isSelected ? Brutal.contentOnYellow : Brutal.blue)
                Button(action: onCancel) {
                    Text(L10n.tr("X"))
                        .brutalFont(size: 9, weight: .black, relativeTo: .caption)
                        .foregroundStyle(Brutal.contentOnRed)
                        .frame(width: 18, height: 18)
                        .background(Brutal.red)
                        .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: 1.5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.tr("Cancel download"))
                .brutalInteractive(
                    label: L10n.tr("Cancel %@ download", model.name),
                    hint: L10n.tr("Stops the current model download"),
                    value: percent.map { L10n.tr("%@ percent", "\($0)") } ?? L10n.tr("Starting"),
                    hitExpansion: 13
                )
            }
        case .failed:
            VStack(alignment: .trailing, spacing: 4) {
                chipText(Brutal.dangerText)
                actionButton(L10n.tr("RETRY"), label: L10n.tr("Retry %@ download", model.name))
            }
        case .download:
            actionButton(L10n.tr("DOWNLOAD"), label: L10n.tr("Download %@", model.name))
        }
    }

    private func actionButton(_ title: String, label: String) -> some View {
        Button(action: onDownload) {
            Text(title)
                .brutalFont(size: 9, weight: .black, relativeTo: .caption)
                .kerning(0.6)
                .foregroundStyle(Brutal.paper)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Brutal.blue)
                .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: 1.5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .brutalInteractive(
            label: label,
            hint: L10n.tr("Downloads this translation model from Hugging Face"),
            value: model.sizeLabel ?? "",
            hitExpansion: 10
        )
    }

    /// Two clicks: DELETE, then SURE? within the same row.
    private var deleteButton: some View {
        Button {
            if confirmingDelete {
                confirmingDelete = false
                onDelete()
            } else {
                confirmingDelete = true
            }
        } label: {
            Text(confirmingDelete ? L10n.tr("SURE? DELETE") : L10n.tr("DELETE"))
                .brutalFont(size: 8.5, weight: .black, relativeTo: .caption2)
                .kerning(0.5)
                .foregroundStyle(Brutal.dangerText)
                .fixedSize()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .brutalInteractive(
            label: L10n.tr("Delete %@", model.name),
            hint: confirmingDelete
                ? L10n.tr("Click again to delete the downloaded file")
                : L10n.tr("Deletes the downloaded file. You can download it again later."),
            hitExpansion: 10
        )
    }
}
