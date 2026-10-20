import Foundation

/// YA-50: what to do with the in-process Parakeet model when the selected
/// engine changes or the app launches. Parakeet holds hundreds of megabytes,
/// so it is released as soon as a Whisper or Qwen3-ASR model takes over. At launch, an
/// installed Parakeet model that the user keeps warm loads right away, so the
/// first dictation does not pay for it.
enum ParakeetMemoryPolicy {
    enum Action: Equatable {
        case none
        case release
        case preload(variant: String)
    }

    static func action(
        engine: ModelEngine,
        parakeetVariant: String?,
        selectedInstalled: Bool,
        keepModelWarm: Bool,
        atLaunch: Bool
    ) -> Action {
        switch engine {
        case .whisper, .qwen3asr:
            return .release
        case .parakeet:
            guard atLaunch, keepModelWarm, selectedInstalled, let parakeetVariant else { return .none }
            return .preload(variant: parakeetVariant)
        }
    }
}
