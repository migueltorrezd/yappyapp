import Foundation
import NaturalLanguage

// NUMBERS (0.4.0): how numbers are written. AS SPOKEN leaves whatever the
// speech model wrote, DIGITS writes "25 people", WORDS writes "twenty-five
// people". A deterministic pass (NumberForms) does the work, so it runs with
// cleanup off. With cleanup on, the prompt gets one line for the style and the
// guard accepts digits <-> words of the same value; the pass runs after
// cleanup as well, so the result is the same either way.

enum NumberStyle: String, CaseIterable, Codable, Identifiable, Sendable {
    case asSpoken = "spoken"
    case digits
    case words

    var id: String { rawValue }

    var label: String {
        switch self {
        case .asSpoken: L10n.tr("AS SPOKEN")
        case .digits: L10n.tr("DIGITS")
        case .words: L10n.tr("WORDS")
        }
    }

    /// One line under the picker. DIGITS states the lone-number rule.
    var summary: String {
        switch self {
        case .asSpoken:
            L10n.tr("Numbers stay the way the speech model wrote them.")
        case .digits:
            L10n.tr("Digits for 10 and up, decimals, years, and numbers before a unit or percent. A lone small number like \"one\" stays a word.")
        case .words:
            L10n.tr("Words for numbers up to 999,999. Years, times, versions, codes and phone numbers stay digits.")
        }
    }

    /// A tiny before and after: what you say, what gets pasted.
    var example: (said: String, written: String) {
        switch self {
        case .asSpoken:
            (L10n.tr("twenty five people, one of them late"), L10n.tr("twenty five people, one of them late"))
        case .digits:
            (L10n.tr("twenty five people, one of them late"), L10n.tr("25 people, one of them late"))
        case .words:
            (L10n.tr("25 people at 3:30"), L10n.tr("Twenty-five people at 3:30"))
        }
    }

    /// Stored raw value, with anything unknown read as AS SPOKEN.
    static func resolve(_ stored: String?) -> NumberStyle {
        stored.flatMap(NumberStyle.init(rawValue:)) ?? .asSpoken
    }
}

extension AppConfig {
    /// The effective number style.
    var numbers: NumberStyle {
        get { NumberStyle.resolve(numberStyle) }
        set { numberStyle = newValue.rawValue }
    }
}

/// Languages the number pass knows. Anything else is left untouched.
enum NumberLanguage: String, CaseIterable, Sendable {
    case en, fr, es, nl

    var nlLanguage: NLLanguage {
        switch self {
        case .en: .english
        case .fr: .french
        case .es: .spanish
        case .nl: .dutch
        }
    }

    /// The dictation language when it is one of ours; on AUTO (or an empty
    /// setting) the transcript's language, detected offline, and only when
    /// the detector is sure. nil means skip the pass.
    static func resolve(dictationLanguage: String, transcript: String) -> NumberLanguage? {
        let code = dictationLanguage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let known = NumberLanguage(rawValue: code) { return known }
        guard code.isEmpty || code == "auto" else { return nil }
        return detect(transcript)
    }

    static let detectionConfidence = 0.6

    static func detect(_ text: String) -> NumberLanguage? {
        guard text.split(whereSeparator: \.isWhitespace).count >= 2 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
              confidence >= detectionConfidence else { return nil }
        return allCases.first { $0.nlLanguage == language }
    }
}

/// What one dictation does with numbers: the style and the language the pass
/// reads. A nil language skips the pass (and the guard's number check).
struct NumberPlan: Equatable, Sendable {
    var style: NumberStyle
    var language: NumberLanguage?

    static let asSpoken = NumberPlan(style: .asSpoken, language: nil)

    /// Whether the deterministic pass and the cleanup line apply.
    var isActive: Bool { style != .asSpoken && language != nil }

    /// The style the cleanup prompt asks for: none when the pass is off.
    var promptStyle: NumberStyle { isActive ? style : .asSpoken }

    static func resolve(style: NumberStyle, dictationLanguage: String, transcript: String) -> NumberPlan {
        guard style != .asSpoken else { return .asSpoken }
        return NumberPlan(style: style, language: NumberLanguage.resolve(dictationLanguage: dictationLanguage, transcript: transcript))
    }
}
