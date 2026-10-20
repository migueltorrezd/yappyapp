#if DEBUG
import Foundation

// WORDS-NEAR-MISS: developer harness behind
// --words-cleanup-eval <llama-completion> <model.gguf> <cases.json>
// Runs synthetic fixtures (never user data) through three pipelines with the
// real cleanup model on the warm llama-server:
//   before   the 0.3 prompt, the old guard, sounds-like swaps only
//   pre-pass the deterministic near-miss pass alone (cleanup off)
//   after    near-miss pass, the new prompt, the new guard, the pass again
// and prints each output, whether it is right, and the model time.
// cases.json: {"words": ["Genial", ...], "cases": [{"text": "...",
// "expect": ["Genial"], "forbid": ["Genial"]}]}
enum WordsCleanupEval {
    struct Case: Decodable {
        let text: String
        let expect: [String]?
        let forbid: [String]?
    }

    struct Fixtures: Decodable {
        let words: [String]
        let cases: [Case]
    }

    /// The protected-spellings rule as it shipped before WORDS-NEAR-MISS.
    static let legacyRule = """
    If the user supplies a "Protected spellings" line, preserve every listed name, product term, acronym, or glossary word exactly. Never lowercase, translate, split, or respell it.
    """

    static func run(completionBinary: String, modelPath: String, casesPath: String) -> Never {
        guard let data = FileManager.default.contents(atPath: casesPath),
              let fixtures = try? JSONDecoder().decode(Fixtures.self, from: data) else {
            print("eval.error=cases unreadable")
            exit(2)
        }
        let entries = fixtures.words.map { GlossaryEntry(canonical: $0, variants: [], notes: nil) }
        let glossary = Glossary(entries: entries, lexicon: SpellCheckerLexicon.shared)
        let terms = LLMCleaner.protectedTerms(from: glossary)

        let server = LlamaServerController.cleanup
        server.synchronize(LlamaServerLaunch(
            binary: CleanupServerPolicy.serverBinaryPath(forRuntimeBinary: completionBinary),
            model: modelPath,
            contextTokens: LLMCleaner.contextTokens
        ))
        guard server.waitUntilReady() else {
            print("eval.error=server not ready")
            exit(2)
        }

        var scores = [0, 0, 0]
        var modelTimes: [[Int]] = [[], []]
        for (index, fixture) in fixtures.cases.enumerated() {
            let before = clean(glossary.applyingVariants(to: fixture.text), terms: terms, legacy: true, server: server)
            let beforeText = glossary.applyingVariants(to: before.text)
            let prePass = glossary.applyingCorrections(to: fixture.text)
            let after = clean(prePass, terms: terms, legacy: false, server: server)
            let afterText = glossary.applyingCorrections(to: after.text)
            let verdicts = [beforeText, prePass, afterText].map { isRight($0, fixture) }
            for (slot, right) in verdicts.enumerated() where right { scores[slot] += 1 }
            modelTimes[0].append(before.milliseconds)
            modelTimes[1].append(after.milliseconds)
            print("case \(index + 1): \(fixture.text)")
            print("  before   [\(mark(verdicts[0]))] \(before.milliseconds)ms \(before.note): \(beforeText)")
            print("  pre-pass [\(mark(verdicts[1]))]: \(prePass)")
            print("  after    [\(mark(verdicts[2]))] \(after.milliseconds)ms \(after.note): \(afterText)")
        }
        let total = fixtures.cases.count
        // The deterministic pass's own cost, dictionary lookups included
        // (cold first, then cached).
        let passStart = Date()
        for fixture in fixtures.cases { _ = glossary.applyingCorrections(to: fixture.text) }
        print("eval.prePassMs.all\(total)CasesWarmCache=\(CleanupLatencyBench.milliseconds(since: passStart))")
        let cold = Glossary(entries: entries, lexicon: SpellCheckerLexicon(languages: SpellCheckerLexicon.defaultLanguages()))
        let coldStart = Date()
        for fixture in fixtures.cases { _ = cold.applyingCorrections(to: fixture.text) }
        print("eval.prePassMs.all\(total)CasesColdCache=\(CleanupLatencyBench.milliseconds(since: coldStart))")
        func median(_ values: [Int]) -> Int { values.sorted()[values.count / 2] }
        print("eval.score.before=\(scores[0])/\(total)")
        print("eval.score.prePassOnly=\(scores[1])/\(total)")
        print("eval.score.after=\(scores[2])/\(total)")
        print("eval.modelMs.before.median=\(median(modelTimes[0])) mean=\(modelTimes[0].reduce(0, +) / total)")
        print("eval.modelMs.after.median=\(median(modelTimes[1])) mean=\(modelTimes[1].reduce(0, +) / total)")
        server.stop()
        exit(0)
    }

    private static func mark(_ right: Bool) -> String { right ? "ok" : "MISS" }

    static func isRight(_ output: String, _ fixture: Case) -> Bool {
        let tokens = Set(GlossaryNearMiss.tokens(in: output).map(\.text))
        let expected = (fixture.expect ?? []).allSatisfy { term in
            term.contains(" ") ? output.contains(term) : tokens.contains(term)
        }
        let forbidden = (fixture.forbid ?? []).contains { term in
            term.contains(" ") ? output.contains(term) : tokens.contains(term)
        }
        return expected && !forbidden
    }

    /// One cleanup through the warm server with the production payload,
    /// timed around the model call. Falls back to the input like the app.
    private static func clean(
        _ text: String,
        terms: [String],
        legacy: Bool,
        server: LlamaServerController
    ) -> (text: String, milliseconds: Int, note: String) {
        let corrected = SelfCorrection.resolve(text)
        var system = LLMCleaner.systemPrompt(mode: .clean, protectedTerms: [])
        if legacy {
            system = system.replacingOccurrences(of: LLMCleaner.protectedRule, with: legacyRule)
        }
        let request = CleanupServerRequest(
            system: system,
            user: LLMCleaner.inputPayload(transcript: corrected, protectedTerms: terms),
            maxTokens: LLMCleaner.tokenBudget(for: corrected),
            timeout: LLMCleaner.hardTimeout(for: corrected)
        )
        let startedAt = Date()
        let reply = server.complete(request.chat)
        let elapsed = CleanupLatencyBench.milliseconds(since: startedAt)
        guard case .text(let output) = reply else { return (text, elapsed, "no reply") }
        let cleaned = LLMCleaner.finish(LLMCleaner.extractResponse(fromOutput: output, runtime: .completion), mode: .clean)
        let rejection = CleanupAcceptance.evaluate(
            original: corrected,
            cleaned: cleaned,
            mode: .clean,
            protectedTerms: legacy ? [] : terms
        )
        if let rejection { return (text, elapsed, "rejected(\(rejection.rawValue)) model said \"\(cleaned)\"") }
        if legacy { return (cleaned, elapsed, "cleaned") }
        return (GlossaryNearMiss.restoringCase(of: terms, from: corrected, in: cleaned), elapsed, "cleaned")
    }
}

// WORDS-AS-HINTS: developer harness behind
// --qwen3asr-hint-check <llama-completion> <0.6b|1.7b> <language> <words.json> <wav>...
// Each synthetic WAV goes through the production Qwen3ASRTranscriber one-shot
// and warm, without and with the words as context. Prints which of the
// words each run spelled right, never other text.
enum Qwen3ASRHintCheck {
    static func run(completionBinary: String, variantName: String, language: String, wordsPath: String, wavs: [String]) -> Never {
        guard let variant = Qwen3ASRVariant(rawValue: variantName),
              let data = FileManager.default.contents(atPath: wordsPath),
              let words = try? JSONDecoder().decode([String].self, from: data) else {
            print("hint.error=bad arguments")
            exit(2)
        }
        guard Qwen3ASRModelStore.isVerified(variant) || Qwen3ASRModelStore.verifyExisting(variant) else {
            print("hint.error=model files missing or not the pinned ones")
            exit(2)
        }
        var config = AppConfig.defaultConfig
        config.modelPath = variant.modelPath
        config.language = language
        // Variants off and an empty lexicon-free pass: only the model spells.
        let none = Glossary(entries: [], lexicon: StaticWordLexicon([]))
        let hinted = Glossary(entries: words.map { GlossaryEntry(canonical: $0, variants: [], notes: nil) }, lexicon: AllWords())

        var oneShot = Qwen3ASRTranscriber()
        oneShot.server = { _, _, _ in .unavailable }
        oneShot.cliBinary = { _ in Qwen3ASRRuntime.cliBinaryPath(forRuntimeBinary: completionBinary) }
        var totals = [0, 0, 0, 0]
        var possible = 0
        func check(_ label: String, _ slot: Int, _ transcriber: Qwen3ASRTranscriber, _ glossary: Glossary, _ wav: String) {
            let url = URL(fileURLWithPath: wav)
            let seconds = TranscriptionTimeouts.audioDuration(of: url) ?? 0
            let startedAt = Date()
            let text = (try? transcriber.transcribeBlocking(audioURL: url, variant: variant, config: config, glossary: glossary, audioSeconds: seconds)) ?? ""
            let found = words.filter { text.contains($0) }
            totals[slot] += found.count
            print("hint.\(label).\(url.deletingPathExtension().lastPathComponent)=\(CleanupLatencyBench.milliseconds(since: startedAt))ms found=\(found.joined(separator: "|"))")
        }
        for wav in wavs {
            check("oneShot.noWords", 0, oneShot, none, wav)
            check("oneShot.words", 1, oneShot, hinted, wav)
        }

        let server = LlamaServerController.speech
        server.synchronize(LlamaServerLaunch(
            binary: LlamaServerPolicy.serverBinaryPath(forRuntimeBinary: completionBinary),
            model: Qwen3ASRModelStore.modelURL(variant).path,
            contextTokens: Qwen3ASRPrompt.contextTokens,
            projector: Qwen3ASRModelStore.projectorURL(variant).path
        ))
        server.waitUntilReady()
        var warm = Qwen3ASRTranscriber()
        warm.cliBinary = { _ in nil }
        for wav in wavs {
            check("server.noWords", 2, warm, none, wav)
            check("server.words", 3, warm, hinted, wav)
        }
        server.stop()
        possible = wavs.count
        print("hint.totals oneShot.noWords=\(totals[0]) oneShot.words=\(totals[1]) server.noWords=\(totals[2]) server.words=\(totals[3]) wavs=\(possible)")
        exit(0)
    }

    /// Every word counts as a dictionary word, so the near-miss pass never
    /// fixes anything and only the model's own spelling is measured.
    private struct AllWords: WordLexicon {
        func isWord(_ word: String) -> Bool { true }
    }
}
#endif
