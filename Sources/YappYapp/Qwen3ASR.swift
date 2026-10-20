import Foundation

// QWEN3-ASR: a third speech engine for the languages Parakeet does not cover.
// Qwen3-ASR (Alibaba, Apache-2.0) recognizes 52 languages and dialects and
// detects the language itself. It runs through the same bundled llama.cpp
// runtime as cleanup and translation, as an audio model with a projector
// (mtmd): a warm llama-server while the model is in use and "keep the model
// warm" is on, else the one-shot llama-mtmd-cli.
//
// Everything in this file is pure (pins, paths, prompt, output rules, budgets)
// so the self-tests and unit tests pin it.

/// Pinned Hugging Face revisions of the official GGUF conversions, read from
/// the Hugging Face model API (api/models/<repo>?blobs=true) on 2026-10-18.
/// The weights are Apache-2.0 per the upstream Qwen/Qwen3-ASR-* model cards.
let Qwen3ASRSmallPinnedRevision = "928ab958557df9aa2ef1c93e0e83c7ad0933fae2"
let Qwen3ASRLargePinnedRevision = "36a678687ba7d07a74ca70ccb0e36902e005fb80"

/// One pinned GGUF file of a Qwen3-ASR model: the language model or its
/// audio projector.
struct Qwen3ASRFile: Equatable, Sendable {
    enum Role: String, Sendable {
        case model
        case projector
    }

    let role: Role
    let filename: String
    let url: URL
    let sha256: String
    let sizeBytes: Int64
}

/// The two sizes the app offers. The raw value is the part after
/// `qwen3asr://` in config.json.
enum Qwen3ASRVariant: String, CaseIterable, Sendable {
    case small = "0.6b"
    case large = "1.7b"

    static let scheme = "qwen3asr://"

    var modelPath: String { Self.scheme + rawValue }

    var repo: String {
        switch self {
        case .small: "ggml-org/Qwen3-ASR-0.6B-GGUF"
        case .large: "ggml-org/Qwen3-ASR-1.7B-GGUF"
        }
    }

    var revision: String {
        switch self {
        case .small: Qwen3ASRSmallPinnedRevision
        case .large: Qwen3ASRLargePinnedRevision
        }
    }

    /// Q8_0 for both: the model card's own conversion, small enough for any
    /// Apple silicon Mac and without the accuracy loss of a 4-bit file.
    var files: [Qwen3ASRFile] {
        switch self {
        case .small:
            [
                file(.model, "Qwen3-ASR-0.6B-Q8_0.gguf",
                     sha256: "bca259818b50ca7c4c05e9bdb35a5dc04fa039653a6d6f3f0f331f96f6aa1971", size: 804_749_248),
                file(.projector, "mmproj-Qwen3-ASR-0.6B-Q8_0.gguf",
                     sha256: "41a342b5e4c514e968cb756de6cd1b7be39eff43c44c57a2ef5fc6522e36603d", size: 214_392_480)
            ]
        case .large:
            [
                file(.model, "Qwen3-ASR-1.7B-Q8_0.gguf",
                     sha256: "58e22d0532d4eacaf034cfac17a6fed159f37c41390c710186783be439d1fc57", size: 2_165_034_944),
                file(.projector, "mmproj-Qwen3-ASR-1.7B-Q8_0.gguf",
                     sha256: "46c1d533af3f354ceb37ce855dbceff7da7fa7cf1e6a523df3b13440bd164c0d", size: 355_709_344)
            ]
        }
    }

    var modelFile: Qwen3ASRFile { files.first { $0.role == .model }! }
    var projectorFile: Qwen3ASRFile { files.first { $0.role == .projector }! }

    var downloadBytes: Int64 { files.reduce(0) { $0 + $1.sizeBytes } }

    /// The variant a `qwen3asr://` model path names, or nil.
    static func from(modelPath: String) -> Qwen3ASRVariant? {
        guard modelPath.hasPrefix(scheme) else { return nil }
        return Qwen3ASRVariant(rawValue: String(modelPath.dropFirst(scheme.count)))
    }

    private func file(_ role: Qwen3ASRFile.Role, _ filename: String, sha256: String, size: Int64) -> Qwen3ASRFile {
        Qwen3ASRFile(
            role: role,
            filename: filename,
            url: URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(filename)")!,
            sha256: sha256,
            sizeBytes: size
        )
    }
}

// MARK: - On disk

/// The two GGUF files of each variant sit flat in the models folder, each
/// with the same SHA-256 stamp the translation models use: hashed once after
/// the download, then checked by size and modification date.
enum Qwen3ASRModelStore {
    static func url(for file: Qwen3ASRFile) -> URL {
        AppPaths.modelsDirectory.appendingPathComponent(file.filename)
    }

    static func stampURL(for file: Qwen3ASRFile) -> URL {
        AppPaths.modelsDirectory.appendingPathComponent(".\(file.filename).verified.json")
    }

    static func stagingURL(for file: Qwen3ASRFile) -> URL {
        AppPaths.modelsDirectory.appendingPathComponent("\(file.filename).download")
    }

    static func modelURL(_ variant: Qwen3ASRVariant) -> URL { url(for: variant.modelFile) }
    static func projectorURL(_ variant: Qwen3ASRVariant) -> URL { url(for: variant.projectorFile) }

    static func isVerified(_ file: Qwen3ASRFile) -> Bool {
        CleanupModelStore.isVerified(modelURL: url(for: file), stampURL: stampURL(for: file), expectedSHA1: file.sha256)
    }

    /// Ready to run: both files are on disk and match their pinned SHA-256.
    static func isVerified(_ variant: Qwen3ASRVariant) -> Bool {
        variant.files.allSatisfy(isVerified)
    }

    /// At least one file is on disk without a stamp, for example one placed
    /// by hand or left by an interrupted install: worth hashing at launch.
    static func needsVerification(_ variant: Qwen3ASRVariant) -> Bool {
        variant.files.contains { FileManager.default.fileExists(atPath: url(for: $0).path) && !isVerified($0) }
    }

    /// Hashes unstamped files. Slow: call it off the main thread.
    @discardableResult
    static func verifyExisting(_ variant: Qwen3ASRVariant) -> Bool {
        var allVerified = true
        for file in variant.files where !isVerified(file) {
            let verified = (try? CleanupModelStore.verifyExisting(
                modelURL: url(for: file),
                stampURL: stampURL(for: file),
                expectedSHA1: file.sha256,
                sha1: ModelIntegrity.sha256Hex(for:)
            )) ?? false
            allVerified = allVerified && verified
        }
        return allVerified
    }

    /// Checks a finished download and moves it into place. A file that fails
    /// the SHA-256 is deleted and never becomes part of the model.
    static func install(_ file: Qwen3ASRFile, downloadedFile: URL) throws {
        try CleanupModelStore.install(
            downloadedFile: downloadedFile,
            modelURL: url(for: file),
            stampURL: stampURL(for: file),
            expectedSHA1: file.sha256,
            sha1: ModelIntegrity.sha256Hex(for:)
        )
    }

    static func delete(_ variant: Qwen3ASRVariant) {
        let fileManager = FileManager.default
        for file in variant.files {
            for url in [url(for: file), stampURL(for: file), stagingURL(for: file)] {
                try? fileManager.removeItem(at: url)
            }
        }
    }
}

// MARK: - Runtime

/// The bundled helpers that run Qwen3-ASR. Both ship next to the cleanup
/// runtime's llama-completion and come from the same pinned llama.cpp build;
/// a llama-cli the user chose never runs an audio model.
enum Qwen3ASRRuntime {
    static let cliBinaryName = "llama-mtmd-cli"

    static func cliBinaryPath(forRuntimeBinary runtimeBinary: String) -> String {
        URL(fileURLWithPath: runtimeBinary)
            .deletingLastPathComponent()
            .appendingPathComponent(cliBinaryName)
            .path
    }

    /// The one-shot helper next to the bundled `llama-completion`, or nil.
    static func bundledCLI(runtimeBinary: String?, launchable: (String) -> String?) -> String? {
        guard let runtimeBinary, LLMCleaner.Runtime.of(binaryPath: runtimeBinary) == .completion else {
            return nil
        }
        return launchable(cliBinaryPath(forRuntimeBinary: runtimeBinary))
    }

    /// Either helper can transcribe; the server alone is enough while warm.
    static func isAvailable(runtimeBinary: String?, launchable: (String) -> String?) -> Bool {
        bundledCLI(runtimeBinary: runtimeBinary, launchable: launchable) != nil
            || LlamaServerPolicy.bundledServer(runtimeBinary: runtimeBinary, launchable: launchable) != nil
    }

    static func isAvailable(configuredLlamaBinary: String) -> Bool {
        isAvailable(
            runtimeBinary: LLMCleaner.binaryPath(configured: configuredLlamaBinary),
            launchable: { HelperBinaryPolicy.launchablePath($0) }
        )
    }
}

// MARK: - Prompt and output (model card)

enum Qwen3ASRPrompt {
    /// Holds about 25 minutes of speech per request. The app cuts longer
    /// audio well before that (see `chunkSeconds`).
    static let contextTokens = 8_192

    /// The audio encoder emits about 13 tokens per second of audio. Four
    /// minutes plus a generous transcript budget stay far below the context.
    static let chunkSeconds = 240

    /// The model card's canonical language names, for the app's dictation
    /// languages. AUTO (and anything unknown) lets the model detect it.
    static func languageName(for code: String) -> String? {
        switch code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "en": "English"
        case "fr": "French"
        case "es": "Spanish"
        case "nl": "Dutch"
        case "de": "German"
        case "it": "Italian"
        case "pt": "Portuguese"
        case "ja": "Japanese"
        case "zh": "Chinese"
        case "ko": "Korean"
        default: nil
        }
    }

    /// Model card: with a known language, the assistant turn starts with
    /// "language <Name><asr_text>" so the model writes only the transcript.
    /// nil lets it detect the language and write that header itself.
    static func assistantPrefill(language code: String) -> String? {
        languageName(for: code).map { "language \($0)<asr_text>" }
    }

    /// Most words the context carries. The model card puts no limit on it,
    /// but a long list costs prompt time on every request.
    static let contextTermLimit = 40

    /// Model card (QwenLM qwen_asr `_build_messages`): the system turn is
    /// free text context, empty when there is none. WORDS-AS-HINTS: the
    /// user's own spellings, comma separated, so a rare name is spelled
    /// their way. Chat markup is stripped so a word can never open a turn.
    static func context(glossary: Glossary) -> String {
        context(terms: glossary.canonicalTerms)
    }

    static func context(terms: [String]) -> String {
        var seen = Set<String>()
        var kept: [String] = []
        for term in terms {
            let clean = sanitized(term)
            guard !clean.isEmpty, seen.insert(clean.lowercased()).inserted else { continue }
            kept.append(clean)
            if kept.count == contextTermLimit { break }
        }
        return kept.joined(separator: ", ")
    }

    /// One term without chat markup, the CLI's part separator or line breaks.
    static func sanitized(_ term: String) -> String {
        var text = term
        for marker in [Qwen3ASRCLI.partSeparator, Qwen3ASRCLI.mediaMarker, "<|", "|>", "<asr_text>"] {
            text = text.replacingOccurrences(of: marker, with: " ")
        }
        return text
            .components(separatedBy: .newlines).joined(separator: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Tokens the reply may take: roomy for fast speech in any script.
    static func maxTokens(audioSeconds: TimeInterval) -> Int {
        min(3_072, 64 + Int((max(0, audioSeconds) * 8).rounded(.up)))
    }

    /// The transcript out of a raw reply, as `parse_asr_output` in the
    /// official package reads it: "language X<asr_text>text", or plain text
    /// when the header is missing. "language None" means no speech.
    static func transcript(fromReply raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let tag = trimmed.range(of: "<asr_text>") else {
            return collapsingRepetitions(trimmed)
        }
        let header = trimmed[..<tag.lowerBound].lowercased()
        let text = String(trimmed[tag.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if header.contains("language none"), text.isEmpty { return "" }
        return collapsingRepetitions(text)
    }

    /// The official package's repetition fix: a character or short pattern
    /// repeated past `threshold` times in a row is kept once. A model stuck
    /// in a loop then returns its real words instead of a wall of "ha ha".
    static func collapsingRepetitions(_ text: String, threshold: Int = 20, maxPatternLength: Int = 20) -> String {
        let characters = Array(text)
        guard characters.count > threshold else { return text }
        var output: [Character] = []
        var index = 0
        outer: while index < characters.count {
            for length in 1...maxPatternLength where index + length * threshold <= characters.count {
                let pattern = characters[index..<(index + length)]
                var repeats = 1
                var probe = index + length
                while probe + length <= characters.count, characters[probe..<(probe + length)] == pattern {
                    repeats += 1
                    probe += length
                }
                if repeats >= threshold {
                    output.append(contentsOf: pattern)
                    index = probe
                    continue outer
                }
            }
            output.append(characters[index])
            index += 1
        }
        return String(output)
    }
}

// MARK: - One-shot command line

enum Qwen3ASRCLI {
    /// The media marker llama-mtmd-cli replaces with the audio.
    static let mediaMarker = "<__media__>"
    /// Splits the stdin prompt into the system context, the user turn and
    /// the assistant prefill (see `chatTemplate`).
    static let partSeparator = "<|yappyapp_part|>"

    /// WORDS-AS-HINTS: the model card's chat, rebuilt from one stdin prompt
    /// "context SEP <__media__> SEP prefill". The template is fixed text in
    /// argv; the context (the user's words) only ever travels over stdin.
    /// Measured 2026-10-18 with the pinned 0.6B Q8_0: the same layout the
    /// warm server sends, and the language prefill works one-shot too.
    static let chatTemplate = """
    {%- set parts = messages[0]['content'].split('\(partSeparator)') -%}<|im_start|>system
    {{ parts[0] }}<|im_end|>
    <|im_start|>user
    {{ parts[1] }}<|im_end|>
    <|im_start|>assistant
    {{ parts[2] }}
    """

    /// What llama-mtmd-cli reads from stdin: context, audio, prefill.
    static func stdinPrompt(context: String, prefill: String?) -> String {
        [context, mediaMarker, prefill ?? ""].joined(separator: partSeparator)
    }

    /// No transcript, glossary or audio content is ever in argv: only the
    /// paths of the model files and of the recording (like whisper-cli),
    /// and the fixed chat template. The prompt comes from stdin.
    static func arguments(variant: Qwen3ASRVariant, modelURL: URL, projectorURL: URL, audioPath: String, maxTokens: Int) -> [String] {
        [
            "-m", modelURL.path,
            "--mmproj", projectorURL.path,
            "--audio", audioPath,
            "-f", "/dev/stdin",
            "--jinja",
            "--chat-template", chatTemplate,
            "--temp", "0",
            "-ngl", "99",
            "-c", String(Qwen3ASRPrompt.contextTokens),
            "-n", String(maxTokens),
            "--no-warmup"
        ]
    }
}
