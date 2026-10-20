import Foundation

struct ModelActivationPlan: Equatable {
    let config: AppConfig
    let shouldPreloadParakeet: Bool
    let statusText: String?
}

enum ModelActivationPlanner {
    static func plan(currentConfig: AppConfig, option: ModelOption) -> ModelActivationPlan {
        var config = currentConfig
        config.modelPath = option.defaultPath
        // YA-25: the saved language is never rewritten here. English-only
        // models resolve to English per dictation (TranscriptionLanguage).

        return ModelActivationPlan(
            config: config,
            shouldPreloadParakeet: option.engine == .parakeet,
            statusText: option.engine == .parakeet
                ? nil
                : L10n.tr("Using %@. It runs on this Mac.", option.name)
        )
    }

    static func forcesEnglishLanguage(_ option: ModelOption) -> Bool {
        option.id.hasSuffix("-en")
            || option.parakeetVariant == "v2"
            || option.parakeetVariant == "tdtCtc110m"
    }
}
