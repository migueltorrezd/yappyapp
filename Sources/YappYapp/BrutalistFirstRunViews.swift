import SwiftUI

// FIRSTRUN track: the setup-honesty pieces of the popover and control window.
// The tab files call into these so their own edits stay one line long.

extension BrutalistPopoverView {
    // MARK: - Readiness

    /// The one input every setup surface reads (YA-01, YA-33, YA-35, YA-73).
    var setupInput: SetupReadinessInput {
        SetupReadinessInput(
            isWhisperReady: state.isWhisperReady,
            isModelReady: state.isModelReady,
            isAccessibilityTrusted: state.isAccessibilityTrusted,
            // YA-17: the auto-paste master switch decides whether to ask.
            pasteWhenFocusIsUnclear: state.config.autoPaste,
            allowModelDownloads: state.config.allowModelDownloads,
            // FIX downloadProgressDeterministic: modelDownloads is an
            // unordered Dictionary; .values.first jumps between concurrent
            // downloads. Prefer the selected model's download, else the
            // furthest-along one, so the setup row is stable.
            activeDownloadProgress: state.modelDownloads[state.selectedModelID]
                ?? state.modelDownloads.values.max(),
            isMicrophoneAuthorized: state.isMicrophoneAuthorized,
            isMicrophoneDenied: state.isMicrophoneDenied,
            isGuidedFirstRun: !state.config.hasCompletedGuidedSetup,
            isAccessibilityStale: state.staleAccessibility != .clean,
            isPackagedApp: WhisperRuntimeCopy.isPackagedApp,
            recommendedModelName: ModelCatalog.option(for: recommendedDownloadID)?.name,
            recommendedModelID: recommendedDownloadID,
            downloadsLockedByOrganization: state.managedConfigKeys.contains(.allowModelDownloads)
        )
    }

    /// The model a setup DOWNLOAD fetches: the selected catalog model, else
    /// the Parakeet default.
    var recommendedDownloadID: String {
        ModelCatalog.option(for: state.selectedModelID) != nil ? state.selectedModelID : ModelCatalog.recommendedID
    }

    /// The mic opens and a voice model can transcribe.
    var canDictate: Bool {
        HomeReadiness.canDictate(
            isWhisperReady: state.isWhisperReady,
            isModelReady: state.isModelReady,
            isMicrophoneAuthorized: state.isMicrophoneAuthorized
        )
    }

    var homeReadiness: HomeReadiness {
        HomeReadiness.evaluate(
            canDictate: canDictate,
            setupIncomplete: !SetupReadinessPresenter.guidedRows(for: setupInput).isEmpty
        )
    }

    var headerChip: HeaderChip {
        HeaderChipPresenter.chip(phase: state.phase, readiness: homeReadiness)
    }

    var headerChipFill: Color {
        switch headerChip.tone {
        case .recording: Brutal.red
        case .transcribing: Brutal.blue
        case .success: Brutal.green
        case .unconfirmed: Brutal.paper
        case .error, .setup: Brutal.yellow
        case .idle: Brutal.ink
        }
    }

    var headerChipText: Color {
        switch headerChip.tone {
        case .recording: Brutal.contentOnRed
        case .transcribing: Brutal.contentOnBlue
        case .success: Brutal.contentOnGreen
        case .unconfirmed: Brutal.ink
        case .error, .setup: Brutal.contentOnYellow
        case .idle: Brutal.paper
        }
    }

    var showsAutoPasteBanner: Bool {
        AutoPastePrompt.showsBanner(
            accessibilityTrusted: state.isAccessibilityTrusted,
            autoPasteEnabled: state.config.autoPaste,
            isGuidedFirstRun: !state.config.hasCompletedGuidedSetup
        )
    }

    var autoPasteBannerIsStale: Bool {
        state.staleAccessibility != .clean
    }

    // MARK: - YA-33 error row

    /// The failure's short reason as the title, the message, and RETRY
    /// right here when the audio was kept (no menu path to remember).
    func brutalErrorRow(_ message: String) -> some View {
        let retryOffered = RetryLastPresenter.offersRetry(phase: state.phase, retryAvailable: state.retryAvailable)
        return HStack(alignment: .top, spacing: 10) {
            Text("!")
                .brutalFont(size: 16, weight: .black, relativeTo: .headline)
                .foregroundStyle(Brutal.red)
                .frame(width: 24, height: 24)
                .background(Brutal.ink)

            VStack(alignment: .leading, spacing: 1) {
                Text(PasteOutcomePresenter.errorShortLabel(message))
                    .brutalFont(size: 11, weight: .black, relativeTo: .callout)
                    .kerning(0.6)
                    .foregroundStyle(Brutal.contentOnRed)
                Text(HomeScreenPresenter.errorDetail(message: message, retryOffered: retryOffered))
                    .brutalFont(size: 10, weight: .semibold, relativeTo: .caption)
                    .foregroundStyle(Brutal.contentOnRed)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if retryOffered {
                RetryFailedButton(action: onRetryFailed)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brutal.red)
        .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))
        .background(Rectangle().fill(Brutal.ink).offset(x: Brutal.drop, y: Brutal.drop))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("homeErrorRow.brutal")
    }

    // MARK: - YA-72 shortcut chips

    var hotkeyUnavailableTitle: String {
        ShortcutCopy.personalize(HotkeyStatusCopy.unavailableTitle, state.config.shortcuts).uppercased()
    }

    /// Only shown when the attention slot is busy with something more
    /// urgent, so the dead shortcut is still named once.
    @ViewBuilder
    var hotkeyChips: some View {
        if state.hotkeyUnavailable {
            HStack(spacing: 4) {
                Text(hotkeyUnavailableTitle)
                    .brutalFont(size: 8.5, weight: .black, relativeTo: .caption2)
                    .kerning(0.6)
                    .foregroundStyle(Brutal.contentOnRed)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Brutal.red)
                    .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: 1.5))
            }
            .help(ShortcutCopy.personalize(HotkeyStatusCopy.unavailableDetail, state.config.shortcuts))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(L10n.tr("Shortcut unavailable"))
            .accessibilityValue(ShortcutCopy.personalize(HotkeyStatusCopy.unavailableDetail, state.config.shortcuts))
        }
    }

    /// A persistent row that explains the dead shortcut in plain words.
    var hotkeyUnavailableRow: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("⌥")
                .brutalFont(size: 14, weight: .black, relativeTo: .headline)
                .foregroundStyle(Brutal.yellow)
                .frame(width: 24, height: 24)
                .background(Brutal.ink)

            VStack(alignment: .leading, spacing: 1) {
                Text(hotkeyUnavailableTitle)
                    .brutalFont(size: 11, weight: .black, relativeTo: .callout)
                    .kerning(0.6)
                    .foregroundStyle(Brutal.ink)
                Text(ShortcutCopy.personalize(HotkeyStatusCopy.unavailableDetail, state.config.shortcuts))
                    .brutalFont(size: 10, weight: .semibold, relativeTo: .caption)
                    .foregroundStyle(Brutal.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brutal.yellow)
        .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))
        .background(Rectangle().fill(Brutal.ink).offset(x: Brutal.drop, y: Brutal.drop))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("hotkeyUnavailable.brutal")
    }

    // MARK: - YA-38 per-tab feedback

    @ViewBuilder
    var tabFeedbackBar: some View {
        if let feedback = state.tabFeedback[tab] {
            BrutalTabFeedbackBar(feedback: feedback) {
                state.dismissFeedback(on: tab)
            }
        }
    }

    /// Follows tab requests from the app (YA-01 opens MIC on a blocked
    /// dictation, YA-28 Settings opens SETUP) and keeps `state.activeTab`
    /// honest so feedback lands where the user is.
    func syncTabOnAppear() {
        if let requested = state.requestedTab {
            tab = requested
        }
        state.activeTab = tab
    }

    func followRequestedTab(_ requested: BrutalTab?) {
        if let requested {
            tab = requested
        }
    }
}

private struct BrutalTabFeedbackBar: View {
    let feedback: TabFeedback
    let onDismiss: () -> Void

    private var fill: Color {
        switch feedback.tone {
        case .success: Brutal.green
        case .info: Brutal.card
        case .error: Brutal.red
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(feedback.text)
                .brutalFont(size: 10, weight: .bold, relativeTo: .caption)
                .foregroundStyle(Brutal.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if feedback.isError {
                Button(action: onDismiss) {
                    Text(L10n.tr("X"))
                        .brutalFont(size: 9, weight: .black, relativeTo: .caption)
                        .foregroundStyle(Brutal.paper)
                        .frame(width: 18, height: 18)
                        .background(Brutal.ink)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .brutalInteractive(
                    label: L10n.tr("Dismiss message"),
                    hint: L10n.tr("Hides this message"),
                    value: feedback.text,
                    hitExpansion: 13
                )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(fill)
        .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tabFeedback.brutal")
    }
}

extension BrutalistPopoverView {
    // MARK: - YA-24 engine notes

    var engineNotes: EngineSettingsNotes {
        EngineSettingsNotes.notes(for: configDraft)
    }
}
