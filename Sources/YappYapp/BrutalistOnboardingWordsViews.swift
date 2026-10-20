import SwiftUI

// ONBOARDING: WORDS AND SNIPPETS, and the TRY IT panels that use them.
// The step is two cards side by side, built the same way so the difference
// reads at a glance: what it is, one concrete example, the fields, ADD.
// Saving goes through the WORDS tab files (OnboardingCoordinator).

private struct OnboardingWordsPreviewKey: EnvironmentKey {
    static let defaultValue: OnboardingWordsPreview? = nil
}

/// The render gallery types into the fields and shows a problem. Nil in the app.
struct OnboardingWordsPreview: Sendable {
    var canonical = ""
    var variants = ""
    var trigger = ""
    var expansion = ""
    var wordIssue: String?
    var snippetIssue: String?
}

extension EnvironmentValues {
    var onboardingWordsPreview: OnboardingWordsPreview? {
        get { self[OnboardingWordsPreviewKey.self] }
        set { self[OnboardingWordsPreviewKey.self] = newValue }
    }
}

struct OnboardingWordsCard: View {
    let session: OnboardingSession
    @Environment(\.onboardingActions) private var actions
    @Environment(\.onboardingWordsPreview) private var preview
    @Environment(\.brutalFlattensScroll) private var offscreen

    @State private var canonical = ""
    @State private var variants = ""
    @State private var trigger = ""
    @State private var expansion = ""
    @State private var wordIssue: String?
    @State private var snippetIssue: String?
    @State private var seeded = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            column(
                title: L10n.tr("WORD"),
                what: L10n.tr("A name or term YappYapp should always spell right."),
                example: ("yap yap", L10n.tr("IT WRITES"), "YappYapp"),
                confirmation: session.addedWord.map(OnboardingWords.wordConfirmation)
            ) {
                wordForm
            }
            column(
                title: L10n.tr("SNIPPET"),
                what: L10n.tr("A short phrase you say that pastes a longer text."),
                example: (L10n.tr("my email"), L10n.tr("IT PASTES"), L10n.tr("jane@company.com")),
                confirmation: session.addedSnippet.map(OnboardingWords.snippetConfirmation)
            ) {
                snippetForm
            }
        }
        // Both cards as tall as the taller one, so they read as a pair.
        .fixedSize(horizontal: false, vertical: true)
        .padding(.trailing, Brutal.drop)
        .onAppear(perform: seed)
    }

    // MARK: - Column

    private func column<Form: View>(
        title: String,
        what: String,
        example: (say: String, verb: String, result: String),
        confirmation: String?,
        @ViewBuilder form: () -> Form
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(title)
                    .brutalText(.sectionTitle)
                    .foregroundStyle(Brutal.paper)
                Spacer(minLength: 0)
                if confirmation != nil {
                    Image(systemName: "checkmark")
                        .brutalText(.sectionTitle)
                        .foregroundStyle(Brutal.green)
                        .accessibilityLabel(Text(L10n.tr("Added")))
                }
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
            .background(Brutal.ink)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: 9) {
                Text(what)
                    .brutalFont(size: 10.5, weight: .bold, relativeTo: .caption)
                    .foregroundStyle(Brutal.ink)
                    .fixedSize(horizontal: false, vertical: true)

                exampleBlock(example)

                Rectangle().fill(Brutal.ink).frame(height: 1).accessibilityHidden(true)

                if let confirmation {
                    confirmationBlock(confirmation)
                } else {
                    form()
                }
            }
            .padding(10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Brutal.card)
        .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))
        .background(Rectangle().fill(Brutal.ink).offset(x: Brutal.drop, y: Brutal.drop))
    }

    /// "YOU SAY yap yap / IT WRITES YappYapp": the one concrete example.
    private func exampleBlock(_ example: (say: String, verb: String, result: String)) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            exampleLine(L10n.tr("YOU SAY"), "\u{201C}\(example.say)\u{201D}", strong: false)
            exampleLine(example.verb, example.result, strong: true)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brutal.yellow)
        .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(L10n.tr("Example: you say %@, %@ %@", example.say, example.verb.lowercased(), example.result)))
    }

    private func exampleLine(_ label: String, _ value: String, strong: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .brutalFont(size: 7.5, weight: .black, relativeTo: .caption2)
                .kerning(0.8)
                .foregroundStyle(Brutal.contentOnYellow)
            Text(value)
                .brutalFont(size: strong ? 12 : 11, weight: strong ? .black : .semibold, design: .monospaced, relativeTo: .callout)
                .foregroundStyle(Brutal.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }

    private func confirmationBlock(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L10n.tr("ADDED"))
                .brutalText(.rowLabel)
                .foregroundStyle(Brutal.contentOnGreen)
            Text(text)
                .brutalFont(size: 10.5, weight: .semibold, relativeTo: .caption)
                .foregroundStyle(Brutal.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(L10n.tr("Change it any time in WORDS."))
                .brutalFont(size: 9.5, weight: .medium, relativeTo: .caption2)
                .foregroundStyle(Brutal.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brutal.green)
        .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Forms

    private var wordForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            labeled(L10n.tr("WRITE IT AS")) {
                BrutalField(label: L10n.tr("Write it as"), placeholder: OnboardingWords.wordPlaceholder(fullName: NSFullUserName()), text: $canonical)
                    .onSubmit(addWord)
            }
            labeled(L10n.tr("SOUNDS LIKE · OPTIONAL")) {
                BrutalField(label: L10n.tr("Sounds like"), placeholder: L10n.tr("what it writes now"), text: $variants)
                    .onSubmit(addWord)
            }
            issueLine(wordIssue ?? previewIssue(\.wordIssue, matches: preview?.canonical == canonical))
            addButton(
                L10n.tr("ADD WORD"),
                enabled: !canonical.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                label: L10n.tr("Add word"),
                hint: L10n.tr("Saves this word to WORDS"),
                action: addWord
            )
        }
        .onChange(of: canonical) { _, _ in wordIssue = nil }
        .onChange(of: variants) { _, _ in wordIssue = nil }
    }

    private var snippetForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            labeled(L10n.tr("WHEN I SAY")) {
                BrutalField(label: L10n.tr("When I say"), placeholder: SnippetPlaceholders.trigger, text: $trigger)
                    .onSubmit(addSnippet)
            }
            labeled(L10n.tr("PASTE THIS")) {
                expansionInput
                    .brutalFont(size: 11.5, weight: .semibold, design: .monospaced, relativeTo: .callout)
                    .foregroundStyle(Brutal.ink)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Brutal.field)
                    .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))
                    .focusEffectDisabled()
                    .brutalFocusRing()
                    .accessibilityLabel(Text(L10n.tr("Paste this")))
            }
            issueLine(snippetIssue ?? previewIssue(\.snippetIssue, matches: preview?.trigger == trigger))
            addButton(
                L10n.tr("ADD SNIPPET"),
                enabled: !SnippetDraftValidator.isBlank(trigger: trigger, expansion: "")
                    && !expansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                label: L10n.tr("Add snippet"),
                hint: L10n.tr("Saves this snippet to WORDS"),
                action: addSnippet
            )
        }
        .onChange(of: trigger) { _, _ in snippetIssue = nil }
        .onChange(of: expansion) { _, _ in snippetIssue = nil }
    }

    @ViewBuilder
    private var expansionInput: some View {
        if offscreen {
            // The render gallery cannot draw an AppKit text field.
            Text(expansion.isEmpty ? SnippetPlaceholders.expansion : expansion)
                .foregroundStyle(expansion.isEmpty ? Brutal.textTertiary : Brutal.ink)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            TextField(L10n.tr("Paste this"), text: $expansion, prompt: Text(SnippetPlaceholders.expansion).foregroundStyle(Brutal.textTertiary), axis: .vertical)
                .lineLimit(1...3)
                .textFieldStyle(.plain)
        }
    }

    private func labeled<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .brutalFont(size: 7.5, weight: .black, relativeTo: .caption2)
                .kerning(0.8)
                .foregroundStyle(Brutal.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            content()
        }
    }

    @ViewBuilder
    private func issueLine(_ issue: String?) -> some View {
        if let issue {
            Text(issue.uppercased())
                .brutalFont(size: 8.5, weight: .black, relativeTo: .caption2)
                .kerning(0.5)
                .foregroundStyle(Brutal.dangerText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(Text(L10n.tr("Problem: %@", issue)))
        }
    }

    private func addButton(_ title: String, enabled: Bool, label: String, hint: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(BrutalTextButtonStyle(fill: enabled ? Brutal.blue : Brutal.card, text: enabled ? Brutal.paper : Brutal.textDisabled))
            .disabled(!enabled)
            .brutalInteractive(label: label, hint: hint, hitExpansion: 5)
    }

    // MARK: - Actions

    private func addWord() {
        guard !canonical.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        wordIssue = actions.addWord(canonical, variants)
    }

    private func addSnippet() {
        guard !trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        snippetIssue = actions.addSnippet(trigger, expansion)
    }

    private func seed() {
        guard !seeded, let preview else { return }
        seeded = true
        canonical = preview.canonical
        variants = preview.variants
        trigger = preview.trigger
        expansion = preview.expansion
    }

    /// The gallery's problem line, shown while the field still holds the
    /// text it was written for.
    private func previewIssue(_ key: KeyPath<OnboardingWordsPreview, String?>, matches: Bool) -> String? {
        guard matches, let preview else { return nil }
        return preview[keyPath: key]
    }
}

// MARK: - TRY IT

/// Before the first dictation: the sentence to say, with the word and the
/// snippet phrase marked.
struct OnboardingTryItPrompt: View {
    let word: GlossaryEntry
    let snippet: Snippet

    var body: some View {
        let sentence = OnboardingWords.tryItSentence(word: word, snippet: snippet)
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.tr("SAY THIS"))
                .brutalText(.sectionTitle)
                .foregroundStyle(Brutal.paper)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                .background(Brutal.ink)
                .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: 8) {
                Text(OnboardingMarks.attributed(sentence, marks: [
                    (sentence.range(of: word.canonical), .word),
                    (sentence.range(of: snippet.trigger), .snippet)
                ]))
                .brutalFont(size: 15, weight: .black, relativeTo: .headline)
                .foregroundStyle(Brutal.ink)
                .fixedSize(horizontal: false, vertical: true)

                legend(.word, L10n.tr("Your word. It should come out as \"%@\".", word.canonical))
                legend(.snippet, L10n.tr("Your snippet. It should turn into \"%@\".", OnboardingWords.preview(snippet.expansion)))
            }
            .padding(11)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brutal.card)
        .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))
        .background(Rectangle().fill(Brutal.ink).offset(x: Brutal.drop, y: Brutal.drop))
        .accessibilityElement(children: .combine)
    }

    private func legend(_ mark: OnboardingMarks.Kind, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Rectangle()
                .fill(mark.fill)
                .frame(width: 10, height: 10)
                .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: 1))
                .accessibilityHidden(true)
            Text(text)
                .brutalFont(size: 10, weight: .semibold, relativeTo: .caption)
                .foregroundStyle(Brutal.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// After the test dictation: the text with the word and the pasted snippet
/// marked, and one line each saying whether it worked and what to try.
struct OnboardingTryItResult: View {
    let text: String
    let word: GlossaryEntry?
    let snippet: Snippet?

    var body: some View {
        if let word, let snippet {
            let check = OnboardingTryItCheck(text: text, word: word, snippet: snippet)
            let allGood = check.wordFound && check.snippetFound
            VStack(alignment: .leading, spacing: 8) {
                Text(allGood ? L10n.tr("IT WORKS. YOU SAID:") : L10n.tr("YOU SAID:"))
                    .brutalText(.rowLabel)
                    .foregroundStyle(allGood ? Brutal.contentOnGreen : Brutal.contentOnYellow)
                Text(OnboardingMarks.attributed(text, marks: [(check.wordRange, .word), (check.snippetRange, .snippet)]))
                    .brutalFont(size: 12, weight: .medium, relativeTo: .callout)
                    .foregroundStyle(Brutal.ink)
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Brutal.card)
                    .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))
                ForEach(Array(check.lines(word: word, snippet: snippet).enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: line.ok ? "checkmark" : "xmark")
                            .brutalFont(size: 10, weight: .black, relativeTo: .caption)
                            .foregroundStyle(Brutal.ink)
                            .accessibilityLabel(Text(line.ok ? L10n.tr("Worked") : L10n.tr("Didn't work")))
                        Text(line.text)
                            .brutalFont(size: 10.5, weight: .semibold, relativeTo: .caption)
                            .foregroundStyle(Brutal.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(allGood ? Brutal.green : Brutal.yellow)
            .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))
            .background(Rectangle().fill(Brutal.ink).offset(x: Brutal.drop, y: Brutal.drop))
            .accessibilityElement(children: .combine)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr("IT WORKS. YOU SAID:"))
                    .brutalText(.rowLabel)
                    .foregroundStyle(Brutal.contentOnGreen)
                Text(text)
                    .brutalFont(size: 12, weight: .medium, relativeTo: .callout)
                    .foregroundStyle(Brutal.ink)
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Brutal.green)
            .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))
            .background(Rectangle().fill(Brutal.ink).offset(x: Brutal.drop, y: Brutal.drop))
            .accessibilityElement(children: .combine)
        }
    }
}

/// Marks the word (yellow) and the snippet (blue) inside a line of text.
enum OnboardingMarks {
    enum Kind {
        case word
        case snippet

        var fill: Color {
            switch self {
            case .word: Brutal.yellow
            case .snippet: Brutal.blue
            }
        }

        var text: Color {
            switch self {
            case .word: Brutal.contentOnYellow
            case .snippet: Brutal.paper
            }
        }
    }

    static func attributed(_ text: String, marks: [(Range<String.Index>?, Kind)]) -> AttributedString {
        var result = AttributedString(text)
        for (range, kind) in marks {
            guard let range,
                  let lower = AttributedString.Index(range.lowerBound, within: result),
                  let upper = AttributedString.Index(range.upperBound, within: result) else { continue }
            result[lower..<upper].backgroundColor = kind.fill
            result[lower..<upper].foregroundColor = kind.text
        }
        return result
    }
}
