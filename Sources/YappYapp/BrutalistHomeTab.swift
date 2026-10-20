import SwiftUI

enum BrutalTranscriptDisclosure: Equatable {
    case collapsed
    case expanded

    var label: String {
        switch self {
        case .collapsed: L10n.tr("Show all")
        case .expanded: L10n.tr("Show less")
        }
    }

    var hint: String {
        switch self {
        case .collapsed: L10n.tr("Shows the whole dictation")
        case .expanded: L10n.tr("Shows only the first lines again")
        }
    }

    func value(for text: String) -> String {
        switch self {
        case .collapsed: L10n.tr("Collapsed. %@", text)
        case .expanded: L10n.tr("Expanded. %@", text)
        }
    }
}

extension BrutalistPopoverView {
    // MARK: - Home

    private var isRecording: Bool {
        state.phase == .recording
    }

    private var hasSetupIssues: Bool {
        !setupRows.isEmpty
    }

    /// UX-WRITING (P1): the one thing under the record block that needs the
    /// user, if anything.
    private var homeAttention: HomeAttention? {
        HomeScreenPresenter.attention(
            phase: state.phase,
            hasSetupRows: hasSetupIssues,
            hotkeyUnavailable: state.hotkeyUnavailable,
            autoPasteNotAllowed: showsAutoPasteBanner
        )
    }

    var homeTab: some View {
        let attention = homeAttention
        return BrutalScroll {
            VStack(spacing: 12) {
                recordBlock(attention: attention)

                // One attention slot: setup step, then error, then the dead
                // shortcut, then auto-paste. The green READY banner only
                // shows when idle with nothing to flag.
                switch attention {
                case .setup:
                    setupBlock
                case .error(let message):
                    brutalErrorRow(message)
                case .shortcutTaken:
                    hotkeyUnavailableRow
                case .autoPaste:
                    pasteOffBanner
                case nil:
                    if HomeScreenPresenter.showsReadyBanner(phase: state.phase, attention: attention) {
                        readyRow
                    }
                }

                // First run only, after the mic step and never before the
                // voice model is there.
                if HomeScreenPresenter.showsGuidedMicCheck(canTranscribe: state.isModelReady && state.isWhisperReady) {
                    MicCheckGuidedCard(state: state, quietVoiceBoost: $configDraft.quietVoiceBoost)
                }

                transcriptBlock

                if HomeScreenPresenter.showsTips(guidedSetupDone: state.config.hasCompletedGuidedSetup) {
                    tipsCard
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 92)
        }
        .scrollIndicators(.never)
        // FILES: a file dropped on MIC still starts, and the window moves to
        // the FILES tab where its progress and result live.
        .fileTranscriptionDropTarget()
    }

    private func recordBlock(attention: HomeAttention?) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button(action: onToggleRecording) {
                    ZStack {
                        if state.phase == .transcribing {
                            ProgressView()
                                .tint(Brutal.contentOnYellow)
                        } else {
                            Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                                .brutalFont(size: 30, weight: .black, relativeTo: .title2)
                                .foregroundStyle(Brutal.ink)
                        }
                    }
                    .frame(width: 84, height: 84)
                    .contentShape(Rectangle())
                }
                .buttonStyle(BrutalButtonStyle(fill: isRecording ? Brutal.red : Brutal.yellow))
                .disabled(state.phase == .transcribing)
                .brutalInteractive(
                    label: isRecording ? L10n.tr("Stop dictating") : L10n.tr("Start dictating"),
                    hint: isRecording
                        ? L10n.tr("Stops recording and begins on-device transcription")
                        : L10n.tr("Starts recording from the selected microphone"),
                    value: state.phase.label,
                    hitExpansion: 0
                )

                VStack(alignment: .leading, spacing: 7) {
                    // UX-WRITING (P1): the headline is the phase. YA-71: the
                    // mode wording only shows idle and ready, and a toggle
                    // never claims push to talk.
                    Text(HomeScreenPresenter.headline(
                        phase: state.phase,
                        canDictate: canDictate,
                        isCleaning: HomeScreenPresenter.isCleaning(phase: state.phase, hudNote: state.hudNote),
                        mode: state.config.shortcuts.mode
                    ))
                        .brutalFont(size: 15, weight: .black, relativeTo: .headline)
                        .kerning(0.8)
                        .foregroundStyle(Brutal.ink)

                    if let statusLine = HomeScreenPresenter.statusLine(
                        statusText: state.statusText,
                        phase: state.phase,
                        attention: attention,
                        canDictate: canDictate,
                        shortcutFailureText: ShortcutCopy.registrationFailure(state.config.shortcuts, failed: [.toggleDictation])
                    ) {
                        Text(ShortcutCopy.personalize(statusLine, state.config.shortcuts))
                            .brutalFont(size: 11, weight: .semibold, relativeTo: .callout)
                            .foregroundStyle(Brutal.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // YA-29: pet news gets its own line; it never replaces the
                    // paste outcome above.
                    if let petEventNote = state.petEventNote {
                        Text(petEventNote)
                            .brutalFont(size: 10, weight: .bold, relativeTo: .caption)
                            .foregroundStyle(Brutal.ink)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Brutal.yellow)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel(L10n.tr("Pet news: %@", petEventNote))
                    }

                    // LEARN-FROM-FIXES: once per learned word, with UNDO.
                    if let notice = state.learnedWordNotice {
                        LearnedWordNoticeRow(notice: notice) { onUndoLearnedWord(notice) }
                    }

                    // COMMANDS: RETRY lives in the error row of the attention
                    // slot; here only when a setup step holds that slot.
                    if attention == .setup,
                       RetryLastPresenter.offersRetry(phase: state.phase, retryAvailable: state.retryAvailable) {
                        RetryFailedButton(action: onRetryFailed)
                    }

                    // YA-72: a dead shortcut is named once. The slot's row
                    // explains it; the red chip only stands in when the slot
                    // holds something more urgent.
                    if state.hotkeyUnavailable {
                        if attention != .shortcutTaken {
                            hotkeyChips
                        }
                    } else {
                        ActiveShortcutKeys(settings: state.config.shortcuts)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(14)
            .background(Brutal.card)

            LiveWaveform(
                levels: state.levelHistory,
                isActive: isRecording,
                tint: Brutal.yellow,
                maxBarHeight: 34,
                barCount: 36,
                barWidth: 5,
                barSpacing: 4,
                squared: true,
                inactiveOpacity: 0.45
            )
            .frame(height: 44)
            .frame(maxWidth: .infinity)
            .background(Brutal.ink)
        }
        .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))
        .background(Rectangle().fill(Brutal.ink).offset(x: Brutal.drop, y: Brutal.drop))
    }

    private var setupBlock: some View {
        VStack(spacing: 0) {
            ForEach(setupRows) { row in
                BrutalSetupRow(
                    title: row.title.uppercased(),
                    detail: row.detail,
                    stepBadge: row.stepBadge?.uppercased(),
                    stepMap: row.stepMap?.uppercased(),
                    actionTitle: row.actionTitle?.uppercased(),
                    action: setupAction(for: row.action)
                )
            }
        }
        .background(Brutal.yellow)
        .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))
        .background(Rectangle().fill(Brutal.ink).offset(x: Brutal.drop, y: Brutal.drop))
    }

    // GUIDED-FIRST-RUN: one numbered step during first run, full list after.
    private var setupRows: [SetupReadinessRow] {
        SetupReadinessPresenter.guidedRows(for: setupInput)
    }

    private func setupAction(for action: SetupReadinessAction?) -> (() -> Void)? {
        guard let action else { return nil }
        switch action {
        case .downloadRecommendedModel:
            return { onDownloadModel(recommendedDownloadID) }
        case .showModels:
            return { tab = .models }
        case .showSetup:
            return { tab = .settings }
        case .requestAccessibility:
            return onRequestAccessibility
        case .requestMicrophone:
            return onRequestMicrophone
        case .openMicrophoneSettings:
            return onOpenMicrophoneSettings
        }
    }

    private var readyRow: some View {
        VStack(spacing: 6) {
            Text(HomeScreenPresenter.readyBannerTitle(autoPaste: state.config.autoPaste))
                .brutalFont(size: 11, weight: .black, relativeTo: .callout)
                .kerning(0.8)
                .foregroundStyle(Brutal.contentOnGreen)

            // MARKER privacyAndTimeSaved: privacy badge
            HStack(spacing: 4) {
                Image(systemName: "lock.fill")
                    .brutalFont(size: 8, weight: .black, relativeTo: .caption2)
                Text(L10n.tr("YOUR VOICE AND TEXT STAY ON THIS MAC."))
                    .brutalFont(size: 9, weight: .black, relativeTo: .caption)
                    .kerning(0.6)
            }
            .foregroundStyle(Brutal.successOnInk)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Brutal.ink)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .background(Brutal.green)
        .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))
        .background(Rectangle().fill(Brutal.ink).offset(x: Brutal.drop, y: Brutal.drop))
    }

    private var tipsCard: some View {
        let tip = FeatureTips.tip(at: tipIndex, petEnabled: state.config.petEnabled)

        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L10n.tr("TIPS"))
                    .brutalFont(size: 10, weight: .black, relativeTo: .caption)
                    .kerning(1)
                    .foregroundStyle(Brutal.paper)

                Spacer()

                Button(L10n.tr("NEXT")) {
                    tipIndex = FeatureTips.nextIndex(after: tipIndex)
                }
                .buttonStyle(.plain)
                .brutalFont(size: 8.5, weight: .black, relativeTo: .caption2)
                .kerning(0.8)
                .foregroundStyle(Brutal.yellow)
                .brutalInteractive(
                    label: L10n.tr("Next tip"),
                    hint: L10n.tr("Shows another YappYapp tip"),
                    value: tip.title,
                    hitExpansion: 10
                )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Brutal.ink)

            HStack(alignment: .top, spacing: 8) {
                Text(tip.title)
                    .brutalFont(size: 9, weight: .black, design: .monospaced, relativeTo: .caption)
                    .kerning(0.7)
                    .foregroundStyle(Brutal.ink)
                    .frame(width: 104, alignment: .leading)

                Text(ShortcutCopy.personalize(tip.body, state.config.shortcuts).uppercased())
                    .brutalFont(size: 9.5, weight: .bold, relativeTo: .caption)
                    .foregroundStyle(Brutal.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Brutal.yellow)
        }
        .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))
        .background(Rectangle().fill(Brutal.ink).offset(x: Brutal.drop, y: Brutal.drop))
    }

    private var transcriptBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L10n.tr("HISTORY"))
                    .brutalFont(size: 10, weight: .black, relativeTo: .caption)
                    .kerning(1)
                    .foregroundStyle(Brutal.paper)

                Spacer()

                if state.petStats.wordsTodayDisplayed() > 0 {
                    Text(brutalStatsLabel)
                        .brutalFont(size: 9, weight: .black, design: .monospaced, relativeTo: .caption)
                        .foregroundStyle(Brutal.yellow)
                }

                if !state.transcriptHistory.isEmpty {
                    Button(L10n.tr("CLEAR")) {
                        state.transcriptHistory = []
                        expandedTranscriptID = nil
                    }
                    .buttonStyle(.plain)
                    .brutalFont(size: 9, weight: .black, relativeTo: .caption)
                    .kerning(0.8)
                    .foregroundStyle(Brutal.yellow)
                    .help(L10n.tr("Clears your history. The clipboard stays as it is."))
                    .brutalInteractive(
                        label: L10n.tr("Clear history"),
                        hint: L10n.tr("Clears your history. The clipboard stays as it is."),
                        value: L10n.plural("%lld dictations", state.transcriptHistory.count),
                        hitExpansion: 10
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Brutal.ink)

            if state.transcriptHistory.isEmpty {
                Text(L10n.tr("Say something. It shows up here, lives in memory only, and is gone when you quit."))
                    .brutalFont(size: 11.5, weight: .semibold, relativeTo: .callout)
                    .foregroundStyle(Brutal.textTertiary)
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(Brutal.card)
            } else {
                BrutalScroll {
                    VStack(spacing: 0) {
                        ForEach(state.transcriptHistory) { entry in
                            BrutalTranscriptRow(
                                entry: entry,
                                isLatest: entry.id == state.transcriptHistory.first?.id,
                                isExpanded: expandedTranscriptID == entry.id,
                                onCopy: { onCopyText(entry.text) },
                                onRemove: { removeFromHistory(entry) },
                                onToggleExpanded: {
                                    expandedTranscriptID = expandedTranscriptID == entry.id ? nil : entry.id
                                }
                            )
                        }
                    }
                }
                .scrollIndicators(.never)
                .background(Brutal.card)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))
        .background(Rectangle().fill(Brutal.ink).offset(x: Brutal.drop, y: Brutal.drop))
    }

    /// CLEAR on one row: drops that dictation only. PASTE LAST reads the
    /// history, so a removed text can no longer be pasted again.
    private func removeFromHistory(_ entry: TranscriptEntry) {
        state.transcriptHistory.removeAll { $0.id == entry.id }
        if state.lastTranscript == entry.text,
           !state.transcriptHistory.contains(where: { $0.text == entry.text }) {
            state.lastTranscript = ""
        }
        if expandedTranscriptID == entry.id {
            expandedTranscriptID = nil
        }
    }

    private var brutalStatsLabel: String {
        // FIX staleDayDisplay: normalized reads so a new day shows 0 today and a
        // broken streak drops out instead of lingering from yesterday.
        let streak = state.petStats.streakDisplayed()
        var label = L10n.tr("%@ TODAY", "\(state.petStats.wordsTodayDisplayed())")
        if streak > 1 {
            label += " · " + L10n.tr("%@-DAY STREAK", "\(streak)")
        }
        return label
    }

private struct BrutalSetupRow: View {
    let title: String
    let detail: String
    // GUIDED-FIRST-RUN: "STEP K OF N" chip, shown only during the wizard.
    var stepBadge: String?
    // UX-WRITING: the steps still to come, under the detail.
    var stepMap: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Text("!")
                .brutalFont(size: 16, weight: .black, relativeTo: .headline)
                .foregroundStyle(Brutal.yellow)
                .frame(width: 24, height: 24)
                .background(Brutal.ink)

            VStack(alignment: .leading, spacing: 1) {
                if let stepBadge {
                    Text(stepBadge)
                        .brutalFont(size: 8, weight: .black, design: .monospaced, relativeTo: .caption2)
                        .kerning(0.6)
                        .foregroundStyle(Brutal.paper)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Brutal.ink)
                        .padding(.bottom, 2)
                }

                Text(title)
                    .brutalFont(size: 11, weight: .black, relativeTo: .callout)
                    .kerning(0.6)
                    .foregroundStyle(Brutal.ink)

                Text(detail)
                    .brutalFont(size: 10, weight: .semibold, relativeTo: .caption)
                    .foregroundStyle(Brutal.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let stepMap {
                    Text(stepMap)
                        .brutalFont(size: 8, weight: .black, relativeTo: .caption2)
                        .kerning(0.6)
                        .foregroundStyle(Brutal.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 3)
                }
            }

            Spacer(minLength: 8)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.plain)
                    .brutalFont(size: 10, weight: .black, relativeTo: .caption)
                    .kerning(0.6)
                    .foregroundStyle(Brutal.paper)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Brutal.blue)
                    .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))
                    .brutalInteractive(
                        label: actionTitle,
                        hint: L10n.tr("Completes this setup step"),
                        value: title,
                        hitExpansion: 10
                    )
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
    }
}

private struct BrutalTranscriptRow: View {
    let entry: TranscriptEntry
    let isLatest: Bool
    let isExpanded: Bool
    let onCopy: () -> Void
    let onRemove: () -> Void
    let onToggleExpanded: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            transcriptText

            VStack(alignment: .trailing, spacing: 4) {
                BrutalIconButton("doc.on.doc", title: L10n.tr("COPY"), help: L10n.tr("Copy to clipboard"), action: onCopy)
                BrutalIconButton("xmark", title: L10n.tr("CLEAR"), help: L10n.tr("Removes this dictation from history."), action: onRemove)
            }
            .fixedSize()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(Rectangle().frame(height: Brutal.border).foregroundStyle(Brutal.ink), alignment: .bottom)
    }

    @ViewBuilder
    private var transcriptText: some View {
        if isExpanded {
            let disclosure = BrutalTranscriptDisclosure.expanded
            ScrollView {
                Text(entry.text)
                    .brutalFont(size: 12, weight: .medium, relativeTo: .callout)
                    .foregroundStyle(isLatest ? Brutal.textPrimary : Brutal.textSecondary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: TranscriptHistoryLayout.expandedTextMaxHeight, alignment: .topLeading)
            .scrollIndicators(.visible)
            .contentShape(Rectangle())
            .onTapGesture(perform: onToggleExpanded)
            .brutalKeyboardAction(
                label: disclosure.label,
                hint: disclosure.hint,
                value: disclosure.value(for: entry.text),
                action: onToggleExpanded
            )
        } else {
            let disclosure = BrutalTranscriptDisclosure.collapsed
            Text(entry.text)
                .brutalFont(size: 12, weight: .medium, relativeTo: .callout)
                .foregroundStyle(isLatest ? Brutal.textPrimary : Brutal.textSecondary)
                .lineLimit(isLatest ? TranscriptHistoryLayout.latestCompactLineLimit : TranscriptHistoryLayout.olderCompactLineLimit)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(perform: onToggleExpanded)
                .brutalKeyboardAction(
                    label: disclosure.label,
                    hint: disclosure.hint,
                    value: disclosure.value(for: entry.text),
                    action: onToggleExpanded
                )
        }
    }
}

}

/// LEARN-FROM-FIXES: "Learned Genial." and UNDO, on one quiet line.
struct LearnedWordNoticeRow: View {
    let notice: LearnedWordNotice
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                    .font(.system(size: 9, weight: .black))
                    .accessibilityHidden(true)
                Text(notice.message)
                    .brutalFont(size: 10, weight: .bold, relativeTo: .caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(Brutal.ink)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Brutal.yellow)

            // Same compact shape as RETRY, in the quiet card color.
            Button(action: onUndo) {
                Text(LearnFromFixesCopy.undo)
                    .brutalFont(size: 10, weight: .black, relativeTo: .caption)
                    .kerning(0.8)
                    .foregroundStyle(Brutal.ink)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 22)
                    .background(Brutal.card)
                    .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))
                    .background(Rectangle().fill(Brutal.ink).offset(x: Brutal.drop, y: Brutal.drop))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .brutalInteractive(label: LearnFromFixesCopy.undo, hint: LearnFromFixesCopy.undoHint, hitExpansion: 9)
        }
        .accessibilityElement(children: .contain)
    }
}
