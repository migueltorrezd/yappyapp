import Foundation

// NUMBERS: the number words of each language, as atoms the parser in
// NumberForms combines. Keys are folded (lowercase, no accents), so "dieciséis",
// "één" and "zéro" match without their marks.

/// One piece of a spoken number.
enum NumberAtom: Equatable, Sendable {
    /// 0...9
    case digit(Int)
    /// 10...19
    case teen(Int)
    /// 20, 30, ... 90
    case tens(Int)
    /// 21...99 in one word: Spanish "veinticinco", Dutch "vijfentwintig".
    case tensUnit(Int)
    /// The x100 word: "hundred", "cent", "honderd". `plural` ("cents") needs
    /// a number in front.
    case hundred(plural: Bool)
    /// A finished hundreds value: Spanish "doscientos", "cien".
    case hundreds(Int)
    /// 1,000 / 1,000,000 / 1,000,000,000. `plural` ("millions") needs a
    /// number in front.
    case scale(Int, plural: Bool)
    /// "and", "et", "y", "en" between parts of one number.
    case joiner
    /// The decimal word and the separator it writes.
    case point(Character)
}

enum NumberLexicon {
    static func fold(_ word: String) -> String {
        word
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .lowercased()
    }

    static func table(_ language: NumberLanguage) -> [String: NumberAtom] {
        switch language {
        case .en: english
        case .fr: french
        case .es: spanish
        case .nl: dutch
        }
    }

    private static func digits(_ words: [String]) -> [String: NumberAtom] {
        var map: [String: NumberAtom] = [:]
        for (value, word) in words.enumerated() where !word.isEmpty {
            map[word] = .digit(value)
        }
        return map
    }

    private static func merged(_ parts: [String: NumberAtom]...) -> [String: NumberAtom] {
        parts.reduce(into: [:]) { result, part in result.merge(part) { first, _ in first } }
    }

    static let english: [String: NumberAtom] = merged(
        digits(["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]),
        [
            "ten": .teen(10), "eleven": .teen(11), "twelve": .teen(12), "thirteen": .teen(13),
            "fourteen": .teen(14), "fifteen": .teen(15), "sixteen": .teen(16), "seventeen": .teen(17),
            "eighteen": .teen(18), "nineteen": .teen(19),
            "twenty": .tens(20), "thirty": .tens(30), "forty": .tens(40), "fifty": .tens(50),
            "sixty": .tens(60), "seventy": .tens(70), "eighty": .tens(80), "ninety": .tens(90),
            "hundred": .hundred(plural: false),
            "thousand": .scale(1_000, plural: false),
            "million": .scale(1_000_000, plural: false),
            "billion": .scale(1_000_000_000, plural: false),
            "and": .joiner,
            "point": .point("."),
        ]
    )

    static let french: [String: NumberAtom] = merged(
        digits(["zero", "un", "deux", "trois", "quatre", "cinq", "six", "sept", "huit", "neuf"]),
        [
            "une": .digit(1),
            "dix": .teen(10), "onze": .teen(11), "douze": .teen(12), "treize": .teen(13),
            "quatorze": .teen(14), "quinze": .teen(15), "seize": .teen(16),
            "vingt": .tens(20), "vingts": .tens(20), "trente": .tens(30), "quarante": .tens(40),
            "cinquante": .tens(50), "soixante": .tens(60),
            // Belgian and Swiss tens.
            "septante": .tens(70), "huitante": .tens(80), "octante": .tens(80), "nonante": .tens(90),
            "cent": .hundred(plural: false), "cents": .hundred(plural: true),
            "mille": .scale(1_000, plural: false),
            "million": .scale(1_000_000, plural: false), "millions": .scale(1_000_000, plural: true),
            "milliard": .scale(1_000_000_000, plural: false), "milliards": .scale(1_000_000_000, plural: true),
            "et": .joiner,
            "virgule": .point(","),
        ]
    )

    static let spanish: [String: NumberAtom] = merged(
        digits(["cero", "uno", "dos", "tres", "cuatro", "cinco", "seis", "siete", "ocho", "nueve"]),
        [
            "un": .digit(1), "una": .digit(1),
            "diez": .teen(10), "once": .teen(11), "doce": .teen(12), "trece": .teen(13),
            "catorce": .teen(14), "quince": .teen(15), "dieciseis": .teen(16), "diecisiete": .teen(17),
            "dieciocho": .teen(18), "diecinueve": .teen(19),
            "veinte": .tens(20),
            "veintiuno": .tensUnit(21), "veintiun": .tensUnit(21), "veintiuna": .tensUnit(21),
            "veintidos": .tensUnit(22), "veintitres": .tensUnit(23), "veinticuatro": .tensUnit(24),
            "veinticinco": .tensUnit(25), "veintiseis": .tensUnit(26), "veintisiete": .tensUnit(27),
            "veintiocho": .tensUnit(28), "veintinueve": .tensUnit(29),
            "treinta": .tens(30), "cuarenta": .tens(40), "cincuenta": .tens(50), "sesenta": .tens(60),
            "setenta": .tens(70), "ochenta": .tens(80), "noventa": .tens(90),
            "cien": .hundreds(100), "ciento": .hundreds(100),
            "doscientos": .hundreds(200), "doscientas": .hundreds(200),
            "trescientos": .hundreds(300), "trescientas": .hundreds(300),
            "cuatrocientos": .hundreds(400), "cuatrocientas": .hundreds(400),
            "quinientos": .hundreds(500), "quinientas": .hundreds(500),
            "seiscientos": .hundreds(600), "seiscientas": .hundreds(600),
            "setecientos": .hundreds(700), "setecientas": .hundreds(700),
            "ochocientos": .hundreds(800), "ochocientas": .hundreds(800),
            "novecientos": .hundreds(900), "novecientas": .hundreds(900),
            "mil": .scale(1_000, plural: false),
            "millon": .scale(1_000_000, plural: false), "millones": .scale(1_000_000, plural: true),
            "y": .joiner,
            "coma": .point(","), "punto": .point("."),
        ]
    )

    static let dutch: [String: NumberAtom] = merged(
        digits(["nul", "een", "twee", "drie", "vier", "vijf", "zes", "zeven", "acht", "negen"]),
        [
            "tien": .teen(10), "elf": .teen(11), "twaalf": .teen(12), "dertien": .teen(13),
            "veertien": .teen(14), "vijftien": .teen(15), "zestien": .teen(16), "zeventien": .teen(17),
            "achttien": .teen(18), "negentien": .teen(19),
            "twintig": .tens(20), "dertig": .tens(30), "veertig": .tens(40), "vijftig": .tens(50),
            "zestig": .tens(60), "zeventig": .tens(70), "tachtig": .tens(80), "negentig": .tens(90),
            "honderd": .hundred(plural: false),
            "duizend": .scale(1_000, plural: false),
            "miljoen": .scale(1_000_000, plural: false),
            "miljard": .scale(1_000_000_000, plural: false),
            "en": .joiner,
            "komma": .point(","), "punt": .point("."),
        ]
    )

    /// Dutch writes numbers below a million as one word: "vijfentwintig",
    /// "tweeduizendvijfhonderd". These are the pieces such a word splits into.
    static let dutchMorphemes: [String] = dutch
        .filter { key, atom in
            if case .point = atom { return false }
            return key != "nul"
        }
        .map(\.key)
        .sorted { $0.count > $1.count }

    /// Splits a Dutch compound into its pieces, or nil when it is not made
    /// only of number words ("vierkant", "tienen").
    static func dutchPieces(_ word: String) -> [String]? {
        guard !word.isEmpty else { return [] }
        for piece in dutchMorphemes where word.hasPrefix(piece) {
            if let rest = dutchPieces(String(word.dropFirst(piece.count))) {
                return [piece] + rest
            }
        }
        return nil
    }

    // MARK: - Words around a number

    /// Words after a number that make even a lone small number a quantity.
    /// Plural forms only: a lone "one" never converts anyway.
    static func units(_ language: NumberLanguage) -> Set<String> {
        switch language {
        case .en:
            [
                "dollars", "euros", "pounds", "cents", "pesos", "yen",
                "seconds", "minutes", "hours", "days", "weeks", "months", "years",
                "kilometers", "kilometres", "km", "miles", "meters", "metres", "centimeters", "centimetres",
                "cm", "mm", "feet", "inches", "kilos", "kilograms", "kg", "grams", "lbs", "ounces",
                "liters", "litres", "degrees", "gigabytes", "gb", "megabytes", "mb", "terabytes", "tb",
            ]
        case .fr:
            [
                "dollars", "euros", "centimes", "pesos",
                "secondes", "minutes", "heures", "jours", "semaines", "mois", "ans", "annees",
                "kilometres", "km", "metres", "centimetres", "cm", "mm", "kilos", "kilogrammes", "kg",
                "grammes", "litres", "degres", "go", "mo", "to",
            ]
        case .es:
            [
                "dolares", "euros", "pesos", "centavos",
                "segundos", "minutos", "horas", "dias", "semanas", "meses", "anos",
                "kilometros", "km", "metros", "centimetros", "cm", "mm", "kilos", "kilogramos", "kg",
                "gramos", "litros", "grados", "gb", "mb",
            ]
        case .nl:
            [
                "euro", "dollar", "cent",
                "seconden", "minuten", "uur", "dagen", "weken", "maanden", "jaar",
                "kilometer", "km", "meter", "centimeter", "cm", "mm", "kilo", "kg", "gram", "liter",
                "graden", "gb", "mb",
            ]
        }
    }

    /// The percent phrase, folded, one word per entry.
    static func percentPhrases(_ language: NumberLanguage) -> [[String]] {
        switch language {
        case .en: [["percent"], ["per", "cent"]]
        case .fr: [["pour", "cent"], ["pourcent"]]
        case .es: [["por", "ciento"], ["porciento"]]
        case .nl: [["procent"]]
        }
    }

    /// The percent word WORDS mode writes.
    static func percentWord(_ language: NumberLanguage) -> String {
        switch language {
        case .en: "percent"
        case .fr: "pour cent"
        case .es: "por ciento"
        case .nl: "procent"
        }
    }

    /// The written percent sign: French puts a narrow no-break space first.
    static func percentSign(_ language: NumberLanguage) -> String {
        language == .fr ? "\u{202F}%" : "%"
    }

    /// The decimal word WORDS mode writes for a separator.
    static func decimalWord(_ language: NumberLanguage, separator: Character) -> String {
        switch language {
        case .en: "point"
        case .fr: "virgule"
        case .es: separator == "." ? "punto" : "coma"
        case .nl: "komma"
        }
    }

    static func locale(_ language: NumberLanguage) -> Locale {
        switch language {
        case .en: Locale(identifier: "en_US")
        case .fr: Locale(identifier: "fr_FR")
        case .es: Locale(identifier: "es_419")
        case .nl: Locale(identifier: "nl_NL")
        }
    }

    /// Thousands separator DIGITS mode writes (numbers of 10,000 and up).
    static func groupingSeparator(_ language: NumberLanguage) -> String {
        switch language {
        case .en, .es: ","
        case .fr: "\u{202F}"
        case .nl: "."
        }
    }

    /// Separators WORDS mode reads: a group is exactly three digits after one.
    static func readGroupingSeparators(_ language: NumberLanguage) -> Set<Character> {
        switch language {
        case .en: [","]
        case .fr: [".", "\u{00A0}", "\u{202F}"]
        case .es: [",", "."]
        case .nl: ["."]
        }
    }

    /// Separators WORDS mode reads as a decimal point (one or two digits after).
    static func readDecimalSeparators(_ language: NumberLanguage) -> Set<Character> {
        switch language {
        case .en: ["."]
        case .fr, .nl: [","]
        case .es: [",", "."]
        }
    }

    /// Words before a number that make it an identifier ("version 2").
    static let identifierWords: Set<String> = [
        "version", "versions", "versie", "build", "release", "v", "port", "rev",
    ]
}
