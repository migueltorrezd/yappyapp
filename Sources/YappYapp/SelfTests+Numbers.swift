#if DEBUG
import Foundation

// Self-tests owned by the "numbers" work track. Keep this track's new
// assertions here so parallel tracks never edit the same test lines.
extension SelfTests {
    static func numbersTrackTests() {
        test("numbers.digits.convertsAndLeavesLoneWords") {
            let plan = NumberPlan(style: .digits, language: .en)
            expectEqual(NumberForms.apply("twenty five people, one of them late", plan: plan), "25 people, one of them late")
            expectEqual(NumberForms.apply("three point five percent", plan: plan), "3.5%")
            expectEqual(NumberForms.apply("one of the reasons", plan: plan), "one of the reasons")
            expectEqual(NumberForms.apply("vingt-cinq personnes, un ami", plan: NumberPlan(style: .digits, language: .fr)), "25 personnes, un ami")
            expectEqual(NumberForms.apply("en un momento llegan treinta y cinco", plan: NumberPlan(style: .digits, language: .es)), "en un momento llegan 35")
            expectEqual(NumberForms.apply("een huis voor vijfentwintig mensen", plan: NumberPlan(style: .digits, language: .nl)), "een huis voor 25 mensen")
        }

        test("numbers.words.keepsIdentifiers") {
            let plan = NumberPlan(style: .words, language: .en)
            expectEqual(NumberForms.apply("we saw 25 people", plan: plan), "we saw twenty-five people")
            for kept in ["in 2025", "at 3:30", "GPT-5", "iOS 26", "the M5 chip", "1,000,000 users", "call 555 1234"] {
                expectEqual(NumberForms.apply(kept, plan: plan), kept, kept)
            }
        }

        test("numbers.asSpoken.changesNothing") {
            expectEqual(NumberForms.apply("twenty five and 25", plan: .asSpoken), "twenty five and 25")
            expectEqual(AppConfig.defaultConfig.numbers, .asSpoken)
            expectEqual(LLMCleaner.numberRule(.asSpoken), nil)
        }

        // The Setup example for every style and language is what the pass
        // really writes.
        test("numbers.examples.matchThePass") {
            for language in NumberLanguage.allCases {
                for style in NumberStyle.allCases {
                    let keys = exampleKeys(style)
                    let said = L10n.string(keys.said, language: language.rawValue)
                    let written = L10n.string(keys.written, language: language.rawValue)
                    // WORDS starts from what the speech model wrote.
                    let input = style == .words ? L10n.string("25 people at 3:30", language: language.rawValue) : said
                    let output = NumberForms.apply(input, plan: NumberPlan(style: style, language: language))
                    expectEqual(output, written, "\(language.rawValue) \(style.rawValue)")
                }
            }
        }
    }

    private static func exampleKeys(_ style: NumberStyle) -> (said: String, written: String) {
        switch style {
        case .asSpoken: ("twenty five people, one of them late", "twenty five people, one of them late")
        case .digits: ("twenty five people, one of them late", "25 people, one of them late")
        case .words: ("25 people at 3:30", "Twenty-five people at 3:30")
        }
    }
}
#endif
