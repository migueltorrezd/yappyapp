#if DEBUG
import AppKit
import Foundation
import SwiftUI

// Self-tests for DROPDOWN-FLOAT and the WORDS AND SNIPPETS onboarding step.
extension SelfTests {
    static func onboardingTrackTests() {
        dropdownFloatTests()
        onboardingWordsTests()
    }

    private static func dropdownFloatTests() {
        test("dropdown.openingNeverMovesTheCard") {
            // The owner hated the card shifting when a list opened. Open or
            // closed, the field takes the same height, with a host above it
            // (the app) and without one (a tab body on its own).
            let label = "Self-test language"
            let picker = BrutalPicker(
                choices: AppLanguage.allCases.map { BrutalChoice(value: $0, title: $0.chipLabel) },
                selection: AppLanguage.allCases[0],
                accessibilityLabel: label,
                hint: ""
            ) { _ in }
            for hosted in [true, false] {
                @MainActor func height(open: Bool) -> CGFloat {
                    let card = VStack(spacing: 0) {
                        picker
                        Text("BELOW").frame(height: 40)
                    }
                    .frame(width: 356)
                    .environment(\.brutalDropdownForcedOpen, open ? label : nil)
                    return hosted
                        ? NSHostingView(rootView: card.brutalDropdownHost()).fittingSize.height
                        : NSHostingView(rootView: card).fittingSize.height
                }
                let closed = height(open: false)
                expect(closed > 40, "the card has a real height, got \(closed)")
                expectEqual(height(open: true), closed, "open and closed are the same height, hosted \(hosted)")
            }
            expect(renderImage(
                VStack { picker; Spacer() }.environment(\.brutalDropdownForcedOpen, label).brutalDropdownHost(),
                width: 404, height: 400
            ) != nil, "an open dropdown renders")
        }

        test("dropdown.everyDropdownIsTheSharedOne") {
            // The inline list is gone everywhere; mic, ADD APP and every
            // BrutalPicker draw through BrutalDropdown.
            expect(L10n.table(for: "en")["Expands the microphone list"] != nil, "the mic hint is translated")
            let place = BrutalMenuPlacement.frame(
                field: CGRect(x: 20, y: 500, width: 300, height: 26),
                bounds: CGSize(width: 440, height: 596),
                wantedHeight: BrutalMenuPlacement.wantedHeight(rows: 10)
            )
            expect(place.above, "a long list near the bottom opens upward")
        }
    }

    private static func onboardingWordsTests() {
        test("onboarding.wordsAndSnippetsSaveLikeWords") {
            // What onboarding adds lands in glossary.json and snippets.json
            // through the WORDS save path, on top like + ADD, and CONTINUE
            // waits for both.
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("yappyapp-onboarding-words-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let glossaryURL = folder.appendingPathComponent("glossary.json")
            let snippetsURL = folder.appendingPathComponent("snippets.json")

            let state = makeUIState()
            state.glossaryEntries = Glossary.defaultEntries
            state.snippets = []
            let coordinator = OnboardingCoordinator(state: state)
            coordinator.hooks.saveGlossary = { entries in
                try? Glossary.save(entries, to: glossaryURL)
                state.glossaryEntries = (try? Glossary.load(from: glossaryURL).entries) ?? []
            }
            coordinator.hooks.saveSnippets = { snippets in
                _ = SnippetPersistence.save(snippets, state: state, to: snippetsURL)
            }
            let facts = OnboardingFacts(microphoneAuthorized: true, accessibilityTrusted: true, autoPasteWanted: true, speechModelReady: true)
            var session = OnboardingFlow.start(facts: facts, configLanguage: "auto", translateTarget: .off)
            session.current = .wordsAndSnippets
            state.onboarding = session

            coordinator.next()
            expectEqual(state.onboarding?.current, .wordsAndSnippets, "CONTINUE waits for a word and a snippet")
            expect(coordinator.addWord(canonical: "YappYapp", variantsText: "") != nil, "a word already in WORDS is refused")
            expectEqual(coordinator.addWord(canonical: " Genial ", variantsText: "jenial, jen yal"), nil)
            expect(coordinator.addSnippet(trigger: "email", expansion: "jane@company.com") != nil, "one word never sets off a snippet")
            expect(coordinator.addSnippet(trigger: "jenial", expansion: "x") != nil, "a phrase the glossary rewrites is refused")
            expectEqual(coordinator.addSnippet(trigger: "my email", expansion: "jane@company.com"), nil)

            let words = try Glossary.load(from: glossaryURL).entries
            expectEqual(words.first, GlossaryEntry(canonical: "Genial", variants: ["jenial", "jen yal"], notes: nil))
            expectEqual(words.count, Glossary.defaultEntries.count + 1, "nothing else changed")
            let snippets = try SnippetStore.load(from: snippetsURL)
            expectEqual(snippets.map(\.trigger), ["my email"])
            expectEqual(state.onboarding?.addedSnippet?.expansion, "jane@company.com")

            coordinator.next()
            expectEqual(state.onboarding?.current, .tryIt, "CONTINUE goes on once both are added")
            coordinator.back()
            expectEqual(state.onboarding?.current, .wordsAndSnippets, "BACK works")
        }

        test("onboarding.wordsStepRenders") {
            let previous = L10n.language
            defer { L10n.apply(previous) }
            for language in L10n.supportedLanguages {
                L10n.apply(language)
                for added in [false, true] {
                    let state = makeUIState()
                    var session = OnboardingFlow.start(
                        facts: OnboardingFacts(microphoneAuthorized: false, accessibilityTrusted: false, autoPasteWanted: true, speechModelReady: false),
                        configLanguage: "auto", translateTarget: .off
                    )
                    session.current = .wordsAndSnippets
                    if added {
                        session.addedWord = GlossaryEntry(canonical: "Genial", variants: ["jenial"], notes: nil)
                        session.addedSnippet = Snippet(trigger: L10n.tr("my email"), expansion: L10n.tr("jane@company.com"))
                    }
                    state.onboarding = session
                    expect(renderImage(makeBrutalPopover(state), width: 440, height: 596) != nil, "\(language) WORDS AND SNIPPETS renders, added \(added)")
                }
            }
        }
    }
}
#endif
