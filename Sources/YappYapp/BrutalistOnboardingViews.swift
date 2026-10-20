import SwiftUI

// ONBOARDING: the first-run screens (see Onboarding.swift). Same window, same
// poster skin as the tabs: the YAPPYAPP header with the step chip, a segment
// bar for progress, one title, one sentence, the step's card, and a footer
// with BACK, SKIP where safe, and the primary action on the right.

private struct OnboardingActionsKey: EnvironmentKey {
    static let defaultValue = OnboardingActions()
}

private struct OnboardingInitialEditingKey: EnvironmentKey {
    static let defaultValue: RecommendationKind? = nil
}

extension EnvironmentValues {
    var onboardingActions: OnboardingActions {
        get { self[OnboardingActionsKey.self] }
        set { self[OnboardingActionsKey.self] = newValue }
    }

    /// The render gallery opens one pick's CHANGE row. Nil in the app.
    var onboardingInitialEditing: RecommendationKind? {
        get { self[OnboardingInitialEditingKey.self] }
        set { self[OnboardingInitialEditingKey.self] = newValue }
    }
}

struct OnboardingView: View {
    @ObservedObject var state: YappYappState
    let session: OnboardingSession
    @Environment(\.onboardingActions) private var actions

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            OnboardingProgressBar(steps: session.steps, current: session.current)

            BrutalScroll {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(OnboardingCopy.title(session.current))
                            .brutalFont(size: 20, weight: .black, relativeTo: .title3)
                            .kerning(1)
                            .foregroundStyle(Brutal.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                        Text(ShortcutCopy.personalize(detail, state.config.shortcuts))
                            .brutalFont(size: 11.5, weight: .semibold, relativeTo: .callout)
                            .foregroundStyle(Brutal.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    stepBody
                    if showsDownloadStrip {
                        OnboardingDownloadStrip(lines: downloadLines, onRetry: actions.retryDownloads)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, Brutal.drop)
                .padding(.bottom, Brutal.drop + 2)
            }
            .scrollIndicators(.never)

            footer
        }
    }

    private var detail: String {
        OnboardingCopy.detail(
            session.current,
            downloadsAllowed: state.config.allowModelDownloads,
            accepted: session.accepted,
            microphoneDenied: state.isMicrophoneDenied
        )
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("YAPPYAPP")
                    .brutalFont(size: 22, weight: .black, relativeTo: .title2)
                    .kerning(1.2)
                    .foregroundStyle(Brutal.ink)
                Text(L10n.tr("FOR PROFESSIONAL YAPPERS"))
                    .brutalFont(size: 8, weight: .bold, relativeTo: .caption2)
                    .kerning(0.8)
                    .foregroundStyle(Brutal.textTertiary)
            }
            Spacer()
            Text(OnboardingFlow.badge(for: session.current, in: session.steps))
                .brutalFont(size: 10, weight: .black, relativeTo: .caption)
                .kerning(0.8)
                .foregroundStyle(Brutal.paper)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(Brutal.ink)
                .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if OnboardingFlow.previous(session) != nil {
                BrutalActionButton(
                    title: L10n.tr("BACK"),
                    accessibilityLabel: L10n.tr("Back"),
                    hint: L10n.tr("Goes to the previous setup step"),
                    action: actions.back
                )
            }
            if let skip = skipTitle {
                BrutalActionButton(
                    title: skip,
                    accessibilityLabel: skip.capitalized,
                    hint: L10n.tr("Moves on without this step. You can do it later."),
                    action: actions.skip
                )
            }
            // Disabled reads as a plain card, never a faded fill.
            Button(primary.title, action: primary.action)
                .buttonStyle(BrutalTextButtonStyle(
                    fill: primary.disabled ? Brutal.card : primary.fill,
                    text: primary.disabled ? Brutal.textDisabled : (primary.fill == Brutal.blue ? Brutal.paper : Brutal.ink)
                ))
                .disabled(primary.disabled)
                .brutalInteractive(
                    label: primary.title.capitalized,
                    hint: primary.hint,
                    hitExpansion: 5
                )
        }
        .padding(.trailing, Brutal.drop)
        .padding(.bottom, Brutal.drop)
    }

    /// SKIP hides once the step is done, so it never competes with CONTINUE.
    private var skipTitle: String? {
        switch session.current {
        case .microphone where state.isMicrophoneAuthorized: nil
        case .autoPaste where state.isAccessibilityTrusted: nil
        case .models where session.accepted || !state.config.allowModelDownloads: nil
        default: OnboardingFlow.skipTitle(for: session.current)
        }
    }

    private struct Primary {
        let title: String
        let hint: String
        var fill = Brutal.yellow
        var disabled = false
        let action: () -> Void
    }

    private var primary: Primary {
        let next = Primary(title: L10n.tr("CONTINUE"), hint: L10n.tr("Goes to the next setup step"), action: actions.next)
        switch session.current {
        case .languages:
            return next
        case .models:
            guard state.config.allowModelDownloads, !session.accepted else { return next }
            let total = OnboardingPlan.totalBytes(rows)
            let title = total > 0
                ? L10n.tr("USE THESE · %@", ByteCountFormatter.string(fromByteCount: total, countStyle: .file))
                : L10n.tr("USE THESE")
            return Primary(
                title: title,
                hint: L10n.tr("Uses these models and starts the downloads"),
                fill: Brutal.blue,
                disabled: session.picks == nil,
                action: actions.acceptPicks
            )
        case .microphone:
            if state.isMicrophoneAuthorized { return next }
            if state.isMicrophoneDenied {
                return Primary(title: L10n.tr("OPEN SETTINGS"), hint: L10n.tr("Opens the Microphone list in System Settings"), fill: Brutal.blue, action: actions.openMicrophoneSettings)
            }
            return Primary(title: L10n.tr("ALLOW MIC"), hint: L10n.tr("Shows the macOS microphone prompt"), fill: Brutal.blue, action: actions.requestMicrophone)
        case .autoPaste:
            if state.isAccessibilityTrusted { return next }
            if state.staleAccessibility != .clean {
                return Primary(title: L10n.tr("RESET"), hint: L10n.tr("Clears the old permission and asks again"), fill: Brutal.blue, action: actions.resetAccessibility)
            }
            return Primary(
                title: session.accessibilityRequested ? L10n.tr("OPEN AGAIN") : L10n.tr("ALLOW"),
                hint: L10n.tr("Opens the macOS Accessibility permission flow"),
                fill: Brutal.blue,
                action: actions.requestAccessibility
            )
        case .wordsAndSnippets:
            let ready = OnboardingFlow.canContinue(session)
            return Primary(
                title: L10n.tr("CONTINUE"),
                hint: ready ? L10n.tr("Goes to the next setup step") : L10n.tr("Add one word and one snippet first"),
                disabled: !ready,
                action: actions.next
            )
        case .tryIt:
            return Primary(title: L10n.tr("FINISH"), hint: L10n.tr("Closes setup and shows the MIC tab"), action: actions.finish)
        }
    }

    // MARK: - Steps

    @ViewBuilder
    private var stepBody: some View {
        switch session.current {
        case .languages:
            OnboardingLanguagesCard(config: state.config, session: session)
        case .models:
            OnboardingModelsCard(session: session, rows: rows, lines: downloadLines, downloadsAllowed: state.config.allowModelDownloads, llamaRuntimeAvailable: llamaRuntimeAvailable)
        case .microphone:
            permissionCard(
                symbol: "mic.fill",
                done: state.isMicrophoneAuthorized,
                doneText: OnboardingCopy.microphoneAllowed,
                waitingText: state.isMicrophoneDenied ? nil : L10n.tr("macOS asks once. Choose Allow.")
            )
        case .autoPaste:
            permissionCard(
                symbol: "text.cursor",
                done: state.isAccessibilityTrusted,
                doneText: OnboardingCopy.autoPasteAllowed,
                waitingText: state.staleAccessibility != .clean
                    ? L10n.tr("macOS remembers an older YappYapp. Click RESET, then turn YappYapp on again.")
                    : (session.accessibilityRequested ? OnboardingCopy.autoPasteWaiting : OnboardingCopy.autoPasteSteps),
                waiting: session.accessibilityRequested && state.staleAccessibility == .clean
            )
        case .wordsAndSnippets:
            OnboardingWordsCard(session: session)
        case .tryIt:
            OnboardingTryItCard(state: state, session: session, speechLine: speechLine)
        }
    }

    private func permissionCard(symbol: String, done: Bool, doneText: String, waitingText: String?, waiting: Bool = false) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: done ? "checkmark" : symbol)
                .brutalFont(size: 24, weight: .black, relativeTo: .title2)
                .foregroundStyle(Brutal.ink)
                .frame(width: 56, height: 56)
                .background(done ? Brutal.green : Brutal.yellow)
                .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                if done {
                    Text(doneText.uppercased())
                        .brutalText(.rowLabel)
                        .foregroundStyle(Brutal.successText)
                } else if let waitingText {
                    HStack(alignment: .top, spacing: 6) {
                        if waiting {
                            ProgressView().controlSize(.small).tint(Brutal.ink)
                        }
                        Text(waitingText)
                            .brutalFont(size: 10.5, weight: .semibold, relativeTo: .caption)
                            .foregroundStyle(Brutal.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(Brutal.card)
        .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))
        .background(Rectangle().fill(Brutal.ink).offset(x: Brutal.drop, y: Brutal.drop))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Derived

    private var llamaRuntimeAvailable: Bool {
        state.translationModels.runtimeAvailable
    }

    private var rows: [OnboardingPickRow] {
        guard let picks = session.picks else { return [] }
        return OnboardingPlan.rows(
            picks: picks,
            recommendations: session.recommendations,
            installed: session.installed,
            translateTarget: session.translateTarget,
            llamaRuntimeAvailable: llamaRuntimeAvailable
        )
    }

    private var speechLine: OnboardingDownloadLine? {
        let id = session.picks?.speechID ?? state.selectedModelID
        guard let option = ModelCatalog.option(for: id) else { return nil }
        return OnboardingDownloads.speechLine(
            name: option.name,
            ready: state.isModelReady && state.selectedModelID == id,
            progress: state.modelDownloads[id],
            error: state.modelDownloadErrors[id]
        )
    }

    private var downloadLines: [OnboardingDownloadLine] {
        guard session.accepted, let picks = session.picks else { return [] }
        var lines: [OnboardingDownloadLine] = []
        if let speechLine { lines.append(speechLine) }
        if picks.cleanup.usesModel {
            let phase: CleanupDownloadPhase
            switch state.cleanupReadiness {
            case .downloading(let fraction): phase = .downloading(fraction: fraction)
            case .verifying: phase = .verifying
            case .failed(let message): phase = .failed(message)
            default: phase = .idle
            }
            if let line = OnboardingDownloads.extraLine(
                name: RecommendationKind.cleanup.label, phase: phase,
                verified: state.cleanupReadiness == .ready, queued: session.extrasQueued
            ) { lines.append(line) }
        }
        if let id = picks.translationModel,
           let line = OnboardingDownloads.extraLine(
               name: TranslationCatalog.model(id).name, phase: state.translationModels.phase(id),
               verified: state.translationModels.verified.contains(id), queued: session.extrasQueued
           ) {
            lines.append(line)
        }
        return lines
    }

    /// The strip follows the user through the permission steps, so a
    /// download is never out of sight.
    private var showsDownloadStrip: Bool {
        guard session.accepted, !downloadLines.isEmpty else { return false }
        switch session.current {
        case .microphone, .autoPaste: return true
        case .languages, .models, .wordsAndSnippets, .tryIt: return false
        }
    }
}

// MARK: - Progress

private struct OnboardingProgressBar: View {
    let steps: [OnboardingStep]
    let current: OnboardingStep

    var body: some View {
        let index = steps.firstIndex(of: current) ?? 0
        HStack(spacing: -Brutal.border) {
            ForEach(Array(steps.enumerated()), id: \.offset) { offset, _ in
                Rectangle()
                    .fill(offset < index ? Brutal.ink : (offset == index ? Brutal.yellow : Brutal.card))
                    .frame(height: 10)
                    .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))
            }
        }
        .padding(.trailing, Brutal.drop)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(OnboardingFlow.badge(for: current, in: steps))
    }
}

// MARK: - LANGUAGES

private struct OnboardingLanguagesCard: View {
    let config: AppConfig
    let session: OnboardingSession
    @Environment(\.onboardingActions) private var actions

    private let columns = Array(repeating: GridItem(.flexible(), spacing: -Brutal.border), count: 4)

    var body: some View {
        BrutalSettingsCard(L10n.tr("LANGUAGES")) {
            VStack(alignment: .leading, spacing: BrutalControl.innerSpacing) {
                BrutalRowLabel(L10n.tr("APP LANGUAGE"))
                BrutalPicker(
                    choices: AppLanguage.allCases.map { language in
                        BrutalChoice(value: language, title: language.chipLabel, accessibilityLabel: L10n.tr("App language %@", language.chipLabel.lowercased()))
                    },
                    selection: AppLanguage(configValue: config.appLanguage),
                    accessibilityLabel: L10n.tr("App language"),
                    hint: L10n.tr("Sets the language of YappYapp's menus and screens"),
                    onSelect: actions.setAppLanguage
                )
            }

            VStack(alignment: .leading, spacing: BrutalControl.innerSpacing) {
                BrutalRowLabel(L10n.tr("I SPEAK"))
                LazyVGrid(columns: columns, spacing: -Brutal.border) {
                    chip(code: OnboardingLanguages.auto, title: L10n.tr("Auto").uppercased(), selected: session.spoken.isEmpty)
                    ForEach(LanguageCatalog.spokenLanguages, id: \.code) { language in
                        chip(code: language.code, title: language.name, selected: session.spoken.contains(language.code))
                    }
                }
                BrutalCaption(L10n.tr("Pick every language you dictate in. AUTO works for most people."))
            }

            VStack(alignment: .leading, spacing: BrutalControl.innerSpacing) {
                BrutalRowLabel(L10n.tr("TRANSLATE TO"))
                BrutalPicker(
                    choices: TranslationCatalog.targets.map { BrutalChoice(value: $0, title: $0.label) },
                    selection: session.translateTarget,
                    accessibilityLabel: L10n.tr("Translate to"),
                    hint: L10n.tr("Your words go out in this language"),
                    onSelect: actions.setTranslateTarget
                )
            }
        }
    }

    private func chip(code: String, title: String, selected: Bool) -> some View {
        Button {
            actions.toggleSpoken(code)
        } label: {
            Text(title)
                .brutalText(.control)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity, minHeight: BrutalControl.height)
                .background(selected ? Brutal.ink : Brutal.card)
                .foregroundStyle(selected ? Brutal.paper : Brutal.ink)
                .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .brutalInteractive(
            label: title,
            hint: L10n.tr("Adds or removes a language you speak"),
            value: selected ? L10n.tr("Selected") : L10n.tr("Not selected"),
            selected: selected,
            hitExpansion: 3
        )
    }
}

// MARK: - DETECT BEST MODELS

private struct OnboardingModelsCard: View {
    let session: OnboardingSession
    let rows: [OnboardingPickRow]
    let lines: [OnboardingDownloadLine]
    let downloadsAllowed: Bool
    let llamaRuntimeAvailable: Bool
    @Environment(\.onboardingActions) private var actions
    @Environment(\.onboardingInitialEditing) private var initialEditing
    @State private var editingChoice: RecommendationKind??

    private var editing: RecommendationKind? {
        editingChoice ?? initialEditing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if session.profile == nil || session.picks == nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(Brutal.ink)
                    Text(L10n.tr("Reading the chip, memory and free space. Nothing leaves this Mac."))
                        .brutalFont(size: 10.5, weight: .semibold, relativeTo: .caption)
                        .foregroundStyle(Brutal.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(11)
            } else {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if index > 0 {
                        Rectangle().fill(Brutal.ink).frame(height: Brutal.border)
                    }
                    rowView(row)
                }
                if !session.accepted, downloadsAllowed {
                    totalBar
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brutal.card)
        .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))
        .background(Rectangle().fill(Brutal.ink).offset(x: Brutal.drop, y: Brutal.drop))
    }

    /// What was detected, in one line.
    private var header: some View {
        HStack(spacing: 8) {
            Text((session.profile?.summaryLine ?? L10n.tr("Scanning this Mac")).uppercased())
                .brutalText(.sectionTitle)
                .foregroundStyle(Brutal.paper)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(L10n.tr("Detected: %@", session.profile?.summaryLine ?? ""))
            if session.profile != nil, !session.accepted {
                Button(action: actions.scanAgain) {
                    Text(L10n.tr("SCAN AGAIN"))
                        .brutalText(.control)
                        .foregroundStyle(Brutal.yellow)
                        .fixedSize()
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .brutalInteractive(label: L10n.tr("Scan my Mac again"), hint: L10n.tr("Reads this Mac again and updates the picks"), hitExpansion: 10)
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        .background(Brutal.ink)
    }

    private var totalBar: some View {
        let total = OnboardingPlan.totalBytes(rows)
        return HStack {
            Text(L10n.tr("TOTAL DOWNLOAD"))
                .brutalText(.rowLabel)
            Spacer()
            Text(total > 0 ? ByteCountFormatter.string(fromByteCount: total, countStyle: .file) : L10n.tr("NOTHING TO DOWNLOAD"))
                .brutalText(.value)
                .monospacedDigit()
        }
        .foregroundStyle(Brutal.ink)
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(Brutal.yellow)
        .overlay(Rectangle().fill(Brutal.ink).frame(height: Brutal.border), alignment: .top)
        .accessibilityElement(children: .combine)
    }

    private func rowView(_ row: OnboardingPickRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(row.kind.label)
                    .brutalFont(size: 8, weight: .black, relativeTo: .caption2)
                    .kerning(0.5)
                    .foregroundStyle(Brutal.paper)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Brutal.ink)
                    .fixedSize()
                Text(row.title.uppercased())
                    .brutalFont(size: 12, weight: .black, relativeTo: .callout)
                    .kerning(0.5)
                    .foregroundStyle(Brutal.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                trailing(row)
            }
            Text(row.reason)
                .brutalFont(size: 10.5, weight: .semibold, relativeTo: .caption)
                .foregroundStyle(Brutal.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if row.kind == .cleanup {
                // CLEANUP-EXPLAINED: say what cleanup is where it is chosen.
                Text(CleanupMode.explainer)
                    .brutalFont(size: 10.5, weight: .semibold, relativeTo: .caption)
                    .foregroundStyle(Brutal.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if editing == row.kind, !session.accepted {
                editor(for: row.kind)
                    .padding(.top, 2)
            }
        }
        .padding(11)
    }

    @ViewBuilder
    private func trailing(_ row: OnboardingPickRow) -> some View {
        if session.accepted {
            if let line = line(for: row) {
                Text(line.isError ? L10n.tr("FAILED") : line.status)
                    .brutalFont(size: 9, weight: .black, design: .monospaced, relativeTo: .caption)
                    .foregroundStyle(line.isError ? Brutal.dangerText : (line.isDone ? Brutal.successText : Brutal.ink))
                    .fixedSize()
            }
        } else {
            if let bytes = row.downloadBytes, downloadsAllowed {
                Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                    .brutalText(.value)
                    .monospacedDigit()
                    .foregroundStyle(Brutal.textSecondary)
                    .fixedSize()
            }
            Button {
                editingChoice = .some(editing == row.kind ? nil : row.kind)
            } label: {
                Text(editing == row.kind ? L10n.tr("DONE") : L10n.tr("CHANGE"))
                    .brutalText(.control)
                    .foregroundStyle(Brutal.blue)
                    .fixedSize()
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .brutalInteractive(
                label: L10n.tr("Change %@", row.kind.label.lowercased()),
                hint: L10n.tr("Shows the other choices for this pick"),
                hitExpansion: 10
            )
        }
    }

    private func line(for row: OnboardingPickRow) -> OnboardingDownloadLine? {
        switch row.kind {
        case .speech: lines.first
        case .cleanup: lines.first { $0.title == RecommendationKind.cleanup.label }
        case .translation: session.picks?.translationModel.flatMap { id in lines.first { $0.title == TranslationCatalog.model(id).name } }
        }
    }

    @ViewBuilder
    private func editor(for kind: RecommendationKind) -> some View {
        if let picks = session.picks {
            switch kind {
            case .speech:
                BrutalPicker(
                    choices: ModelCatalog.options.map { option in
                        BrutalChoice(value: option.id, title: [option.name, option.sizeLabel].compactMap { $0 }.joined(separator: " · "))
                    },
                    selection: picks.speechID,
                    accessibilityLabel: L10n.tr("Speech model"),
                    hint: L10n.tr("The model that turns your voice into text")
                ) { id in
                    var next = picks
                    next.speechID = id
                    actions.setPicks(next)
                }
            case .cleanup:
                BrutalSegmented(
                    choices: [
                        BrutalChoice(value: CleanupMode.verbatim, title: CleanupMode.verbatim.label),
                        BrutalChoice(value: CleanupMode.clean, title: CleanupMode.clean.label, disabled: !llamaRuntimeAvailable)
                    ],
                    selection: picks.cleanup.usesModel ? CleanupMode.clean : CleanupMode.verbatim,
                    hint: L10n.tr("Cleanup tidies your words on this Mac before they're pasted")
                ) { mode in
                    var next = picks
                    next.cleanup = mode
                    actions.setPicks(next)
                }
                // The selected mode, in one line and a tiny example.
                CleanupModeExplainer(mode: picks.cleanup.usesModel ? picks.cleanup : .verbatim)
                    .padding(.top, BrutalControl.innerSpacing)
            case .translation:
                if session.translateTarget == .off {
                    BrutalCaption(L10n.tr("Off. Pick a TRANSLATE TO language in step 1 to add it."))
                } else {
                    BrutalSegmented(
                        choices: [BrutalChoice<TranslationModelID?>(value: nil, title: L10n.tr("OFF"))]
                            + [TranslationModelID.hyMT2Fast, .hyMT2Best].map { id in
                                BrutalChoice<TranslationModelID?>(value: id, title: TranslationCatalog.model(id).name, disabled: !llamaRuntimeAvailable)
                            },
                        selection: picks.translationModel,
                        hint: L10n.tr("The model that translates what you said")
                    ) { id in
                        var next = picks
                        next.translationModel = id
                        actions.setPicks(next)
                    }
                }
            }
        }
    }
}

// MARK: - TRY IT

private struct OnboardingTryItCard: View {
    @ObservedObject var state: YappYappState
    let session: OnboardingSession
    let speechLine: OnboardingDownloadLine?
    @Environment(\.onboardingActions) private var actions

    private var canDictate: Bool {
        HomeReadiness.canDictate(
            isWhisperReady: state.isWhisperReady,
            isModelReady: state.isModelReady,
            isMicrophoneAuthorized: state.isMicrophoneAuthorized
        )
    }

    private var isRecording: Bool { state.phase == .recording }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Button(action: actions.toggleRecording) {
                    ZStack {
                        if state.phase == .transcribing {
                            ProgressView().tint(Brutal.contentOnYellow)
                        } else {
                            Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                                .brutalFont(size: 28, weight: .black, relativeTo: .title2)
                                .foregroundStyle(canDictate ? Brutal.ink : Brutal.textDisabled)
                        }
                    }
                    .frame(width: 72, height: 72)
                    .contentShape(Rectangle())
                }
                .buttonStyle(BrutalButtonStyle(fill: isRecording ? Brutal.red : (canDictate ? Brutal.yellow : Brutal.card)))
                .disabled(!canDictate || state.phase == .transcribing)
                .brutalInteractive(
                    label: isRecording ? L10n.tr("Stop dictating") : L10n.tr("Start dictating"),
                    hint: L10n.tr("Records a test sentence"),
                    value: state.phase.label,
                    hitExpansion: 0
                )

                VStack(alignment: .leading, spacing: 6) {
                    Text(HomeScreenPresenter.headline(phase: state.phase, canDictate: canDictate, isCleaning: false, mode: state.config.shortcuts.mode))
                        .brutalFont(size: 14, weight: .black, relativeTo: .headline)
                        .kerning(0.8)
                        .foregroundStyle(Brutal.ink)
                    Text(statusLine)
                        .brutalFont(size: 10.5, weight: .semibold, relativeTo: .caption)
                        .foregroundStyle(Brutal.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if canDictate {
                        ActiveShortcutKeys(settings: state.config.shortcuts)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(Brutal.card)
            .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))
            .background(Rectangle().fill(Brutal.ink).offset(x: Brutal.drop, y: Brutal.drop))

            if let latest = state.transcriptHistory.first {
                OnboardingTryItResult(text: latest.text, word: session.addedWord, snippet: session.addedSnippet)
            } else if let word = session.addedWord, let snippet = session.addedSnippet {
                OnboardingTryItPrompt(word: word, snippet: snippet)
            }
            if state.transcriptHistory.isEmpty, let speechLine, !speechLine.isDone {
                OnboardingDownloadStrip(lines: [speechLine], onRetry: actions.retryDownloads)
            }
        }
    }

    private var statusLine: String {
        if !state.isMicrophoneAuthorized {
            return L10n.tr("Allow the mic first. Go BACK, or allow it later on the MIC tab.")
        }
        if !state.isModelReady {
            if let speechLine, speechLine.isError {
                return L10n.tr("The voice model didn't download. Click RETRY below.")
            }
            return L10n.tr("Your voice model is still downloading. Try it the moment it finishes.")
        }
        if state.phase == .idle, state.transcriptHistory.isEmpty {
            return ShortcutCopy.personalize(L10n.tr("Click the button or press ⌥ space, then speak."), state.config.shortcuts)
        }
        return ShortcutCopy.personalize(state.statusText, state.config.shortcuts)
    }
}

// MARK: - Downloads

struct OnboardingDownloadStrip: View {
    let lines: [OnboardingDownloadLine]
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L10n.tr("DOWNLOADS"))
                    .brutalText(.sectionTitle)
                    .foregroundStyle(Brutal.paper)
                Spacer()
                if lines.contains(where: \.isError) {
                    Button(action: onRetry) {
                        Text(L10n.tr("RETRY"))
                            .brutalText(.control)
                            .foregroundStyle(Brutal.yellow)
                            .fixedSize()
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .brutalInteractive(label: L10n.tr("Retry downloads"), hint: L10n.tr("Starts the failed downloads again"), hitExpansion: 10)
                }
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 26)
            .background(Brutal.ink)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(line.title)
                                .brutalText(.control)
                                .foregroundStyle(Brutal.ink)
                            Spacer(minLength: 8)
                            if !line.isError {
                                Text(line.status)
                                    .brutalText(.value)
                                    .monospacedDigit()
                                    .foregroundStyle(line.isDone ? Brutal.successText : Brutal.ink)
                            }
                        }
                        if line.isError {
                            BrutalCaption(line.status, tone: .warning)
                        } else if let fraction = line.fraction, !line.isDone {
                            GeometryReader { proxy in
                                Rectangle()
                                    .fill(Brutal.blue)
                                    .frame(width: max(0, proxy.size.width * min(fraction, 1)))
                            }
                            .frame(height: 6)
                            .background(Brutal.field)
                            .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: 1))
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(10)
            .background(Brutal.card)
        }
        .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))
        .background(Rectangle().fill(Brutal.ink).offset(x: Brutal.drop, y: Brutal.drop))
    }
}
