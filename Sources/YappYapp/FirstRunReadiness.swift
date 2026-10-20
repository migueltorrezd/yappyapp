import Foundation

// YA-01: what stops a dictation before the mic opens, and how to say it.
// Pure so the self-tests can walk every branch without a model on disk.

struct MissingModelNotice: Equatable {
    let modelID: String
    let modelName: String
    let downloadsAllowed: Bool
    let downloadProgress: Double?

    /// Every missing-model message starts with this, so the HUD can show a
    /// specific label instead of a generic error.
    static var messagePrefix: String { L10n.tr("No voice model yet.") }
    static var hudLabel: String { L10n.tr("NO MODEL") }

    var message: String {
        if let downloadProgress, downloadProgress >= 0 {
            let percent = Int(min(max(downloadProgress, 0), 1) * 100)
            return "\(Self.messagePrefix) " + L10n.tr("Downloading %@ (%@%%). You can dictate the moment it finishes.", modelName, "\(percent)")
        }
        if downloadProgress != nil {
            return "\(Self.messagePrefix) " + L10n.tr("%@ is almost ready. You can dictate the moment it finishes.", modelName)
        }
        if downloadsAllowed {
            return "\(Self.messagePrefix) " + L10n.tr("Download %@ below to start dictating.", modelName)
        }
        return "\(Self.messagePrefix) " + L10n.tr("Model downloads are off. Turn them on in Setup, or ask your IT admin for %@.", modelName)
    }

    /// The DOWNLOAD action only makes sense when nothing is in flight and
    /// downloads are allowed.
    var offersDownload: Bool {
        downloadsAllowed && downloadProgress == nil
    }
}

enum RecordingPrerequisite: Equatable {
    case ready
    case missingModel(MissingModelNotice)
    case blocked(String)

    var message: String? {
        switch self {
        case .ready: nil
        case .missingModel(let notice): notice.message
        case .blocked(let message): message
        }
    }

    static func evaluate(
        config: AppConfig,
        selectedOption: ModelOption?,
        selectedModelInstalled: Bool,
        downloadProgress: Double?,
        whisperReadiness: (binary: Bool, model: Bool),
        isPackagedApp: Bool = false,
        qwen3RuntimeAvailable: Bool = true
    ) -> RecordingPrerequisite {
        let engine = ModelCatalog.engine(for: config.modelPath)

        // QWEN3-ASR: the verified model files and the bundled audio helper.
        if engine == .qwen3asr {
            guard selectedModelInstalled else {
                return .missingModel(MissingModelNotice(
                    modelID: selectedOption?.id ?? "qwen3asr-0.6b",
                    modelName: selectedOption?.name ?? "Qwen3-ASR",
                    downloadsAllowed: config.allowModelDownloads,
                    downloadProgress: downloadProgress
                ))
            }
            guard qwen3RuntimeAvailable else {
                return .blocked(Qwen3ASRError.runtimeMissing.localizedDescription)
            }
            return .ready
        }

        if engine == .parakeet {
            guard selectedModelInstalled else {
                return .missingModel(MissingModelNotice(
                    modelID: selectedOption?.id ?? ModelCatalog.recommendedID,
                    modelName: selectedOption?.name ?? L10n.tr("Parakeet"),
                    downloadsAllowed: config.allowModelDownloads,
                    downloadProgress: downloadProgress
                ))
            }
            return .ready
        }

        if !whisperReadiness.binary {
            // YA-73: no file paths or terminal hints for DMG users.
            return .blocked(WhisperRuntimeCopy.missingBlockedMessage(
                isPackagedApp: isPackagedApp,
                binaryPath: config.whisperBinaryPath.expandingTildeInPath
            ))
        }
        if !whisperReadiness.model {
            // A catalog Whisper model can be downloaded in one click; a custom
            // path cannot, so it keeps the literal file error.
            guard let selectedOption else {
                return .blocked(WhisperError.modelMissing(config.modelPath.expandingTildeInPath).localizedDescription)
            }
            return .missingModel(MissingModelNotice(
                modelID: selectedOption.id,
                modelName: selectedOption.name,
                downloadsAllowed: config.allowModelDownloads,
                downloadProgress: downloadProgress
            ))
        }
        return .ready
    }
}

// YA-01: the 900 s leash existed for a first-use download that no longer
// happens (FluidAudio is forced offline). A cold load from the verified cache
// still compiles CoreML, so it gets a modest extra margin.
// YA-05: the budgets themselves live in TranscriptionTimeouts and scale with
// the recording; these are the floors for a short dictation.
enum TranscriptionWatchdog {
    static let warmTimeoutSeconds: UInt64 = 90
    static let coldParakeetTimeoutSeconds: UInt64 = 180

    static func timeoutSeconds(
        isParakeet: Bool,
        isLoaded: Bool,
        audioSeconds: TimeInterval = 0,
        beamSearch: Bool = false,
        isQwen3ASR: Bool = false
    ) -> UInt64 {
        let interval = isParakeet
            ? TranscriptionTimeouts.parakeetWatchdog(audioSeconds: audioSeconds, modelLoaded: isLoaded)
            : isQwen3ASR
                ? TranscriptionTimeouts.qwen3ASRWatchdog(audioSeconds: audioSeconds)
                : TranscriptionTimeouts.whisperWatchdog(audioSeconds: audioSeconds, beamSearch: beamSearch)
        return UInt64(interval.rounded(.up))
    }
}

// YA-25: English-only models transcribe in English, but the saved language is
// the user's choice and survives switching models. Resolve it per dictation.
enum TranscriptionLanguage {
    static func effectiveLanguage(for config: AppConfig) -> String {
        let selectedID = ModelCatalog.selectedID(for: config.modelPath)
        if let option = ModelCatalog.option(for: selectedID),
           ModelActivationPlanner.forcesEnglishLanguage(option) {
            return "en"
        }
        return config.language
    }

    /// A copy of the config for transcription only. Never saved.
    static func transcriptionConfig(from config: AppConfig) -> AppConfig {
        var copy = config
        copy.language = effectiveLanguage(for: config)
        return copy
    }
}
