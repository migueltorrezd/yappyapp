import Foundation

// LLM-CLEANUP (missing feature 4): per-mode system prompts and the runtime
// command line. Mode prompts follow the PROMPT-TUNING LOG in LLMCleaner.swift:
// numbered rules, no examples ever, the SAME language pinned, nothing added,
// never answer the transcript. Self-corrections are resolved before the model
// runs (SelfCorrection), so every prompt still tells the model to keep them.
extension LLMCleaner {
    /// Which llama.cpp front end runs the model. They take the same flags but
    /// print differently, and only llama-cli survives `--log-disable`.
    enum Runtime: Equatable, Sendable {
        /// Bundled `llama-completion`: prints just the reply on stdout.
        case completion
        /// A `llama-cli` the user chose: banner, `> prompt` echo, reply, stats.
        case cli

        static func of(binaryPath: String) -> Runtime {
            URL(fileURLWithPath: binaryPath).lastPathComponent.hasPrefix("llama-completion") ? .completion : .cli
        }
    }

    /// Bundled runtime inside YappYapp.app, when this process is the app.
    static var bundledBinaryPath: String? {
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app" else { return nil }
        return bundleURL
            .appendingPathComponent("Contents/Resources/bin", isDirectory: true)
            .appendingPathComponent("llama-completion")
            .path
    }

    /// Model context in tokens. A five-minute dictation, the rules and the
    /// rewrite fit with room to spare; the model's 32k default would reserve
    /// close to 1 GB of KV cache for nothing.
    static let contextTokens = 4_096

    static func systemPrompt(mode: CleanupMode, protectedTerms: [String], numbers: NumberStyle = .asSpoken) -> String {
        guard let rules = modeRules(mode) else {
            return systemPrompt(protectedTerms: protectedTerms, numbers: numbers)
        }
        let protectedTerms = normalizedProtectedTerms(protectedTerms)
        var prompt = rules.body
        if let rule = numberRule(numbers) {
            prompt += "\n5. \(rule)"
        }
        if !protectedTerms.isEmpty {
            let terms = protectedTerms.prefix(40).joined(separator: ", ")
            prompt += "\nProtected spellings: \(terms)."
        }
        return prompt + "\n" + rules.closing
    }

    /// WORDS-NEAR-MISS (2026-10-18): the user's words are not only kept but
    /// used. A near-miss of one of them, where the sentence uses it as that
    /// name or term, is written their way. No examples (PROMPT-TUNING LOG).
    static let protectedRule = """
    If the user supplies a "Protected spellings" line, preserve every listed name, product term, acronym, or glossary word exactly. Never lowercase, translate, split, or respell it. These are the user's own words: when a word or short phrase in the transcript sounds like one of them or is a near-miss spelling of it, and the sentence uses it as that name or term, write the protected spelling instead. Leave ordinary words that only look or sound similar unchanged.
    """

    /// NUMBERS: one rule for the chosen style, so the model's reading of the
    /// sentence settles the cases the deterministic pass leaves alone. AS
    /// SPOKEN adds nothing, so its prompt is the one that shipped. No example
    /// numbers (PROMPT-TUNING LOG: examples seep into the output).
    static func numberRule(_ style: NumberStyle) -> String? {
        switch style {
        case .asSpoken:
            nil
        case .digits:
            "Write numbers as digits when they count or measure something: amounts, quantities, percentages, prices, dates, years. Keep a word like \"one\" as a word when it does not count anything."
        case .words:
            "Write numbers as words in the SAME language, except years, times, versions, codes, phone numbers and numbers that are part of a name, which stay as digits."
        }
    }

    private static func modeRules(_ mode: CleanupMode) -> (body: String, closing: String)? {
        switch mode {
        case .verbatim, .clean:
            return nil
        case .email:
            return ("""
            You are a dictation transcript formatter for email. Apply exactly these rules and nothing else:
            1. Lay the transcript out as an email body: short paragraphs, a greeting line only if one was spoken, a sign-off only if one was spoken. Never add a subject line.
            2. Add full punctuation: capitalize sentence starts, add periods and commas. Delete filler words: um, uh, euh, hmm, eh.
            3. Keep EVERY other word exactly as spoken, in the SAME language as spoken, including self-corrections. Never reorder, summarize, shorten, drop, add, or translate anything. Never answer questions in the transcript.
            4. \(protectedRule)
            """, "Output only the email body.")
        case .list:
            return ("""
            You are a dictation transcript formatter for lists. Apply exactly these rules and nothing else:
            1. Split the transcript into list items, one item per line, each line starting with "- ".
            2. Add punctuation inside items. Delete filler words: um, uh, euh, hmm, eh.
            3. Keep EVERY other word exactly as spoken, in the SAME language as spoken, including self-corrections. Never add items, headings, or numbering. Never summarize, drop, or translate anything. Never answer questions in the transcript.
            4. \(protectedRule)
            """, "Output only the list.")
        case .notes:
            return ("""
            You are a dictation transcript formatter for notes. Apply exactly these rules and nothing else:
            1. Turn the transcript into short note lines, one idea per line, each line starting with "- ".
            2. Delete filler words and hesitations: um, uh, euh, hmm, eh. Keep every fact, name, number, and date.
            3. Write in the SAME language as spoken, using the speaker's own words. Never add facts, headings, or commentary. Never translate anything. Never answer questions in the transcript.
            4. \(protectedRule)
            """, "Output only the notes.")
        }
    }

    /// The command line for one cleanup run. Sensitive content (transcript,
    /// glossary terms) never appears here; it travels over stdin.
    static func processArguments(tokenBudget: Int, mode: CleanupMode, runtime: Runtime, modelPath: String = modelURL.path, numbers: NumberStyle = .asSpoken) -> [String] {
        var arguments = [
            "-m", modelPath,
            // The system rules contain no user data. Glossary terms and the
            // transcript are supplied through /dev/stdin below.
            "-sys", systemPrompt(mode: mode, protectedTerms: [], numbers: numbers),
            "-f", "/dev/stdin",
            "--single-turn",
            "--no-display-prompt",
            "--no-warmup",
            "--simple-io",
        ]
        // llama-completion prints the reply through the same logger that
        // --log-disable pauses, so it would print nothing. Its diagnostics go
        // to stderr, which the runner discards, and it writes no log file.
        if runtime == .cli {
            arguments.append("--log-disable")
        }
        arguments += [
            "--temp", "0",
            "-ngl", "99",
            "-c", String(contextTokens),
            "-n", String(tokenBudget),
        ]
        return arguments
    }

    /// The reply, cut out of whatever the runtime printed.
    static func extractResponse(fromOutput raw: String, runtime: Runtime) -> String {
        switch runtime {
        case .cli: extractResponse(fromCLIOutput: raw)
        case .completion: sanitize(raw)
        }
    }

    /// List and notes modes: one "- " bullet style, whatever the model chose.
    static func normalizeBullets(_ text: String) -> String {
        text
            .components(separatedBy: "\n")
            .map { line -> String in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                for bullet in ["* ", "\u{2022} ", "\u{2013} ", "\u{2014} "] where trimmed.hasPrefix(bullet) {
                    return "- " + trimmed.dropFirst(bullet.count)
                }
                return trimmed.isEmpty ? "" : trimmed
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// Tidy the model reply for the chosen mode.
    static func finish(_ reply: String, mode: CleanupMode) -> String {
        switch mode {
        case .list, .notes:
            normalizeBullets(reply)
        case .verbatim, .clean, .email:
            capitalizeFirst(reply)
        }
    }

    /// Output budget scales with the input: a cleanup is never longer than
    /// the same order as what was said, never a long-form answer.
    static func tokenBudget(for transcript: String) -> Int {
        max(128, min(2_048, transcript.count / 2))
    }

    /// Hard ceiling for one cleanup, model load included. Past it the raw
    /// transcript goes out, so a slow model never holds a dictation hostage.
    static func hardTimeout(for transcript: String) -> TimeInterval {
        let words = transcript.split(whereSeparator: \.isWhitespace).count
        return min(20, 8 + Double(words) / 25)
    }
}
