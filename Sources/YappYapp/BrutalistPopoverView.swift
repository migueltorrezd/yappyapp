import SwiftUI

// Flat saturated color on warm paper, 2pt ink borders, hard offset shadows,
// and heavy uppercase type. No blur, gradients, translucency, or soft shadow.

enum BrutalTab: String, CaseIterable, Identifiable {
    case home = "MIC"
    case files = "FILES"
    case models = "MODELS"
    case words = "WORDS"
    case pet = "PET"
    case settings = "SETUP"

    var id: String { rawValue }
}

struct BrutalistPopoverView: View {
    @ObservedObject var state: YappYappState

    let onToggleRecording: () -> Void
    let onSelectModel: (String) -> Void
    let onDownloadModel: (String) -> Void
    let onCancelDownload: (String) -> Void
    let onSaveConfig: (AppConfig) -> Void
    let onSaveGlossary: ([GlossaryEntry]) -> Void
    let onRequestAccessibility: () -> Void
    let onResetAndRegrantAccessibility: () -> Void
    let onRequestMicrophone: () -> Void
    let onOpenMicrophoneSettings: () -> Void
    let onSetLaunchAtLogin: (Bool) -> Void
    let onChooseStarter: (PetKind) -> Void
    let onEquipAccessory: (PetAccessory) -> Void
    let onSaveRecap: () -> Void
    let onCopyText: (String) -> Void
    let onRevealSupport: () -> Void
    let onQuit: () -> Void
    var onCheckForUpdates: () -> Void = {}
    // YA-10: cleanup model download controls in SETUP.
    var onDownloadCleanupModel: () -> Void = {}
    var onCancelCleanupDownload: () -> Void = {}
    // TRANSLATION (round 2): translation model controls in SETUP and MODELS.
    var onSelectTranslationModel: (TranslationModelID) -> Void = { _ in }
    var onDownloadTranslationModel: (TranslationModelID) -> Void = { _ in }
    var onCancelTranslationDownload: (TranslationModelID) -> Void = { _ in }
    var onDeleteTranslationModel: (TranslationModelID) -> Void = { _ in }
    // SCAN MY MAC on MODELS.
    var onScanMac: () -> Void = {}
    var onApplyRecommendation: (RecommendedChoice) -> Void = { _ in }
    var onSaveSnippets: ([Snippet]) -> Void = { _ in }
    // COMMANDS: RETRY on the MIC tab after a failed transcription.
    var onRetryFailed: () -> Void = {}
    // QWEN3-ASR: DELETE on a downloaded Qwen3-ASR row in MODELS.
    var onDeleteModel: (String) -> Void = { _ in }
    // LEARN-FROM-FIXES: UNDO next to "Learned Genial." on the MIC tab.
    var onUndoLearnedWord: (LearnedWordNotice) -> Void = { _ in }

    @State var tab: BrutalTab = .home
    @State var configDraft = AppConfig.defaultConfig
    @State var glossaryDrafts: [GlossaryEntryDraft] = []
    @State var focusedGlossaryDraftID: UUID?
    // SNIPPETS: the WORDS tab list, snippet edits and the import/export strip.
    @State var wordsMode: WordsMode = .words
    @State var snippetDrafts: [SnippetDraft] = []
    @State var wordsShare: WordsShareState = .idle
    @State var autosaveTask: Task<Void, Never>?
    @State var expandedTranscriptID: UUID?
    @State var tipIndex = FeatureTips.randomIndex()

    var body: some View {
        VStack(spacing: 14) {
            // ONBOARDING: the first-run steps take the whole window until
            // FINISH; the tabs come back after.
            if let session = state.onboarding {
                OnboardingView(state: state, session: session)
                    .id(state.config.appLanguage)
            } else {
                tabbedBody
            }
        }
        .padding(18)
        .frame(width: 440, height: 596)
        .background(Brutal.paper)
        // DROPDOWN-FLOAT: open lists float here, over every tab and step.
        .brutalDropdownHost()
        .environment(\.brutalTextSize, BrutalTextSize(configValue: configDraft.textSize))
        .focusEffectDisabled()
        .overlay(alignment: .bottom) {
            if state.onboarding == nil {
                PetView(state: state, kind: state.overlayPet, pixel: 2)
                    .frame(height: PetOverlayLayout.overlayHeight)
                    .padding(.horizontal, 4)
                    .allowsHitTesting(false)
            }
        }
        .onAppear {
            resetDrafts()
            resetSnippetDrafts()
            syncTabOnAppear()
        }
        // ONBOARDING: WORDS AND SNIPPETS saved a word and a snippet; show
        // them in WORDS the moment the tabs come back.
        .onChange(of: state.onboarding == nil) { _, finished in
            if finished {
                resetDrafts()
                resetSnippetDrafts()
            }
        }
        .onChange(of: state.requestedTab) { _, requested in
            followRequestedTab(requested)
        }
        .onChange(of: tab) { _, newTab in
            state.activeTab = newTab
        }
        .onChange(of: state.config) { _, newValue in
            configDraft = newValue
        }
        .onChange(of: configDraft) { _, _ in
            scheduleAutosave()
        }
    }

    @ViewBuilder
    private var tabbedBody: some View {
        header
        // YA-35: one auto-paste prompt, hidden while the wizard asks.
        // On MIC it sits in the tab's single attention slot instead.
        if showsAutoPasteBanner && tab != .home {
            pasteOffBanner
        }
        if let notice = state.configRecoveryNotice {
            ConfigRecoveryBanner(notice: notice) { state.configRecoveryNotice = nil }
        }
        tabBar
        tabFeedbackBar

        Group {
            switch tab {
            case .home:
                homeTab
            case .files:
                filesTab
            case .models:
                modelsTab
            case .words:
                wordsTab
            case .pet:
                petTab
            case .settings:
                settingsTab
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // L10N: a new app language rebuilds the tab so every child
        // view renders in it, not only the ones whose inputs changed.
        .id(configDraft.appLanguage)
        // YA-37: every tab keeps its bottom clear of the walking pet.
        .padding(.bottom, PetOverlayLayout.bottomReserve(for: state.overlayPet))
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

            // YA-33: derived from setup readiness, not just the phase.
            Text(headerChip.label)
                .brutalFont(size: 10, weight: .black, relativeTo: .caption)
                .kerning(0.8)
                .foregroundStyle(headerChipText)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(headerChipFill)
                .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))
        }
    }

    // pasteOffBanner: persistent auto-paste warning while Accessibility is
    // not trusted, bound to state.isAccessibilityTrusted. Above the tabs
    // everywhere except MIC, where the attention slot shows it.
    var pasteOffBanner: some View {
        HStack(spacing: 10) {
            Text("!")
                .brutalFont(size: 16, weight: .black, relativeTo: .headline)
                .foregroundStyle(Brutal.yellow)
                .frame(width: 24, height: 24)
                .background(Brutal.ink)

            VStack(alignment: .leading, spacing: 1) {
                Text(AutoPastePrompt.bannerTitle)
                    .brutalFont(size: 11, weight: .black, relativeTo: .callout)
                    .kerning(0.6)
                    .foregroundStyle(Brutal.ink)
                Text(AutoPastePrompt.bannerDetail(isStale: autoPasteBannerIsStale))
                    .brutalFont(size: 10, weight: .semibold, relativeTo: .caption)
                    .foregroundStyle(Brutal.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button(
                AutoPastePrompt.bannerActionTitle(isStale: autoPasteBannerIsStale),
                action: autoPasteBannerIsStale ? onResetAndRegrantAccessibility : onRequestAccessibility
            )
                .buttonStyle(.plain)
                .brutalFont(size: 10, weight: .black, relativeTo: .caption)
                .kerning(0.6)
                .foregroundStyle(Brutal.paper)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Brutal.blue)
                .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))
                .brutalInteractive(
                    label: L10n.tr("Allow auto-paste"),
                    hint: L10n.tr("Opens the macOS Accessibility permission flow"),
                    value: state.isAccessibilityTrusted ? L10n.tr("Enabled") : L10n.tr("Disabled"),
                    hitExpansion: 10
                )
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brutal.yellow)
        .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))
        .background(Rectangle().fill(Brutal.ink).offset(x: Brutal.drop, y: Brutal.drop))
        .accessibilityIdentifier("pasteOffBanner.brutal")
    }

    private var tabBar: some View {
        // UX-WRITING: every tab gets its label's width plus an equal share of
        // the spare room, so long labels (MASCOTTE, RÉGLAGES, HUISDIER) keep
        // the same gap as short ones instead of touching their neighbours.
        BrutalTabRowLayout {
            ForEach(BrutalTab.allCases) { item in
                Button {
                    tab = item
                } label: {
                    Text(L10n.tr(item.rawValue))
                        .brutalFont(size: BrutalTabRowLayout.fontSize, weight: .black, relativeTo: .callout)
                        .kerning(BrutalTabRowLayout.kerning)
                        // Long labels (MASCOTTE, RÉGLAGES, LARGER text)
                        // shrink on one line and keep a gap between tabs.
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .padding(.horizontal, BrutalTabRowLayout.labelPadding)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 34)
                        .background(tab == item ? Brutal.ink : Brutal.card)
                        .foregroundStyle(tab == item ? Brutal.paper : Brutal.ink)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .brutalInteractive(
                    label: item.rawValue,
                    hint: L10n.tr("Shows the %@ tab", L10n.tr(item.rawValue).lowercased()),
                    value: tab == item ? L10n.tr("Selected") : L10n.tr("Not selected"),
                    selected: tab == item,
                    hitExpansion: 5
                )
            }
        }
        .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))
        .background(Rectangle().fill(Brutal.ink).offset(x: Brutal.drop, y: Brutal.drop))
    }

    // MARK: - Helpers

    func resetDrafts() {
        configDraft = state.config
        glossaryDrafts = state.glossaryEntries.map(GlossaryEntryDraft.init)
    }

    private func scheduleAutosave() {
        guard configDraft != state.config else { return }

        autosaveTask?.cancel()
        autosaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            onSaveConfig(configDraft)
        }
    }
}

/// The tab bar row: each cell is its ideal width plus an equal share of what
/// is left. When the labels do not fit at all (Larger text in a long
/// language), cells shrink in proportion and the labels scale down.
struct BrutalTabRowLayout: Layout {
    static let labelPadding: CGFloat = 5
    /// Six tabs (MIC, FILES, MODELS, WORDS, PET, SETUP) share the row, so
    /// labels are a step smaller and tighter than the five-tab bar was.
    static let fontSize: CGFloat = 10
    static let kerning: CGFloat = 0.5

    static func widths(ideal: [CGFloat], available: CGFloat) -> [CGFloat] {
        guard !ideal.isEmpty else { return [] }
        let total = ideal.reduce(0, +)
        guard total > 0 else { return ideal.map { _ in available / CGFloat(ideal.count) } }
        if total <= available {
            let extra = (available - total) / CGFloat(ideal.count)
            return ideal.map { $0 + extra }
        }
        return ideal.map { $0 * available / total }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let width = proposal.width ?? sizes.reduce(0) { $0 + $1.width }
        let height = sizes.map(\.height).max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let ideal = subviews.map { $0.sizeThatFits(.unspecified).width }
        let widths = Self.widths(ideal: ideal, available: bounds.width)
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths) {
            subview.place(
                at: CGPoint(x: x, y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: width, height: bounds.height)
            )
            x += width
        }
    }
}
