import Foundation

/// YA-48: Whisper invents text when it hears (almost) nothing: "Thank you.",
/// "Thanks for watching!", subtitle credits, or it reads its own prompt back.
/// This guard drops those outputs, and only in the narrow cases where they
/// cannot be a real dictation:
/// - a known hallucination phrase, and the recording was near silence;
/// - the output is exactly the prompt (or one part of it);
/// - the output is only a non-speech tag such as "[BLANK_AUDIO]".
/// A real "Thank you." spoken at normal volume always goes through.
enum WhisperOutputGuard {
    /// Reference peak (99.7th percentile, before normalization) under which a
    /// recording counts as near silence. About -48 dBFS: well below a quiet
    /// or whispered voice, above the dead-silence floor checked earlier.
    static let nearSilencePeak: Float = 0.004

    /// Normalized (lowercased, letters and digits only, single spaces).
    static let hallucinationPhrases: Set<String> = [
        // English
        "you", "thank you", "thanks", "thank you very much", "thank you so much",
        "thanks for watching", "thank you for watching", "thanks for listening",
        "thank you for listening", "please subscribe", "like and subscribe",
        "subscribe to my channel", "bye", "bye bye", "goodbye", "see you next time",
        "subtitles by the amara org community", "transcribed by https otter ai",
        // French
        "merci", "merci beaucoup", "merci d avoir regardé", "merci de votre attention",
        "au revoir", "sous titres réalisés par la communauté d amara org",
        "sous titrage st 501", "sous titrage société radio canada",
        // Spanish
        "gracias", "muchas gracias", "gracias por ver", "gracias por ver el video",
        "subtítulos realizados por la comunidad de amara org", "suscríbete",
        // German and Dutch
        "danke", "vielen dank", "danke fürs zuschauen", "tschüss",
        "untertitel der amara org community", "untertitel im auftrag des zdf",
        "bedankt", "bedankt voor het kijken", "ondertiteling door de amara org gemeenschap"
    ]

    enum Verdict: Equatable {
        case keep
        case dropHallucination
        case dropPromptEcho
        case dropNonSpeech
    }

    /// The pieces of the prompt Whisper tends to read back on its own: the
    /// glossary sentence, the bare word list, and the extra prompt.
    static func promptParts(config: AppConfig, glossary: Glossary) -> [String] {
        [
            glossary.promptPrefix(),
            glossary.canonicalTerms.prefix(40).joined(separator: ", "),
            config.additionalPrompt
        ]
    }

    static func isNearSilence(_ profile: AudioSignalProfile?) -> Bool {
        guard let profile else { return false }
        return profile.referencePeak < nearSilencePeak
    }

    static func verdict(output: String, prompt: String, promptParts: [String] = [], nearSilence: Bool) -> Verdict {
        let normalizedOutput = normalize(output)
        guard !normalizedOutput.isEmpty else {
            // Only tags or punctuation, for example "[BLANK_AUDIO]" or "(music)".
            return output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .keep : .dropNonSpeech
        }

        let promptCandidates = ([prompt] + promptParts)
            .map(normalize)
            .filter { !$0.isEmpty }
        if promptCandidates.contains(normalizedOutput) {
            return .dropPromptEcho
        }

        if nearSilence, isHallucinationPhrase(output) {
            return .dropHallucination
        }

        return .keep
    }

    /// True when every sentence of the output is a known phrase, so a looped
    /// "Thank you. Thank you." is caught as well.
    static func isHallucinationPhrase(_ output: String) -> Bool {
        // Split on sentence marks followed by a space or the end, so a dot
        // inside "Amara.org" does not cut the phrase in two.
        let sentences = output
            .replacingOccurrences(of: #"[.!?…]+(?=\s|$)"#, with: "\n", options: .regularExpression)
            .components(separatedBy: .newlines)
            .map(normalize)
            .filter { !$0.isEmpty }
        guard !sentences.isEmpty else { return false }
        return sentences.allSatisfy { hallucinationPhrases.contains($0) }
    }

    /// Lowercases, drops bracketed tags, and keeps only letters and digits
    /// separated by single spaces.
    static func normalize(_ text: String) -> String {
        let withoutTags = text.replacingOccurrences(
            of: #"\[[^\]]*\]|\([^)]*\)|\*[^*]*\*"#,
            with: " ",
            options: .regularExpression
        )
        var words: [String] = []
        var current = ""
        for character in withoutTags.lowercased() {
            if character.isLetter || character.isNumber {
                current.append(character)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        return words.joined(separator: " ")
    }
}
