import Foundation

enum ModelEngine: String, Sendable {
    case whisper
    case parakeet
    /// QWEN3-ASR: 52 languages through the bundled llama.cpp runtime.
    case qwen3asr
}

struct ModelOption: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let filename: String
    let badge: String
    let summary: String
    /// Bytes fetched by a download of the pinned revision. Read from the
    /// Hugging Face tree API on 2026-10-16: the whisper.cpp file at
    /// `ModelDownloadManager.whisperModelRevision`, or the sum of the files
    /// `ParakeetModelDistribution.plan(for:)` keeps. Nil means unknown, and
    /// the Models row then shows no size.
    var downloadBytes: Int64? = nil
    var expectedSHA1: String? = nil
    var engine: ModelEngine = .whisper
    /// FluidAudio model version key for parakeet options.
    var parakeetVariant: String?
    /// QWEN3-ASR: which size, for qwen3asr options.
    var qwen3Variant: Qwen3ASRVariant? = nil

    var defaultPath: String {
        if engine == .parakeet {
            return "parakeet://\(parakeetVariant ?? "v3")"
        }
        if engine == .qwen3asr {
            return (qwen3Variant ?? .small).modelPath
        }
        return AppPaths.defaultModelPath(for: filename)
    }

    var expandedPath: String {
        defaultPath.expandingTildeInPath
    }

    var isInstalled: Bool {
        if engine == .parakeet {
            return parakeetModelDownloaded(variant: parakeetVariant ?? "v3")
        }
        if engine == .qwen3asr {
            // Installed means both files are on disk and verified.
            return Qwen3ASRModelStore.isVerified(qwen3Variant ?? .small)
        }
        return FileManager.default.fileExists(atPath: expandedPath)
    }

    /// The download size for the Models row, for example "483 MB".
    var sizeLabel: String? {
        guard let downloadBytes, downloadBytes > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: downloadBytes, countStyle: .file)
    }
}

enum ModelCatalog {
    static let options: [ModelOption] = [
        // PARAKEET-FIRST: Parakeet leads the picker and Parakeet Ultra is the
        // app default: much faster than Whisper Large at comparable accuracy,
        // multilingual, and a one-click, verified download. Ultra is a
        // post-trained TDT v3 (same 25 languages, same speed, lower error
        // rate); v3 stays offered for people who already have it.
        ModelOption(
            id: "parakeet-ultra",
            name: "Parakeet Ultra",
            filename: "",
            badge: "Multi max",
            summary: "25 European languages. Picks the language itself. The most accurate Parakeet.",
            downloadBytes: 632162964,
            engine: .parakeet,
            parakeetVariant: "ultra"
        ),
        ModelOption(
            id: "parakeet-v3",
            name: "Parakeet TDT v3",
            filename: "",
            badge: "Multi",
            summary: "25 European languages. Picks the language itself. Fast and accurate.",
            downloadBytes: 483105645,
            engine: .parakeet,
            parakeetVariant: "v3"
        ),
        ModelOption(
            id: "parakeet-v2",
            name: "Parakeet TDT v2",
            filename: "",
            badge: "EN max",
            summary: "English only. Very accurate.",
            downloadBytes: 464413247,
            engine: .parakeet,
            parakeetVariant: "v2"
        ),
        ModelOption(
            id: "parakeet-110m",
            name: "Parakeet 110M",
            filename: "",
            badge: "EN tiny",
            summary: "English only. Tiny and very quick, less accurate.",
            downloadBytes: 227466209,
            engine: .parakeet,
            parakeetVariant: "tdtCtc110m"
        ),
        ModelOption(
            id: "parakeet-ja",
            name: "Parakeet Japanese",
            filename: "",
            badge: "JA",
            summary: "Made for Japanese.",
            downloadBytes: 619065246,
            engine: .parakeet,
            parakeetVariant: "tdtJa"
        ),
        ModelOption(
            id: "large-v3-turbo",
            name: "Large v3 Turbo",
            filename: "ggml-large-v3-turbo.bin",
            badge: "High",
            summary: "Many languages. Good balance of speed and quality.",
            downloadBytes: 1624555275,
            expectedSHA1: "4af2b29d7ec73d781377bfd1758ca957a807e941"
        ),
        ModelOption(
            id: "large-v3",
            name: "Large v3",
            filename: "ggml-large-v3.bin",
            badge: "Max",
            summary: "Many languages. Most accurate Whisper, and slower.",
            downloadBytes: 3095033483,
            expectedSHA1: "ad82bf6a9043ceed055076d0fd39f5f186ff8062"
        ),
        ModelOption(
            id: "medium",
            name: "Medium",
            filename: "ggml-medium.bin",
            badge: "Balanced",
            summary: "Many languages. Good quality.",
            downloadBytes: 1533763059,
            expectedSHA1: "fd9727b6e1217c2f614f9b698455c4ffd82463b4"
        ),
        ModelOption(
            id: "small",
            name: "Small",
            filename: "ggml-small.bin",
            badge: "Fast",
            summary: "Many languages. Quicker, less accurate.",
            downloadBytes: 487601967,
            expectedSHA1: "55356645c2b361a969dfd0ef2c5a50d530afd8d5"
        ),
        ModelOption(
            id: "base",
            name: "Base",
            filename: "ggml-base.bin",
            badge: "Light",
            summary: "Many languages. Light and quick.",
            downloadBytes: 147951465,
            expectedSHA1: "465707469ff3a37a2b9b8d8f89f2f99de7299dac"
        ),
        ModelOption(
            id: "tiny",
            name: "Tiny",
            filename: "ggml-tiny.bin",
            badge: "Tiny",
            summary: "Many languages. Smallest and quickest, least accurate.",
            downloadBytes: 77691713,
            expectedSHA1: "bd577a113a864445d4c299885e0cb97d4ba92b5f"
        ),
        ModelOption(
            id: "medium-en",
            name: "Medium English",
            filename: "ggml-medium.en.bin",
            badge: "EN high",
            summary: "English only. Good quality.",
            downloadBytes: 1533774781,
            expectedSHA1: "8c30f0e44ce9560643ebd10bbe50cd20eafd3723"
        ),
        ModelOption(
            id: "small-en",
            name: "Small English",
            filename: "ggml-small.en.bin",
            badge: "EN fast",
            summary: "English only. Quicker.",
            downloadBytes: 487614201,
            expectedSHA1: "db8a495a91d927739e50b3fc1cc4c6b8f6c2d022"
        ),
        ModelOption(
            id: "base-en",
            name: "Base English",
            filename: "ggml-base.en.bin",
            badge: "EN light",
            summary: "English only. Light.",
            downloadBytes: 147964211,
            expectedSHA1: "137c40403d78fd54d454da0f9bd998f78703390c"
        ),
        ModelOption(
            id: "tiny-en",
            name: "Tiny English",
            filename: "ggml-tiny.en.bin",
            badge: "EN tiny",
            summary: "English only. Smallest.",
            downloadBytes: 77704715,
            expectedSHA1: "c78c86eb1a8faa21b369bcd33207cc90d64ae9df"
        ),
        // QWEN3-ASR: for the languages Parakeet does not cover (Chinese,
        // Japanese, Korean, Arabic, Hindi and more). Sizes are the pinned
        // model plus its audio projector (Qwen3ASRVariant.files).
        ModelOption(
            id: "qwen3asr-0.6b",
            name: "Qwen3-ASR 0.6B",
            filename: "",
            badge: "Fast",
            summary: "52 languages, Chinese and Japanese too. Picks the language itself. Quick.",
            downloadBytes: Qwen3ASRVariant.small.downloadBytes,
            engine: .qwen3asr,
            qwen3Variant: .small
        ),
        ModelOption(
            id: "qwen3asr-1.7b",
            name: "Qwen3-ASR 1.7B",
            filename: "",
            badge: "High",
            summary: "52 languages, Chinese and Japanese too. Most accurate of the two. Best on a recent Mac.",
            downloadBytes: Qwen3ASRVariant.large.downloadBytes,
            engine: .qwen3asr,
            qwen3Variant: .large
        )
    ]

    /// The model a fresh install uses (`AppConfig.defaultConfig`). The
    /// Models tab tags it RECOMMENDED.
    static var recommendedID: String {
        selectedID(for: AppConfig.defaultConfig.modelPath)
    }

    static func option(for id: String) -> ModelOption? {
        options.first { $0.id == id }
    }

    static func selectedID(for modelPath: String) -> String {
        if modelPath.hasPrefix("parakeet://") {
            let variant = String(modelPath.dropFirst("parakeet://".count))
            return options.first(where: { $0.parakeetVariant == variant })?.id ?? "parakeet-v3"
        }
        if modelPath.hasPrefix(Qwen3ASRVariant.scheme) {
            let variant = Qwen3ASRVariant.from(modelPath: modelPath) ?? .small
            return options.first(where: { $0.qwen3Variant == variant })?.id ?? "qwen3asr-0.6b"
        }

        let filename = URL(fileURLWithPath: modelPath.expandingTildeInPath).lastPathComponent
        return options.first(where: { $0.filename == filename })?.id ?? "custom"
    }

    static func displayName(for modelPath: String) -> String {
        if modelPath.hasPrefix("parakeet://") {
            return option(for: selectedID(for: modelPath))?.name ?? "Parakeet"
        }
        if modelPath.hasPrefix(Qwen3ASRVariant.scheme) {
            return option(for: selectedID(for: modelPath))?.name ?? "Qwen3-ASR"
        }

        let filename = URL(fileURLWithPath: modelPath.expandingTildeInPath).lastPathComponent
        return options.first(where: { $0.filename == filename })?.name ?? filename
    }

    static func engine(for modelPath: String) -> ModelEngine {
        if modelPath.hasPrefix("parakeet://") { return .parakeet }
        if modelPath.hasPrefix(Qwen3ASRVariant.scheme) { return .qwen3asr }
        return .whisper
    }
}
