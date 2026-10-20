import Foundation

// TRANSLATION (round 2): owns the translation model downloads (one pinned
// downloader per model), their verification, deletion, and the translate
// step of a dictation. Kept out of AppDelegate so the app delegate only
// holds one reference and a few one-line hooks.
//
// Downloads follow the cleanup model's rules: only the pinned URL, never
// without the llama.cpp runtime, never with allowModelDownloads off, and the
// file becomes the model only after its SHA-256 matches.
@MainActor
final class TranslationCoordinator {
    private let state: YappYappState
    private var downloaders: [TranslationModelID: CleanupModelDownloader] = [:]
    private var phases: [TranslationModelID: CleanupDownloadPhase] = [:]
    private var verifying: Set<TranslationModelID> = []
    /// TRANSLATION-WARM: a model verified, deleted or the runtime changed,
    /// so the warm translation server can start, switch or stop.
    var onModelsChanged: (() -> Void)?

    init(state: YappYappState) {
        self.state = state
    }

    private var downloadable: [TranslationModelID] {
        TranslationCatalog.models.filter { $0.download != nil }.map(\.id)
    }

    /// Publishes what is on disk and in flight. Cheap: stamp reads only.
    func refresh(_ config: AppConfig? = nil) {
        let config = config ?? state.config
        var snapshot = TranslationModelsSnapshot()
        snapshot.runtimeAvailable = LLMCleaner.isRuntimeAvailable(configured: config.llamaBinaryPath)
        for id in downloadable {
            if TranslationModelStore.isVerified(id) { snapshot.verified.insert(id) }
            if TranslationModelStore.isInstalled(id) { snapshot.installed.insert(id) }
        }
        snapshot.phases = phases.filter { $0.value != .idle }
        if snapshot != state.translationModels {
            let modelsChanged = snapshot.verified != state.translationModels.verified
                || snapshot.runtimeAvailable != state.translationModels.runtimeAvailable
            state.translationModels = snapshot
            if modelsChanged { onModelsChanged?() }
        }
    }

    /// Stamps models installed by hand or before a stamp existed.
    func prepareAtLaunch() {
        refresh()
        for id in downloadable where TranslationModelStore.isInstalled(id) && !TranslationModelStore.isVerified(id) {
            verifyInstalled(id)
        }
    }

    private func verifyInstalled(_ id: TranslationModelID) {
        guard !verifying.contains(id) else { return }
        verifying.insert(id)
        phases[id] = .verifying
        refresh()
        DispatchQueue.global(qos: .utility).async {
            let verified = (try? TranslationModelStore.verifyExisting(id)) ?? false
            Task { @MainActor in
                self.verifying.remove(id)
                self.phases[id] = verified ? .idle : .failed(DownloadErrorCopy.integrity)
                self.refresh()
            }
        }
    }

    func startDownload(_ id: TranslationModelID) {
        let config = state.config
        guard let download = TranslationCatalog.model(id).download,
              config.allowModelDownloads, !verifying.contains(id),
              LLMCleaner.isRuntimeAvailable(configured: config.llamaBinaryPath) else {
            if !state.config.allowModelDownloads {
                state.postFeedback(.error(ModelDownloadPresenter.downloadsOffStatus(
                    lockedByAdmin: state.managedConfigKeys.contains(.allowModelDownloads)
                ), topic: "translation"), on: state.activeTab)
            }
            refresh()
            return
        }
        guard !TranslationModelStore.isVerified(id) else {
            refresh()
            return
        }
        let downloader = downloaders[id] ?? CleanupModelDownloader(source: download.url)
        downloaders[id] = downloader
        let started = downloader.start(
            stagingURL: TranslationModelStore.stagingURL(for: id),
            progress: { [weak self] fraction in
                guard let self else { return }
                self.phases[id] = .downloading(fraction: fraction)
                self.refresh()
            },
            completion: { [weak self] result in
                self?.finishDownload(id, result)
            }
        )
        guard started else { return }
        phases[id] = .downloading(fraction: nil)
        refresh()
        let model = TranslationCatalog.model(id)
        state.postFeedback(.info(L10n.tr("Downloading %@ (%@).", model.name, model.sizeLabel ?? ""), topic: "translation"), on: state.activeTab)
    }

    func cancelDownload(_ id: TranslationModelID) {
        downloaders[id]?.cancel()
    }

    func delete(_ id: TranslationModelID) {
        downloaders[id]?.cancel()
        TranslationModelStore.delete(id)
        phases[id] = .idle
        refresh()
        state.postFeedback(.success(L10n.tr("%@ deleted.", TranslationCatalog.model(id).name), topic: "translation"), on: state.activeTab)
    }

    private func finishDownload(_ id: TranslationModelID, _ result: Result<URL, Error>) {
        let name = TranslationCatalog.model(id).name
        switch result {
        case .failure(let error):
            if (error as? CleanupModelError) == .canceled {
                phases[id] = .idle
                state.postFeedback(.info(L10n.tr("Download canceled."), topic: "translation"), on: state.activeTab)
            } else {
                let message = L10n.tr("%@ download failed. %@", name, TranslationModelStore.plainError(error))
                phases[id] = .failed(message)
                state.postFeedback(.error(message, topic: "translation"), on: state.activeTab)
            }
            refresh()
        case .success(let staged):
            phases[id] = .verifying
            refresh()
            DispatchQueue.global(qos: .utility).async {
                var failure: Error?
                do {
                    try TranslationModelStore.install(id, downloadedFile: staged)
                } catch {
                    failure = error
                }
                let installError = failure
                Task { @MainActor in
                    if let installError {
                        let message = L10n.tr("%@ not installed. %@", name, TranslationModelStore.plainError(installError))
                        self.phases[id] = .failed(message)
                        self.state.postFeedback(.error(message, topic: "translation"), on: self.state.activeTab)
                    } else {
                        self.phases[id] = .idle
                        self.state.postFeedback(.success(L10n.tr("%@ is ready.", name), topic: "translation"), on: self.state.activeTab)
                    }
                    self.refresh()
                }
            }
        }
    }

    // MARK: - The translate step of a dictation

    /// Runs after cleanup, commands and snippets. Shows TRANSLATING on the
    /// HUD while it works when the dictation is still the current one, and
    /// returns the untranslated text with a reason on any failure.
    func translate(
        _ text: String,
        config: AppConfig,
        glossary: Glossary,
        isCurrent: @escaping @MainActor () -> Bool
    ) async -> TranslationResult {
        let plan = config.translationPlan
        guard case .model = plan.route,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              config.language != plan.target.rawValue else {
            return TranslationResult(text: text, outcome: .skipped)
        }
        var previousNote: String?
        let shown = isCurrent()
        if shown {
            previousNote = state.hudNote
            state.hudNote = L10n.tr("TRANSLATING · %@", plan.target.label)
            state.statusText = L10n.tr("Translating on this Mac\u{2026}")
        }
        let protectedTerms = LLMCleaner.protectedTerms(from: glossary)
        let llamaBinaryPath = config.llamaBinaryPath
        let language = config.language
        let result = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Translator.translate(
                    text: text,
                    plan: plan,
                    dictationLanguage: language,
                    protectedTerms: protectedTerms,
                    llamaBinaryPath: llamaBinaryPath
                ))
            }
        }
        if shown, isCurrent() {
            state.hudNote = result.fallback?.hudNote ?? previousNote
        }
        return result
    }
}
