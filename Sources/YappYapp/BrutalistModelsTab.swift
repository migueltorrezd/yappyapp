import SwiftUI

extension BrutalistPopoverView {
    // MARK: - Models

    var modelsTab: some View {
        VStack(spacing: 10) {
            BrutalScroll {
                VStack(spacing: 10) {
                    // SCAN MY MAC: picks from what the app offers, for this Mac.
                    ModelScanCard(
                        scan: state.hardwareScan,
                        config: state.config,
                        selectedModelID: state.selectedModelID,
                        onScan: onScanMac,
                        onApply: onApplyRecommendation
                    )
                    .padding(.bottom, 8)

                    // MANAGED-PREFS: the profile picks the model; rows stay
                    // visible but selecting is refused in AppDelegate.
                    if state.managedConfigKeys.contains(.selectedModel) {
                        ManagedModelLockedRow()
                    }
                    // Both families sit behind the same collapsible header.
                    let parakeetOptions = state.modelOptions.filter { $0.engine == .parakeet }
                    ModelGroupSection(
                        group: .parakeet,
                        count: parakeetOptions.count,
                        opensByDefault: ModelListPolicy.parakeetOpensByDefault
                    ) {
                        ForEach(parakeetOptions) { option in
                            modelRow(option)
                        }
                    }

                    let whisperOptions = state.modelOptions.filter { $0.engine == .whisper }
                    ModelGroupSection(
                        group: .whisper,
                        count: whisperOptions.count,
                        opensByDefault: ModelListPolicy.whisperOpensByDefault(
                            selectedID: state.selectedModelID,
                            downloads: state.modelDownloads,
                            errors: state.modelDownloadErrors
                        )
                    ) {
                        ForEach(whisperOptions) { option in
                            modelRow(option)
                        }
                    }
                    .padding(.top, 8)

                    // QWEN3-ASR: 52 languages, for what Parakeet does not cover.
                    let qwenOptions = state.modelOptions.filter { $0.engine == .qwen3asr }
                    ModelGroupSection(
                        group: .qwen3asr,
                        count: qwenOptions.count,
                        opensByDefault: ModelListPolicy.qwen3ASROpensByDefault(
                            selectedID: state.selectedModelID,
                            downloads: state.modelDownloads,
                            errors: state.modelDownloadErrors
                        )
                    ) {
                        ForEach(qwenOptions) { option in
                            modelRow(option)
                        }
                    }
                    .padding(.top, 8)

                    // TRANSLATION (round 2): which model translates, with
                    // size, speed, download state and the in-use mark.
                    ModelGroupSection(
                        group: .translation,
                        count: TranslationCatalog.models.count,
                        opensByDefault: ModelListPolicy.translationOpensByDefault(
                            target: state.config.translation,
                            snapshot: state.translationModels
                        )
                    ) {
                        ForEach(TranslationCatalog.models) { model in
                            translationRow(model)
                        }
                    }
                    .padding(.top, 8)
                }
                .padding(.bottom, Brutal.drop)
                .padding(.trailing, Brutal.drop)
            }
            .scrollIndicators(.never)

            Text(modelsFootnote)
                .brutalFont(size: 8.5, weight: .bold, relativeTo: .caption2)
                .kerning(0.6)
                .foregroundStyle(Brutal.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func modelRow(_ option: ModelOption) -> some View {
        BrutalModelRow(
            option: option,
            isSelected: state.selectedModelID == option.id,
            isRecommended: ModelListPolicy.isRecommended(option),
            downloadProgress: state.modelDownloads[option.id],
            downloadsAllowed: state.config.allowModelDownloads,
            downloadsOffStatus: ModelDownloadPresenter.downloadsOffStatus(
                lockedByAdmin: state.managedConfigKeys.contains(.allowModelDownloads)
            ),
            downloadError: state.modelDownloadErrors[option.id],
            onSelect: { onSelectModel(option.id) },
            onDownload: { onDownloadModel(option.id) },
            onCancelDownload: { onCancelDownload(option.id) },
            // QWEN3-ASR rows can give their disk space back.
            onDelete: option.engine == .qwen3asr ? { onDeleteModel(option.id) } : nil
        )
    }

    private func translationRow(_ model: TranslationModel) -> some View {
        let isSelected = state.config.translationModelID == model.id
        let failure: String? = {
            if case .failed(let message) = state.translationModels.phase(model.id) { return message }
            return nil
        }()
        return TranslationModelRow(
            model: model,
            isSelected: isSelected,
            chip: TranslationRowChip.state(
                model: model,
                isSelected: isSelected,
                snapshot: state.translationModels,
                downloadsAllowed: state.config.allowModelDownloads
            ),
            failure: failure,
            onSelect: { onSelectTranslationModel(model.id) },
            onDownload: { onDownloadTranslationModel(model.id) },
            onCancel: { onCancelTranslationDownload(model.id) },
            onDelete: { onDeleteTranslationModel(model.id) }
        )
    }

    private var modelsFootnote: String {
        if state.config.allowModelDownloads {
            return L10n.tr("MODELS DOWNLOAD ONCE FROM HUGGING FACE. AFTER THAT, EVERYTHING RUNS ON THIS MAC.")
        }
        return ModelDownloadPresenter.downloadsOffStatus(
            lockedByAdmin: state.managedConfigKeys.contains(.allowModelDownloads)
        ).uppercased()
    }

/// One model family (Parakeet, Whisper, Qwen3-ASR, Translation) behind a full-width ink header that
/// opens and closes it. Parakeet starts open; Whisper starts closed unless one
/// of its models is in use, downloading or failed. Either can be toggled.
private struct ModelGroupSection<Rows: View>: View {
    let group: ModelGroup
    let count: Int
    let opensByDefault: Bool
    @ViewBuilder let rows: () -> Rows
    @State private var userChoice: Bool?

    private var isOpen: Bool {
        ModelGroupDisclosure.isOpen(userChoice: userChoice, opensByDefault: opensByDefault)
    }

    var body: some View {
        VStack(spacing: 10) {
            Button {
                userChoice = !isOpen
            } label: {
                ModelGroupHeader(group: group, count: count, isOpen: isOpen)
            }
            .buttonStyle(.plain)
            .brutalInteractive(
                label: group.accessibilityLabel,
                hint: isOpen ? group.hideHint : group.showHint,
                value: isOpen ? L10n.tr("Expanded") : L10n.tr("Collapsed"),
                hitExpansion: 5
            )
            if isOpen {
                rows()
            }
        }
    }
}

/// The header bar itself: family and count on the left, what it is for in
/// a quieter line, and the open/closed chevron on the right.
struct ModelGroupHeader: View {
    let group: ModelGroup
    let count: Int
    let isOpen: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(group.title(count: count))
                .brutalFont(size: 10, weight: .black, relativeTo: .caption)
                .kerning(1)
                .foregroundStyle(Brutal.paper)
                .fixedSize()

            // One line in every language and text size: short copy, and at
            // the largest sizes it shrinks a little rather than wrap.
            Text(group.detail)
                .brutalFont(size: 8.5, weight: .black, relativeTo: .caption2)
                .kerning(0.6)
                .foregroundStyle(Brutal.yellow)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(ModelGroupDisclosure.chevron(isOpen: isOpen))
                .brutalFont(size: 10, weight: .black, relativeTo: .caption)
                .foregroundStyle(Brutal.paper)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        .background(Brutal.ink)
        .contentShape(Rectangle())
    }
}

private struct BrutalModelRow: View {
    let option: ModelOption
    let isSelected: Bool
    var isRecommended = false
    let downloadProgress: Double?
    let downloadsAllowed: Bool
    let downloadsOffStatus: String
    // YA-34: the last failure for this model, in plain words.
    var downloadError: String?
    let onSelect: () -> Void
    let onDownload: () -> Void
    let onCancelDownload: () -> Void
    /// QWEN3-ASR: DELETE under the size of a downloaded row not in use.
    var onDelete: (() -> Void)? = nil

    @State private var confirmingDelete = false

    private var chip: ModelRowChip {
        ModelRowChip.state(
            isInstalled: option.isInstalled,
            isSelected: isSelected,
            downloadProgress: downloadProgress,
            downloadError: downloadError,
            downloadsAllowed: downloadsAllowed
        )
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: onSelect) {
                HStack(alignment: .top, spacing: 10) {
                    ModelChoiceMark(isSelected: isSelected)
                        .padding(.top, 1)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(option.name.uppercased())
                                .brutalFont(size: 12, weight: .black, relativeTo: .callout)
                                .kerning(0.5)
                                .foregroundStyle(Brutal.ink)

                            // The recommended model trades its badge for the tag.
                            Text(isRecommended ? L10n.tr("RECOMMENDED") : L10n.tr(option.badge).uppercased())
                                .brutalFont(size: 8, weight: .black, relativeTo: .caption2)
                                .kerning(0.5)
                                .foregroundStyle(Brutal.paper)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(isRecommended ? Brutal.blue : Brutal.ink)

                            Spacer()
                        }

                        Text(L10n.tr(option.summary))
                            .brutalFont(size: 10.5, weight: .semibold, relativeTo: .caption)
                            .foregroundStyle(Brutal.textSecondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)

                        if let note = ModelRowStatus.note(
                            isInstalled: option.isInstalled,
                            downloadsAllowed: downloadsAllowed,
                            downloadError: downloadProgress == nil ? downloadError : nil
                        ) {
                            Text(note.text)
                                .brutalFont(size: 9, weight: .black, relativeTo: .caption2)
                                .foregroundStyle(note.isError ? Brutal.dangerText : Brutal.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!modelSelectionEnabled)
            .brutalInteractive(
                label: option.name,
                hint: modelSelectionHint,
                value: modelAccessibilityValue,
                selected: isSelected,
                hitExpansion: 0
            )

            VStack(alignment: .trailing, spacing: 4) {
                trailingStatus
                if let size = option.sizeLabel {
                    Text(size)
                        .brutalFont(size: 8.5, weight: .bold, design: .monospaced, relativeTo: .caption2)
                        .foregroundStyle(Brutal.textTertiary)
                }
                if let onDelete, ModelRowDelete.isOffered(isInstalled: option.isInstalled, isSelected: isSelected, downloadProgress: downloadProgress) {
                    deleteButton(onDelete)
                }
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Brutal.yellow : Brutal.card)
        .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))
        .background(Rectangle().fill(Brutal.ink).offset(x: Brutal.drop, y: Brutal.drop))
    }

    // YA-75: a downloading row stays enabled so it does not look disabled; a
    // second click is a no-op because the download is already in flight.
    private var modelSelectionEnabled: Bool {
        option.isInstalled || downloadsAllowed
    }

    private var modelSelectionHint: String {
        if option.isInstalled {
            return L10n.tr("Selects this local transcription model")
        }
        if downloadProgress != nil {
            return L10n.tr("Download is already in progress")
        }
        if downloadsAllowed {
            return L10n.tr("Starts this model download")
        }
        return downloadsOffStatus
    }

    private var modelAccessibilityValue: String {
        var parts = [isSelected ? L10n.tr("Selected") : L10n.tr("Not selected")]
        switch chip {
        case .preparing: parts.append(L10n.tr("Preparing"))
        case .downloading(let percent): parts.append(L10n.tr("Downloading %@ percent", "\(percent)"))
        case .downloaded, .inUse: parts.append(L10n.tr("Downloaded"))
        case .failed: parts.append(L10n.tr("Download failed"))
        case .download: parts.append(L10n.tr("Download available"))
        case .downloadsOff: parts.append(L10n.tr("Downloads off"))
        }
        if let size = option.sizeLabel {
            parts.append(size)
        }
        return parts.joined(separator: ", ")
    }

    private func chipText(_ color: Color) -> some View {
        Text(chip.text)
            .brutalFont(size: 9, weight: .black, design: .monospaced, relativeTo: .caption)
            .foregroundStyle(color)
            .multilineTextAlignment(.trailing)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var trailingStatus: some View {
        switch chip {
        case .preparing:
            HStack(spacing: 5) {
                ProgressView()
                    .controlSize(.small)
                    .tint(Brutal.ink)
                    .accessibilityLabel(L10n.tr("Preparing %@", option.name))

                chipText(Brutal.ink)
            }
        case .downloading(let percent):
            HStack(spacing: 5) {
                Text(chip.text)
                    .brutalFont(size: 10, weight: .black, design: .monospaced, relativeTo: .caption)
                    .foregroundStyle(isSelected ? Brutal.contentOnYellow : Brutal.blue)

                Button(action: onCancelDownload) {
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
                    label: L10n.tr("Cancel %@ download", option.name),
                    hint: L10n.tr("Stops the current model download"),
                    value: L10n.tr("%@ percent", "\(percent)"),
                    hitExpansion: 13
                )
            }
        case .inUse:
            chipText(isSelected ? Brutal.contentOnYellow : Brutal.successText)
        case .downloaded:
            chipText(Brutal.successText)
        case .downloadsOff:
            chipText(Brutal.textTertiary)
                .frame(maxWidth: 84, alignment: .trailing)
                .help(downloadsOffStatus)
        case .failed:
            VStack(alignment: .trailing, spacing: 4) {
                chipText(Brutal.dangerText)
                actionButton(L10n.tr("RETRY"))
                    .help(L10n.tr("Try the download again"))
                    .brutalInteractive(
                        label: L10n.tr("Retry %@ download", option.name),
                        hint: L10n.tr("Starts the download again"),
                        value: downloadError ?? "",
                        hitExpansion: 10
                    )
            }
        case .download:
            actionButton(L10n.tr("DOWNLOAD"))
                .help(L10n.tr("Download this model from Hugging Face"))
                .brutalInteractive(
                    label: L10n.tr("Download %@", option.name),
                    hint: L10n.tr("Downloads this model for local transcription"),
                    value: option.sizeLabel ?? L10n.tr("Not installed"),
                    hitExpansion: 10
                )
        }
    }

    /// Two clicks: DELETE, then SURE? within the same row.
    private func deleteButton(_ onDelete: @escaping () -> Void) -> some View {
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
            label: L10n.tr("Delete %@", option.name),
            hint: confirmingDelete
                ? L10n.tr("Click again to delete the downloaded files")
                : L10n.tr("Deletes the downloaded files. You can download them again later."),
            hitExpansion: 10
        )
    }

    private func actionButton(_ title: String) -> some View {
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
    }
}
}

/// The choice control on a model row: an empty square, or a square with an
/// ink center on the model in use. Reads as "pick one", not as a checkbox.
struct ModelChoiceMark: View {
    let isSelected: Bool

    var body: some View {
        ZStack {
            Rectangle().fill(Brutal.card)
            if isSelected {
                Rectangle()
                    .fill(Brutal.ink)
                    .frame(width: 8, height: 8)
            }
        }
        .frame(width: 18, height: 18)
        .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))
        .accessibilityHidden(true)
    }
}
