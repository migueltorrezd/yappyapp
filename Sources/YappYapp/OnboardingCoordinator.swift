import AppKit
import Combine

/// What the onboarding screens can ask for. Built by `OnboardingCoordinator`
/// and handed to the views through the environment, so the popover's
/// initializer stays as it is.
struct OnboardingActions: Sendable {
    var setAppLanguage: @MainActor @Sendable (AppLanguage) -> Void = { _ in }
    var toggleSpoken: @MainActor @Sendable (String) -> Void = { _ in }
    var setTranslateTarget: @MainActor @Sendable (TranslationTarget) -> Void = { _ in }
    var setPicks: @MainActor @Sendable (OnboardingPicks) -> Void = { _ in }
    var scanAgain: @MainActor @Sendable () -> Void = {}
    var acceptPicks: @MainActor @Sendable () -> Void = {}
    var next: @MainActor @Sendable () -> Void = {}
    var back: @MainActor @Sendable () -> Void = {}
    var skip: @MainActor @Sendable () -> Void = {}
    var retryDownloads: @MainActor @Sendable () -> Void = {}
    var requestMicrophone: @MainActor @Sendable () -> Void = {}
    var openMicrophoneSettings: @MainActor @Sendable () -> Void = {}
    var requestAccessibility: @MainActor @Sendable () -> Void = {}
    var resetAccessibility: @MainActor @Sendable () -> Void = {}
    var toggleRecording: @MainActor @Sendable () -> Void = {}
    /// WORDS AND SNIPPETS: saves and returns nil, or returns the problem.
    var addWord: @MainActor @Sendable (_ canonical: String, _ variantsText: String) -> String? = { _, _ in nil }
    var addSnippet: @MainActor @Sendable (_ trigger: String, _ expansion: String) -> String? = { _, _ in nil }
    var finish: @MainActor @Sendable () -> Void = {}
}

/// Owns the onboarding run: step changes, the scan, USE THESE and the
/// order downloads start in (the speech model first, so the first dictation
/// is not waiting behind cleanup or translation).
@MainActor
final class OnboardingCoordinator {
    /// AppDelegate's side of the work.
    struct Hooks {
        var saveConfig: (AppConfig) -> Void = { _ in }
        var selectSpeechModel: (String) -> Void = { _ in }
        var retrySpeechDownload: (String) -> Void = { _ in }
        var startCleanupDownload: () -> Void = {}
        var selectTranslationModel: (TranslationModelID) -> Void = { _ in }
        var startTranslationDownload: (TranslationModelID) -> Void = { _ in }
        var installedModels: () -> InstalledModels = { InstalledModels() }
        var whisperAvailable: () -> Bool = { true }
        var qwen3ASRAvailable: () -> Bool = { true }
        var llamaRuntimeAvailable: () -> Bool = { true }
        var refreshPermissions: () -> Void = {}
        var requestMicrophone: () -> Void = {}
        var openMicrophoneSettings: () -> Void = {}
        var requestAccessibility: () -> Void = {}
        var resetAccessibility: () -> Void = {}
        var toggleRecording: () -> Void = {}
        /// The WORDS tab save paths: glossary.json and snippets.json.
        var saveGlossary: ([GlossaryEntry]) -> Void = { _ in }
        var saveSnippets: ([Snippet]) -> Void = { _ in }
        var showWindow: () -> Void = {}
        var finished: () -> Void = {}
    }

    private let state: YappYappState
    var hooks = Hooks()
    /// Cleanup and translation picks that start once the speech model lands.
    /// Kept apart from the session so FINISH does not drop them.
    private(set) var pendingExtras: OnboardingPicks?
    private var cancellables = Set<AnyCancellable>()
    private var activeObserver: NSObjectProtocol?

    init(state: YappYappState) {
        self.state = state
    }

    var facts: OnboardingFacts {
        OnboardingFacts(
            microphoneAuthorized: state.isMicrophoneAuthorized,
            accessibilityTrusted: state.isAccessibilityTrusted,
            autoPasteWanted: state.config.autoPaste,
            speechModelReady: state.isModelReady
        )
    }

    // MARK: - Lifecycle

    func start() {
        state.onboarding = OnboardingFlow.start(
            facts: facts,
            configLanguage: state.config.language,
            translateTarget: state.config.translation
        )
        if state.onboarding?.current == .models { scan() }
        observe()
    }

    private func observe() {
        guard cancellables.isEmpty else { return }
        // A grant made in System Settings flips these through the readiness
        // poll; the screen moves on without a relaunch.
        state.$isMicrophoneAuthorized.removeDuplicates().dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { MainActor.assumeIsolated { self?.permissionsChanged() } } }
            .store(in: &cancellables)
        state.$isAccessibilityTrusted.removeDuplicates().dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { MainActor.assumeIsolated { self?.permissionsChanged() } } }
            .store(in: &cancellables)
        // Coming back from System Settings: read the permissions at once
        // instead of waiting for the next poll.
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.state.onboarding != nil else { return }
                self.hooks.refreshPermissions()
            }
        }
    }

    func stop() {
        cancellables.removeAll()
        if let activeObserver {
            NotificationCenter.default.removeObserver(activeObserver)
        }
        activeObserver = nil
    }

    private func permissionsChanged() {
        guard let session = state.onboarding,
              OnboardingFlow.autoAdvances(session.current, facts: facts) else { return }
        let wasInSettings = !NSApp.isActive
        next()
        // The user granted it in System Settings: bring the next step back.
        if wasInSettings { hooks.showWindow() }
    }

    // MARK: - Navigation

    func next() {
        guard var session = state.onboarding else { return }
        if session.current == .languages {
            // The dictation language is saved now, so CHOOSE LATER keeps it.
            let language = OnboardingLanguages.configLanguage(for: session.spoken)
            if language != state.config.language {
                var config = state.config
                config.language = language
                hooks.saveConfig(config)
            }
            // Languages changed the advice; refresh it before MODELS shows.
            if session.profile != nil { recompute(&session) }
        }
        // WORDS AND SNIPPETS has no way around it but BACK.
        guard OnboardingFlow.canContinue(session) else { return }
        guard let step = OnboardingFlow.next(session, facts: facts) else {
            finish()
            return
        }
        session.current = step
        state.onboarding = session
        if step == .models, session.profile == nil { scan() }
    }

    func back() {
        guard var session = state.onboarding, let step = OnboardingFlow.previous(session) else { return }
        session.current = step
        state.onboarding = session
    }

    func skip() {
        next()
    }

    func finish() {
        state.onboarding = nil
        hooks.finished()
    }

    // MARK: - Languages

    func setAppLanguage(_ language: AppLanguage) {
        // Switch first so the next render is already translated.
        L10n.apply(language.rawValue)
        var config = state.config
        config.appLanguage = language.rawValue
        hooks.saveConfig(config)
        // Reasons and labels in the session were built in the old language.
        if var session = state.onboarding, session.profile != nil {
            recompute(&session)
            state.onboarding = session
        }
    }

    func toggleSpoken(_ code: String) {
        guard var session = state.onboarding else { return }
        session.spoken = OnboardingLanguages.toggle(code, in: session.spoken)
        if session.profile != nil, !session.accepted { recompute(&session) }
        state.onboarding = session
    }

    /// Only the translation pick follows; speech and cleanup keep any
    /// change the user made.
    func setTranslateTarget(_ target: TranslationTarget) {
        guard var session = state.onboarding else { return }
        session.translateTarget = target
        if !session.accepted, var picks = session.picks {
            if target == .off || !hooks.llamaRuntimeAvailable() {
                picks.translationModel = nil
            } else if picks.translationModel == nil {
                picks.translationModel = OnboardingPlan.picks(
                    from: session.recommendations, translateTarget: target, llamaRuntimeAvailable: true
                ).translationModel
            }
            session.picks = picks
        }
        state.onboarding = session
    }

    // MARK: - DETECT BEST MODELS

    func scan() {
        let installed = hooks.installedModels()
        DispatchQueue.global(qos: .userInitiated).async {
            let profile = HardwareScanner.read()
            Task { @MainActor in
                guard var session = self.state.onboarding else { return }
                session.profile = profile
                self.recompute(&session, installed: installed)
                self.state.onboarding = session
            }
        }
    }

    private func recompute(_ session: inout OnboardingSession, installed: InstalledModels? = nil) {
        guard let profile = session.profile else { return }
        let installed = installed ?? hooks.installedModels()
        session.installed = installed
        let recommendations = ModelAdvisor.recommend(
            for: profile,
            installed: installed,
            languages: session.spoken,
            whisperAvailable: hooks.whisperAvailable(),
            qwen3ASRAvailable: hooks.qwen3ASRAvailable()
        )
        session.recommendations = recommendations
        // MODELS shows the same advice afterwards.
        state.hardwareScan = HardwareScan(profile: profile, recommendations: recommendations)
        guard !session.accepted else { return }
        session.picks = OnboardingPlan.picks(
            from: recommendations,
            translateTarget: session.translateTarget,
            llamaRuntimeAvailable: hooks.llamaRuntimeAvailable()
        )
    }

    func setPicks(_ picks: OnboardingPicks) {
        guard var session = state.onboarding, !session.accepted else { return }
        session.picks = picks
        if picks.translationModel == nil { session.translateTarget = .off }
        state.onboarding = session
    }

    /// USE THESE: the only place onboarding starts a download.
    func acceptPicks() {
        guard var session = state.onboarding, let picks = session.picks else { return }
        // Languages now; cleanup and translation once the speech model is
        // here, so it downloads at full speed.
        var config = OnboardingPlan.applying(picks, spoken: session.spoken, translateTarget: .off, to: state.config)
        config.cleanup = state.config.cleanup
        hooks.saveConfig(config)

        let extrasWanted = picks.cleanup.usesModel || picks.translationModel != nil
        pendingExtras = extrasWanted ? picks : nil
        pendingTranslateTarget = session.translateTarget
        hooks.selectSpeechModel(picks.speechID)
        if ModelCatalog.option(for: picks.speechID)?.isInstalled == true {
            startExtras()
        }

        session.accepted = true
        session.extrasQueued = pendingExtras != nil
        state.onboarding = session
        next()
    }

    private var pendingTranslateTarget: TranslationTarget = .off

    /// AppDelegate calls this when the chosen speech model is installed.
    func speechModelInstalled(_ id: String) {
        guard pendingExtras?.speechID == id else { return }
        startExtras()
    }

    private func startExtras() {
        guard let picks = pendingExtras else { return }
        pendingExtras = nil
        state.onboarding?.extrasQueued = false
        var config = state.config
        config.cleanup = picks.cleanup
        if let id = picks.translationModel, pendingTranslateTarget != .off {
            config.translation = pendingTranslateTarget
            config.translationModelID = id
        }
        // Saving a cleanup mode starts its model download (AppDelegate).
        hooks.saveConfig(config)
        if let id = picks.translationModel, pendingTranslateTarget != .off {
            hooks.selectTranslationModel(id)
        }
    }

    /// RETRY in the download strip: whatever failed starts again.
    func retryDownloads() {
        guard let picks = state.onboarding?.picks else { return }
        if state.modelDownloadErrors[picks.speechID] != nil, state.modelDownloads[picks.speechID] == nil {
            hooks.retrySpeechDownload(picks.speechID)
        }
        if case .failed = state.cleanupReadiness {
            hooks.startCleanupDownload()
        }
        if let id = picks.translationModel, case .failed = state.translationModels.phase(id) {
            hooks.startTranslationDownload(id)
        }
    }

    // MARK: - WORDS AND SNIPPETS

    /// Saves the word through the WORDS tab path. Returns the problem
    /// instead when it cannot be saved, or did not land on disk.
    func addWord(canonical: String, variantsText: String) -> String? {
        if let issue = OnboardingWords.wordIssue(canonical: canonical, variantsText: variantsText, existing: state.glossaryEntries) {
            return issue
        }
        let entry = OnboardingWords.entry(canonical: canonical, variantsText: variantsText)
        hooks.saveGlossary(OnboardingWords.adding(entry, to: state.glossaryEntries))
        guard let saved = state.glossaryEntries.first(where: { $0.canonical == entry.canonical }) else {
            return L10n.tr("Your word wasn't saved. Try again.")
        }
        state.onboarding?.addedWord = saved
        return nil
    }

    func addSnippet(trigger: String, expansion: String) -> String? {
        if let issue = OnboardingWords.snippetIssue(
            trigger: trigger, expansion: expansion, existing: state.snippets, glossary: state.glossaryEntries
        ) {
            return issue
        }
        let snippet = OnboardingWords.snippet(trigger: trigger, expansion: expansion)
        hooks.saveSnippets(OnboardingWords.adding(snippet, to: state.snippets))
        guard let saved = state.snippets.first(where: { $0.id == snippet.id }) else {
            return L10n.tr("Your snippet wasn't saved. Try again.")
        }
        state.onboarding?.addedSnippet = saved
        return nil
    }

    // MARK: - Permissions and TRY IT

    func requestAccessibility() {
        if var session = state.onboarding {
            session.accessibilityRequested = true
            state.onboarding = session
        }
        hooks.requestAccessibility()
    }

    var actions: OnboardingActions {
        OnboardingActions(
            setAppLanguage: { [weak self] in self?.setAppLanguage($0) },
            toggleSpoken: { [weak self] in self?.toggleSpoken($0) },
            setTranslateTarget: { [weak self] in self?.setTranslateTarget($0) },
            setPicks: { [weak self] in self?.setPicks($0) },
            scanAgain: { [weak self] in self?.scan() },
            acceptPicks: { [weak self] in self?.acceptPicks() },
            next: { [weak self] in self?.next() },
            back: { [weak self] in self?.back() },
            skip: { [weak self] in self?.skip() },
            retryDownloads: { [weak self] in self?.retryDownloads() },
            requestMicrophone: { [weak self] in self?.hooks.requestMicrophone() },
            openMicrophoneSettings: { [weak self] in self?.hooks.openMicrophoneSettings() },
            requestAccessibility: { [weak self] in self?.requestAccessibility() },
            resetAccessibility: { [weak self] in self?.hooks.resetAccessibility() },
            toggleRecording: { [weak self] in self?.hooks.toggleRecording() },
            addWord: { [weak self] canonical, variants in
                self?.addWord(canonical: canonical, variantsText: variants) ?? L10n.tr("Your word wasn't saved. Try again.")
            },
            addSnippet: { [weak self] trigger, expansion in
                self?.addSnippet(trigger: trigger, expansion: expansion) ?? L10n.tr("Your snippet wasn't saved. Try again.")
            },
            finish: { [weak self] in self?.finish() }
        )
    }
}
