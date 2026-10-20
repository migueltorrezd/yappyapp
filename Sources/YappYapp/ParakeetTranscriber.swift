import FluidAudio
import Foundation

func configureParakeetDownloads(allowed: Bool) {
    // All network access is owned by ModelDownloadManager, which pins the
    // repository revision and verifies every file before publishing a cache
    // manifest. FluidAudio must stay offline even when the UI allows downloads
    // or its load/recovery path could silently fetch mutable upstream content.
    _ = allowed
    ModelHub.offlineMode = true
}

func asrVersion(forVariant variant: String) -> AsrModelVersion {
    switch variant {
    case "v2": .v2
    case "tdtCtc110m": .tdtCtc110m
    case "tdtJa": .tdtJa
    case "ultra": .ultra
    default: .v3
    }
}

/// True when the CoreML bundle for this Parakeet variant is already cached.
func parakeetModelDownloaded(variant: String) -> Bool {
    ModelDownloadManager.isVerifiedParakeetCache(variant: variant)
}

func parakeetCacheDirectoryPath(variant: String) -> String {
    let version = asrVersion(forVariant: variant)
    return AsrModels.defaultCacheDirectory(for: version).path
}

/// YappYapp owns Parakeet repository listing and file transfer so it can pin and
/// verify every dependency. Loading/compilation remains a separate local phase
/// handled by FluidAudio after the verified cache has been published.
enum ParakeetDownloadPhase: Sendable { case listing, downloading }

struct ParakeetDownloadProgress: Sendable {
    let fraction: Double      // 0...1, as reported by the verified downloader
    let phase: ParakeetDownloadPhase
}

/// Fetches the CoreML bundle for a variant without loading it into memory,
/// so a download never disturbs the model currently serving dictations.
/// Progress callbacks arrive on an arbitrary queue.
func downloadParakeetModel(
    variant: String,
    downloadsAllowed: Bool,
    progress: @escaping @Sendable (ParakeetDownloadProgress) -> Void
) async throws {
    guard downloadsAllowed else {
        throw DownloadError.networkDisabled(operation: "download verified Parakeet model")
    }
    try await ModelDownloadManager.downloadParakeet(variant: variant, progress: progress)
}

/// NVIDIA Parakeet engine via FluidAudio's CoreML port. Models are fetched by
/// YappYapp's verified downloader, then stay loaded in memory (the in-process
/// equivalent of the warm whisper-server).
actor ParakeetTranscriber {
    private var manager: AsrManager?
    private var loadedVariant: String?
    // FIX loadGen: every load request, and every unload, bumps this token. A
    // load may only install its result while its captured generation is still
    // the latest; a superseded load (newer variant selected, or unloaded)
    // discards its manager instead of clobbering the active model.
    private var loadGeneration = 0
    private var inFlight: (variant: String, generation: Int, task: Task<AsrManager, Error>)?
    // LIVE-PREVIEW: FIFO turn-taking for decodes on the one AsrManager.
    // Actor reentrancy would otherwise let two decodes interleave at their
    // suspension points.
    private var decodeBusy = false
    private var decodeWaiters: [CheckedContinuation<Void, Never>] = []

    func isLoaded(variant: String) -> Bool {
        manager != nil && loadedVariant == variant
    }

    /// Downloads and loads the model ahead of time (called on selection).
    func preload(variant: String) async throws {
        _ = try await loadIfNeeded(variant: variant)
    }

    func transcribe(audioURL: URL, variant: String) async throws -> String {
        let manager = try await loadIfNeeded(variant: variant)

        // LIVE-PREVIEW: one decode at a time on the shared manager. A dictation
        // waits for at most one in-flight preview or file chunk; a preview
        // never waits behind a dictation (it skips instead).
        await acquireDecodeTurn()
        defer { releaseDecodeTurn() }

        // Fresh decoder state per dictation: each recording is independent.
        var decoderState = TdtDecoderState.make()
        let result = try await manager.transcribe(audioURL, decoderState: &decoderState)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else {
            throw WhisperError.emptyTranscript
        }

        return text
    }

    /// LIVE-PREVIEW: decodes in-memory 16 kHz samples for the HUD preview.
    /// Returns nil without decoding when the model is not loaded yet or any
    /// other decode holds the manager, so a preview never delays a dictation
    /// and never triggers a model load on its own.
    func transcribePreview(samples: [Float], variant: String) async throws -> String? {
        guard let manager, loadedVariant == variant, !decodeBusy else { return nil }
        decodeBusy = true
        defer { releaseDecodeTurn() }
        var decoderState = TdtDecoderState.make()
        let result = try await manager.transcribe(samples, decoderState: &decoderState)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func acquireDecodeTurn() async {
        guard decodeBusy else {
            decodeBusy = true
            return
        }
        await withCheckedContinuation { decodeWaiters.append($0) }
    }

    private func releaseDecodeTurn() {
        if decodeWaiters.isEmpty {
            decodeBusy = false
        } else {
            // Hand the turn straight to the next waiter; decodeBusy stays true.
            decodeWaiters.removeFirst().resume()
        }
    }

    func unload() {
        manager = nil
        loadedVariant = nil
        // FIX loadGen: invalidate any in-flight load so a load that completes
        // after this unload cannot silently re-install the model the user just
        // dropped.
        loadGeneration += 1
        inFlight = nil
    }

    private func loadIfNeeded(variant: String) async throws -> AsrManager {
        if let manager, loadedVariant == variant {
            return manager
        }

        // A dictation arriving mid-download for the same variant must wait for
        // that same load, not start a second one.
        if let inFlight, inFlight.variant == variant {
            return try await inFlight.task.value
        }

        // FIX loadGen: a newer request (this one) supersedes any in-flight load
        // for a different variant. Bump the generation so the older load, when
        // it finishes, discards its result instead of clobbering active state.
        loadGeneration += 1
        let generation = loadGeneration
        let version = asrVersion(forVariant: variant)

        let task = Task<AsrManager, Error> {
            guard ModelDownloadManager.isVerifiedParakeetCache(variant: variant) else {
                throw WhisperError.modelUnavailable(
                    L10n.tr("This Parakeet model didn't verify. Download it again in MODELS.")
                )
            }

            // Defense in depth: AsrModels.load delegates to ModelHub,
            // whose normal recovery behavior deletes and re-downloads a cache
            // after a compile failure. Keep it offline so only the verified
            // local files can participate in transcription.
            ModelHub.offlineMode = true
            let models = try await AsrModels.load(
                from: AsrModels.defaultCacheDirectory(for: version),
                version: version,
                encoderPrecision: .int8
            )
            let newManager = AsrManager(config: .default)
            try await newManager.loadModels(models)
            return newManager
        }
        inFlight = (variant, generation, task)

        let newManager: AsrManager
        do {
            newManager = try await task.value
        } catch {
            // Only clear the in-flight slot if it is still ours.
            if inFlight?.generation == generation {
                inFlight = nil
            }
            throw error
        }

        // FIX loadGen: install only if still the latest requested load. A
        // superseded load (deselected variant, or an intervening unload())
        // returns its manager to this caller but never becomes the active model.
        guard generation == loadGeneration else {
            return newManager
        }

        manager = newManager
        loadedVariant = variant
        if inFlight?.generation == generation {
            inFlight = nil
        }
        return newManager
    }
}

