import Foundation

struct ModelReadinessSnapshot: Equatable {
    let selectedModelID: String
    let selectedModelName: String
    let isWhisperReady: Bool
    let isModelReady: Bool
}

enum ModelReadinessPresenter {
    static func snapshot(
        config: AppConfig,
        whisperReadiness: (binary: Bool, model: Bool),
        selectedModelInstalled: Bool = false,
        qwen3RuntimeAvailable: Bool = true
    ) -> ModelReadinessSnapshot {
        let selectedModelID = ModelCatalog.selectedID(for: config.modelPath)
        let selectedModelName = ModelCatalog.displayName(for: config.modelPath)

        if ModelCatalog.engine(for: config.modelPath) == .parakeet {
            return ModelReadinessSnapshot(
                selectedModelID: selectedModelID,
                selectedModelName: selectedModelName,
                isWhisperReady: true,
                // YA-01: ready means installed. FluidAudio is forced offline,
                // so "downloads allowed" no longer fetches anything on its own.
                isModelReady: selectedModelInstalled
            )
        }

        // QWEN3-ASR: the runtime is the bundled llama.cpp audio helper, and
        // the model is ready once both of its files are verified.
        if ModelCatalog.engine(for: config.modelPath) == .qwen3asr {
            return ModelReadinessSnapshot(
                selectedModelID: selectedModelID,
                selectedModelName: selectedModelName,
                isWhisperReady: qwen3RuntimeAvailable,
                isModelReady: selectedModelInstalled
            )
        }

        return ModelReadinessSnapshot(
            selectedModelID: selectedModelID,
            selectedModelName: selectedModelName,
            isWhisperReady: whisperReadiness.binary,
            isModelReady: whisperReadiness.model
        )
    }

    static func parakeetOfflineMissingMessage(optionName: String) -> String {
        L10n.tr("%@ isn't downloaded, and downloads are off. Turn them on in Setup, or ask your IT admin.", optionName)
    }
}
