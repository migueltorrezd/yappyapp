import Foundation

// QWEN3-ASR: downloads a model's two pinned files one after the other (the
// language model, then its audio projector), each from its pinned Hugging
// Face URL only, each verified by SHA-256 before it is moved into place. A
// file already verified is never fetched again. Never runs with
// allowModelDownloads off or without the bundled runtime. Progress is one
// number over both files, shown on the model's row like any other download.
@MainActor
final class Qwen3ASRDownloadCoordinator {
    struct Callbacks {
        /// 0...1, or -1 while a file is being verified.
        var progress: (String, Double) -> Void
        var finished: (ModelOption) -> Void
        var failed: (ModelOption, Error) -> Void
        var canceled: (ModelOption) -> Void
    }

    private var downloaders: [Qwen3ASRVariant: CleanupModelDownloader] = [:]
    private var running: Set<Qwen3ASRVariant> = []
    private var verifying: Set<Qwen3ASRVariant> = []
    private let callbacks: Callbacks

    init(callbacks: Callbacks) {
        self.callbacks = callbacks
    }

    func isRunning(_ variant: Qwen3ASRVariant) -> Bool {
        running.contains(variant)
    }

    /// Byte-weighted progress over both files. Pure, for the unit tests.
    nonisolated static func overallFraction(variant: Qwen3ASRVariant, doneBytes: Int64, current: Qwen3ASRFile, fraction: Double?) -> Double {
        let total = Double(variant.downloadBytes)
        guard total > 0 else { return 0 }
        let inFile = Double(current.sizeBytes) * min(max(fraction ?? 0, 0), 1)
        return min(1, (Double(doneBytes) + inFile) / total)
    }

    func start(_ option: ModelOption) {
        guard let variant = option.qwen3Variant, !running.contains(variant) else { return }
        running.insert(variant)
        callbacks.progress(option.id, 0)
        next(option, variant: variant)
    }

    func cancel(_ option: ModelOption) {
        guard let variant = option.qwen3Variant else { return }
        downloaders[variant]?.cancel()
    }

    /// Hashes files placed by hand or left unstamped. Quiet: the row simply
    /// shows DOWNLOADED once they pass, or DOWNLOAD when they do not.
    func verifyInstalledAtLaunch(_ onChange: @escaping @MainActor @Sendable () -> Void) {
        for variant in Qwen3ASRVariant.allCases where Qwen3ASRModelStore.needsVerification(variant) && !verifying.contains(variant) {
            verifying.insert(variant)
            DispatchQueue.global(qos: .utility).async {
                Qwen3ASRModelStore.verifyExisting(variant)
                Task { @MainActor in
                    self.verifying.remove(variant)
                    onChange()
                }
            }
        }
    }

    /// Fetches the first file that is not verified yet, or finishes.
    private func next(_ option: ModelOption, variant: Qwen3ASRVariant) {
        let pending = variant.files.filter { !Qwen3ASRModelStore.isVerified($0) }
        guard let file = pending.first else {
            running.remove(variant)
            downloaders[variant] = nil
            callbacks.finished(option)
            return
        }
        let doneBytes = variant.files
            .filter { Qwen3ASRModelStore.isVerified($0) }
            .reduce(Int64(0)) { $0 + $1.sizeBytes }
        let downloader = CleanupModelDownloader(source: file.url)
        downloaders[variant] = downloader
        downloader.start(
            stagingURL: Qwen3ASRModelStore.stagingURL(for: file),
            progress: { [weak self] fraction in
                guard let self, self.running.contains(variant) else { return }
                self.callbacks.progress(option.id, Self.overallFraction(
                    variant: variant, doneBytes: doneBytes, current: file, fraction: fraction
                ))
            },
            completion: { [weak self] result in
                self?.finishFile(file, option: option, variant: variant, result: result)
            }
        )
    }

    private func finishFile(_ file: Qwen3ASRFile, option: ModelOption, variant: Qwen3ASRVariant, result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            running.remove(variant)
            downloaders[variant] = nil
            if (error as? CleanupModelError) == .canceled {
                callbacks.canceled(option)
            } else {
                callbacks.failed(option, error)
            }
        case .success(let staged):
            callbacks.progress(option.id, -1)
            DispatchQueue.global(qos: .utility).async {
                var failure: Error?
                do {
                    try Qwen3ASRModelStore.install(file, downloadedFile: staged)
                } catch {
                    failure = error
                }
                let installError = failure
                Task { @MainActor in
                    if let installError {
                        self.running.remove(variant)
                        self.downloaders[variant] = nil
                        self.callbacks.failed(option, installError)
                    } else {
                        self.next(option, variant: variant)
                    }
                }
            }
        }
    }
}
