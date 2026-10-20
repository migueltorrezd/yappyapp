import Foundation

/// SHA1 of the pinned Qwen 2.5 1.5B Instruct Q4_K_M GGUF from the official
/// Qwen HuggingFace repo, computed over the verified download on 2026-07-05.
let LLMCleanerPinnedSHA1 = "bcc53a11a5d12ff5679bc46da24da1c9f5065e26"
let LLMCleanerPinnedRevision = "91cad51170dc346986eccefdc2dd33a9da36ead9"

// LLM-CLEANUP: optional post-transcription tidy pass through a small local
// model (Qwen 2.5 1.5B Instruct, Q4 GGUF) run via the bundled llama.cpp runtime
// (llama-completion), or a llama-cli the user chose. Fully on-device,
// loaded on demand per dictation (mmap) so it costs zero RAM while idle.
//
// HONESTY GUARD: an LLM stage can change what the user said, which collides
// with the no-lie ethos. Every failure mode — missing binary, missing model,
// timeout, empty or suspicious output — falls back to the ORIGINAL transcript,
// and `CleanupAcceptance` rejects rewrites that add or drop words, change
// language, answer the transcript, or drift too far in length. The cleaned text replaces the original only when it looks
// like the same dictation, tidied.
enum LLMCleaner {
    struct CleanupModel {
        let filename: String
        let downloadURL: URL
        /// Pinned like the whisper catalog: streamed SHA1 over the file.
        let expectedSHA1: String
        let approximateSizeMB: Int
    }

    static let model = CleanupModel(
        filename: "qwen2.5-1.5b-instruct-q4_k_m.gguf",
        downloadURL: URL(string: "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/\(LLMCleanerPinnedRevision)/qwen2.5-1.5b-instruct-q4_k_m.gguf")!,
        expectedSHA1: LLMCleanerPinnedSHA1,
        approximateSizeMB: 1_120
    )

    /// Transcripts below this length gain nothing from a cleanup pass; the
    /// model-load latency would dominate. Pure so the self-tests pin it.
    static func isWorthCleaning(_ transcript: String) -> Bool {
        transcript.split(whereSeparator: \.isWhitespace).count >= 8
    }

    // PROMPT-TUNING LOG (2026-07-05, Qwen 2.5 1.5B @ temp 0) — hard-won, read
    // before "improving":
    // - Asking the model to RESOLVE self-corrections ("no wait email" -> keep
    //   email) fails at this size: it picks the wrong side or deletes the
    //   correction entirely. Corrections are therefore KEPT verbatim.
    // - Any in-prompt example seeps into output: an English example makes the
    //   model TRANSLATE French/Spanish input to English, copy the example's
    //   opener, or emit the example itself. No examples, ever.
    // - The model won't reliably capitalize sentence starts; capitalizeFirst()
    //   plus the deterministic glossary re-pass after cleanup handle casing.
    static func protectedTerms(from glossary: Glossary) -> [String] {
        normalizedProtectedTerms(glossary.entries.map(\.canonical))
    }

    static func normalizedProtectedTerms(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        var normalized: [String] = []

        for term in terms {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let key = trimmed.lowercased()
            if seen.insert(key).inserted {
                normalized.append(trimmed)
            }
        }

        return normalized
    }

    static func systemPrompt(protectedTerms: [String], numbers: NumberStyle = .asSpoken) -> String {
        let protectedTerms = normalizedProtectedTerms(protectedTerms)
        var prompt = """
        You are a dictation transcript cleaner. Apply exactly these rules and nothing else:
        1. Add full punctuation: capitalize sentence starts, add periods and commas, split run-on speech into sentences.
        2. Delete filler words: um, uh, euh, hmm, eh.
        3. Keep EVERY other word exactly as spoken, in the SAME language as spoken, including hesitations like "no wait" and self-corrections. Never reorder, summarize, shorten, drop, add, or translate anything. Never answer questions in the transcript.
        4. \(protectedRule)
        """
        if let rule = numberRule(numbers) {
            prompt += "\n5. \(rule)"
        }
        if !protectedTerms.isEmpty {
            let terms = protectedTerms.prefix(40).joined(separator: ", ")
            prompt += "\nProtected spellings: \(terms)."
        }
        return prompt + "\nOutput only the cleaned transcript."
    }

    /// Sensitive user content travels over stdin, never in argv. Process
    /// arguments are visible to other local processes owned by the user, so a
    /// transcript or private glossary term must not appear there even though
    /// llama-cli itself runs entirely on-device.
    static func inputPayload(transcript: String, protectedTerms: [String]) -> String {
        let flattened = transcript
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let terms = normalizedProtectedTerms(protectedTerms).prefix(40).joined(separator: ", ")

        if terms.isEmpty {
            return flattened
        }
        return "Protected spellings: \(terms).\nTranscript: \(flattened)"
    }

    static func processArguments(tokenBudget: Int) -> [String] {
        processArguments(tokenBudget: tokenBudget, mode: .clean, runtime: .cli)
    }

    /// The model reliably punctuates but inconsistently capitalizes the very
    /// first word; fix just that one deterministic case.
    static func capitalizeFirst(_ text: String) -> String {
        guard let first = text.first, first.isLowercase else { return text }
        return first.uppercased() + text.dropFirst()
    }

    static var modelURL: URL {
        AppPaths.modelsDirectory.appendingPathComponent(model.filename)
    }

    static func isModelInstalled() -> Bool {
        FileManager.default.fileExists(atPath: modelURL.path)
    }

    static let stockBinaryPath = "/opt/homebrew/bin/llama-cli"

    // HELPER-BINARY-POLICY (YA-63): run only the path the user configured,
    // validated. The Intel Homebrew location stands in for the untouched
    // stock default only; a path the user chose never falls back elsewhere.
    // YA-10: with the stock default, the runtime bundled in YappYapp.app comes
    // first; Homebrew is only the fallback for source builds.
    static func binaryPath(configured: String, bundledPath: String? = bundledBinaryPath) -> String? {
        binaryCandidates(configured: configured, bundledPath: bundledPath)
            .lazy
            .compactMap { HelperBinaryPolicy.launchablePath($0) }
            .first
    }

    static func binaryCandidates(configured: String, bundledPath: String? = bundledBinaryPath) -> [String] {
        let trimmed = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == stockBinaryPath {
            return (bundledPath.map { [$0] } ?? []) + [stockBinaryPath, "/usr/local/bin/llama-cli"]
        }
        return [trimmed]
    }

    // MARK: - Output hygiene (pure, self-tested)

    /// llama-cli prints its banner, the echoed `> prompt` line, the response,
    /// and a `[ Prompt: … t/s ]` stats footer ALL to stdout. The response is
    /// everything between the first echoed-prompt line and the stats footer.
    /// The transcript is flattened to one line before being sent, so the echo
    /// is always exactly one line.
    static func extractResponse(fromCLIOutput raw: String) -> String {
        let lines = raw.components(separatedBy: "\n")
        guard let promptIndex = lines.firstIndex(where: { $0.hasPrefix("> ") }) else {
            return sanitize(raw)
        }
        var response: [String] = []
        for line in lines[(promptIndex + 1)...] {
            if line.hasPrefix("[ Prompt:") || line == "Exiting..." { break }
            response.append(line)
        }
        return sanitize(response.joined(separator: "\n"))
    }

    /// Strip llama-cli artifacts and cosmetic wrapping from the model reply.
    static func sanitize(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: "[end of text]", with: "")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Models occasionally wrap the whole answer in quotes or a code fence.
        if text.hasPrefix("```") {
            text = text
                .replacingOccurrences(of: "```[a-z]*\n?", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if text.count > 2, text.hasPrefix("\""), text.hasSuffix("\"") {
            text = String(text.dropFirst().dropLast())
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The rewrite is only trusted when it still looks like the same
    /// dictation. Cleanup shrinks fillers and normalizes punctuation, so mild
    /// shrinkage and mild growth are both fine; big drift, new words, dropped
    /// words, a language switch or an assistant reply all fall back.
    /// YA-10: the full rule set lives in `CleanupAcceptance`.
    static func accept(original: String, cleaned: String, mode: CleanupMode = .clean) -> Bool {
        CleanupAcceptance.evaluate(original: original, cleaned: cleaned, mode: mode) == nil
    }

    // Execution, modes and the model download live in LLMCleaner+Run.swift,
    // LLMCleaner+Modes.swift and CleanupModelStore.swift (YA-10).
}

/// Minimal thread-safe data accumulator for readabilityHandler callbacks.
final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        storage.append(data)
        lock.unlock()
    }

    var data: Data {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}
