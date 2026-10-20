import Foundation

// ONBOARDING: the first-run flow in the control window. Six short steps,
// each with one sentence of what happens and why, one primary action, BACK,
// and SKIP where skipping is safe:
//   LANGUAGES  app language (applied live), the languages you speak, and an
//              optional TRANSLATE TO
//   MODELS     DETECT BEST MODELS: reads this Mac, proposes speech, cleanup
//              and translation with sizes and reasons. Nothing downloads
//              until USE THESE.
//   MIC        the macOS microphone prompt, asked in context
//   AUTO-PASTE Accessibility; moves on by itself when System Settings grants it
//   WORDS AND SNIPPETS  one word and one snippet, saved exactly as the WORDS
//              tab saves them; CONTINUE waits for both, and there is no SKIP
//   TRY IT     a first dictation that uses that word and snippet, then FINISH
// Everything here is pure so the unit tests walk every branch.

enum OnboardingStep: String, CaseIterable, Sendable {
    case languages
    case models
    case microphone
    case autoPaste
    case wordsAndSnippets
    case tryIt
}

/// What the Mac says right now. Read on every refresh.
struct OnboardingFacts: Equatable, Sendable {
    var microphoneAuthorized: Bool
    var accessibilityTrusted: Bool
    /// Auto-paste is on, so Accessibility is worth asking for.
    var autoPasteWanted: Bool
    var speechModelReady: Bool
}

/// The three picks USE THESE applies.
struct OnboardingPicks: Equatable, Sendable {
    var speechID: String
    var cleanup: CleanupMode
    /// nil keeps translation off.
    var translationModel: TranslationModelID?
}

/// One onboarding run. Lives in memory; a relaunch starts a new one from
/// the facts, so a model already on disk skips straight to the open steps.
struct OnboardingSession: Equatable, Sendable {
    /// Fixed when the run starts, so "STEP 3 OF 5" never jumps around.
    var steps: [OnboardingStep]
    var current: OnboardingStep
    /// Spoken language codes. Empty means AUTO.
    var spoken: Set<String>
    var translateTarget: TranslationTarget
    /// nil until the scan comes back.
    var profile: HardwareProfile?
    var recommendations: [ModelRecommendation] = []
    /// What was on this Mac at the scan, so sizes only count real downloads.
    var installed = InstalledModels()
    var picks: OnboardingPicks?
    /// USE THESE was pressed (or a model was already on this Mac).
    var accepted: Bool
    /// ALLOW was pressed on AUTO-PASTE; the screen waits for System Settings.
    var accessibilityRequested = false
    /// Cleanup or translation waits for the speech model to land.
    var extrasQueued = false
    /// The word and the snippet added on WORDS AND SNIPPETS. TRY IT asks
    /// the user to say both.
    var addedWord: GlossaryEntry?
    var addedSnippet: Snippet?
}

enum OnboardingFlow {
    /// The steps for this Mac. Permissions already granted are left out.
    static func steps(for facts: OnboardingFacts) -> [OnboardingStep] {
        var steps: [OnboardingStep] = [.languages, .models]
        if !facts.microphoneAuthorized { steps.append(.microphone) }
        if facts.autoPasteWanted, !facts.accessibilityTrusted { steps.append(.autoPaste) }
        steps.append(.wordsAndSnippets)
        steps.append(.tryIt)
        return steps
    }

    static func start(facts: OnboardingFacts, configLanguage: String, translateTarget: TranslationTarget) -> OnboardingSession {
        let steps = steps(for: facts)
        var session = OnboardingSession(
            steps: steps,
            current: .languages,
            spoken: OnboardingLanguages.initialPicks(configLanguage: configLanguage),
            translateTarget: translateTarget,
            profile: nil,
            picks: nil,
            accepted: facts.speechModelReady
        )
        // A model already here (a relaunch mid-setup, or a reinstall): go
        // on from the first open step after MODELS.
        if facts.speechModelReady {
            session.current = firstOpen(after: .models, in: steps, facts: facts) ?? .tryIt
        }
        return session
    }

    /// True once the step has nothing left to ask.
    static func isSatisfied(_ step: OnboardingStep, facts: OnboardingFacts) -> Bool {
        switch step {
        case .microphone: facts.microphoneAuthorized
        case .autoPaste: !facts.autoPasteWanted || facts.accessibilityTrusted
        case .languages, .models, .wordsAndSnippets, .tryIt: false
        }
    }

    /// CONTINUE waits on WORDS AND SNIPPETS until one of each is added.
    static func canContinue(_ session: OnboardingSession) -> Bool {
        switch session.current {
        case .wordsAndSnippets: session.addedWord != nil && session.addedSnippet != nil
        default: true
        }
    }

    /// The step after `step`, passing permissions granted meanwhile. nil
    /// means the run is done.
    static func firstOpen(after step: OnboardingStep, in steps: [OnboardingStep], facts: OnboardingFacts) -> OnboardingStep? {
        guard let index = steps.firstIndex(of: step) else { return nil }
        return steps[(index + 1)...].first { !isSatisfied($0, facts: facts) }
    }

    static func next(_ session: OnboardingSession, facts: OnboardingFacts) -> OnboardingStep? {
        firstOpen(after: session.current, in: session.steps, facts: facts)
    }

    /// BACK always goes one step back, even to a granted permission, so the
    /// user sees the same screens in reverse.
    static func previous(_ session: OnboardingSession) -> OnboardingStep? {
        guard let index = session.steps.firstIndex(of: session.current), index > 0 else { return nil }
        return session.steps[index - 1]
    }

    /// The screen moves on by itself once macOS grants what it asked for.
    static func autoAdvances(_ step: OnboardingStep, facts: OnboardingFacts) -> Bool {
        (step == .microphone || step == .autoPaste) && isSatisfied(step, facts: facts)
    }

    /// SKIP only where nothing breaks: the user can pick models in MODELS,
    /// allow the mic or auto-paste from the MIC tab, and try it any time.
    /// LANGUAGES has sensible defaults, so CONTINUE is the skip. WORDS AND
    /// SNIPPETS is required: the owner wants every user to add one of each.
    static func skipTitle(for step: OnboardingStep) -> String? {
        switch step {
        case .languages: nil
        case .models: L10n.tr("CHOOSE LATER")
        case .microphone, .autoPaste: L10n.tr("SKIP")
        case .wordsAndSnippets, .tryIt: nil
        }
    }

    /// "STEP 2 OF 5".
    static func badge(for step: OnboardingStep, in steps: [OnboardingStep]) -> String {
        let index = (steps.firstIndex(of: step) ?? 0) + 1
        return L10n.tr("Step %@ of %@", "\(index)", "\(steps.count)").uppercased()
    }
}

// MARK: - Languages

enum OnboardingLanguages {
    static let auto = "auto"

    /// AUTO and specific languages exclude each other. Turning the last
    /// language off goes back to AUTO.
    static func toggle(_ code: String, in picks: Set<String>) -> Set<String> {
        if code == auto { return [] }
        var next = picks
        if next.contains(code) {
            next.remove(code)
        } else {
            next.insert(code)
        }
        return next
    }

    /// The dictation language setting: one language the setting offers, or
    /// auto-detect for several (or one only the model pick uses).
    static func configLanguage(for picks: Set<String>) -> String {
        guard picks.count == 1, let only = picks.first,
              LanguageCatalog.options.contains(where: { $0.code == only }) else { return auto }
        return only
    }

    static func initialPicks(configLanguage: String) -> Set<String> {
        configLanguage == auto || configLanguage.isEmpty ? [] : [configLanguage]
    }
}

// MARK: - Model picks

/// One row of DETECT BEST MODELS.
struct OnboardingPickRow: Equatable, Sendable {
    let kind: RecommendationKind
    let title: String
    let reason: String
    /// What USE THESE downloads for this row; nil when nothing.
    let downloadBytes: Int64?
}

enum OnboardingPlan {
    static var cleanupModelBytes: Int64 {
        Int64(LLMCleaner.model.approximateSizeMB) * 1_000_000
    }

    /// The advisor's picks as a starting point. Translation stays off unless
    /// a TRANSLATE TO language is set, and cleanup and translation need the
    /// bundled llama.cpp runtime.
    static func picks(
        from recommendations: [ModelRecommendation],
        translateTarget: TranslationTarget,
        llamaRuntimeAvailable: Bool
    ) -> OnboardingPicks {
        var speechID = ModelCatalog.recommendedID
        var cleanup = CleanupMode.verbatim
        var translation: TranslationModelID?
        for recommendation in recommendations {
            switch recommendation.choice {
            case .speech(let id): speechID = id
            case .cleanup(let mode): cleanup = llamaRuntimeAvailable ? mode : .verbatim
            case .translation(let id):
                if translateTarget != .off, llamaRuntimeAvailable { translation = id }
            case .none: break
            }
        }
        if translateTarget != .off, llamaRuntimeAvailable, translation == nil,
           recommendations.contains(where: { $0.kind == .translation && $0.choice == .none }) == false {
            translation = TranslationCatalog.defaultModelID
        }
        return OnboardingPicks(speechID: speechID, cleanup: cleanup, translationModel: translation)
    }

    static func rows(
        picks: OnboardingPicks,
        recommendations: [ModelRecommendation],
        installed: InstalledModels,
        translateTarget: TranslationTarget,
        llamaRuntimeAvailable: Bool
    ) -> [OnboardingPickRow] {
        func advised(_ kind: RecommendationKind, _ choice: RecommendedChoice) -> ModelRecommendation? {
            recommendations.first { $0.kind == kind && $0.choice == choice }
        }

        let speechOption = ModelCatalog.option(for: picks.speechID)
        let speech = OnboardingPickRow(
            kind: .speech,
            title: speechOption?.name ?? picks.speechID,
            reason: advised(.speech, .speech(modelID: picks.speechID))?.reason
                ?? speechOption.map { L10n.tr($0.summary) } ?? "",
            downloadBytes: installed.speechIDs.contains(picks.speechID) ? nil : speechOption?.downloadBytes
        )

        let cleanup: OnboardingPickRow
        if picks.cleanup.usesModel {
            cleanup = OnboardingPickRow(
                kind: .cleanup,
                title: "\(picks.cleanup.label) · Qwen 2.5 1.5B",
                reason: advised(.cleanup, .cleanup(picks.cleanup))?.reason
                    ?? L10n.tr("Fixes punctuation and false starts. Adds about a second."),
                downloadBytes: installed.cleanupModel ? nil : cleanupModelBytes
            )
        } else {
            cleanup = OnboardingPickRow(
                kind: .cleanup,
                title: CleanupMode.verbatim.label,
                reason: llamaRuntimeAvailable
                    ? advised(.cleanup, .cleanup(.verbatim))?.reason ?? L10n.tr("Your words exactly as you said them. Nothing to download.")
                    : L10n.tr("Cleanup can't run in this copy of YappYapp."),
                downloadBytes: nil
            )
        }

        let translation: OnboardingPickRow
        if let id = picks.translationModel {
            let model = TranslationCatalog.model(id)
            translation = OnboardingPickRow(
                kind: .translation,
                title: "\(model.name) · \(translateTarget.label)",
                reason: advised(.translation, .translation(id))?.reason ?? L10n.tr(model.summary),
                downloadBytes: installed.translation.contains(id) ? nil : model.download?.sizeBytes
            )
        } else {
            let reason: String
            if translateTarget == .off {
                reason = L10n.tr("Off. Pick a TRANSLATE TO language in step 1 to add it.")
            } else if !llamaRuntimeAvailable {
                reason = L10n.tr("Translation can't run in this copy of YappYapp.")
            } else {
                reason = recommendations.first { $0.kind == .translation }?.reason
                    ?? L10n.tr("Off. Pick a TRANSLATE TO language in step 1 to add it.")
            }
            translation = OnboardingPickRow(kind: .translation, title: L10n.tr("OFF"), reason: reason, downloadBytes: nil)
        }
        return [speech, cleanup, translation]
    }

    static func totalBytes(_ rows: [OnboardingPickRow]) -> Int64 {
        rows.compactMap(\.downloadBytes).reduce(0, +)
    }

    /// The config USE THESE saves. The speech model is selected through the
    /// normal download path, so the current one keeps working until it lands.
    static func applying(_ picks: OnboardingPicks, spoken: Set<String>, translateTarget: TranslationTarget, to config: AppConfig) -> AppConfig {
        var config = config
        config.language = OnboardingLanguages.configLanguage(for: spoken)
        config.cleanup = picks.cleanup
        if let id = picks.translationModel, translateTarget != .off {
            config.translation = translateTarget
            config.translationModelID = id
        } else {
            config.translation = .off
        }
        return config
    }
}

// MARK: - Copy

enum OnboardingCopy {
    static func title(_ step: OnboardingStep) -> String {
        switch step {
        case .languages: L10n.tr("YOUR LANGUAGES")
        case .models: L10n.tr("DETECT BEST MODELS")
        case .microphone: L10n.tr("ALLOW THE MIC")
        case .autoPaste: L10n.tr("ALLOW AUTO-PASTE")
        case .wordsAndSnippets: L10n.tr("WORDS AND SNIPPETS")
        case .tryIt: L10n.tr("TRY IT")
        }
    }

    /// One sentence: what happens on this screen and why.
    static func detail(_ step: OnboardingStep, downloadsAllowed: Bool = true, accepted: Bool = false, microphoneDenied: Bool = false) -> String {
        switch step {
        case .languages:
            L10n.tr("Pick the language for YappYapp and the ones you speak, so it suggests a model that understands you.")
        case .models:
            if !downloadsAllowed {
                L10n.tr("Model downloads are off on this Mac, so these are only suggestions. Ask your IT admin to install the speech model.")
            } else if accepted {
                L10n.tr("Your models are downloading. Keep going; the next steps don't need them.")
            } else {
                L10n.tr("YappYapp read this Mac and picked what fits. Nothing downloads until you click USE THESE.")
            }
        case .microphone:
            microphoneDenied
                ? L10n.tr("The mic is blocked. Click OPEN SETTINGS, turn on YappYapp under Microphone, then come back.")
                : L10n.tr("YappYapp listens only while you dictate, and your audio stays on this Mac.")
        case .autoPaste:
            L10n.tr("So your words land at your cursor in any app. Without it, text is copied and you press ⌘V.")
        case .wordsAndSnippets:
            L10n.tr("Add one of each to continue. You will say both in the next step and see them work.")
        case .tryIt:
            L10n.tr("Press ⌥ space or the button, say a sentence, then press again. The text shows up here.")
        }
    }

    static var autoPasteSteps: String {
        L10n.tr("Click ALLOW, turn on YappYapp in System Settings > Privacy & Security > Accessibility, then come back. This screen moves on by itself.")
    }

    static var autoPasteWaiting: String {
        L10n.tr("Waiting for System Settings. Turn on YappYapp under Accessibility.")
    }

    static var microphoneAllowed: String { L10n.tr("Mic allowed.") }
    static var autoPasteAllowed: String { L10n.tr("Auto-paste allowed.") }
}

// MARK: - Words and snippets

/// WORDS AND SNIPPETS: the same rules and the same files as the WORDS tab.
/// A word goes through `GlossaryDraftValidator`, a snippet through
/// `SnippetDraftValidator`, and both land at the top of the saved list,
/// where WORDS puts a row added with + ADD.
enum OnboardingWords {
    /// The problem with this word, or nil when ADD WORD may save it.
    static func wordIssue(canonical: String, variantsText: String, existing: [GlossaryEntry]) -> String? {
        if canonical.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return L10n.tr("Add the spelling to write.")
        }
        return GlossaryDraftValidator.issue(
            canonical: canonical,
            variantsText: variantsText,
            otherCanonicals: existing.map(\.canonical)
        )
    }

    /// The problem with this snippet, or nil when ADD SNIPPET may save it.
    static func snippetIssue(trigger: String, expansion: String, existing: [Snippet], glossary: [GlossaryEntry]) -> String? {
        if SnippetDraftValidator.isBlank(trigger: trigger, expansion: expansion) {
            return L10n.tr("Add the phrase you will say.")
        }
        return SnippetDraftValidator.issue(
            trigger: trigger,
            expansion: expansion,
            otherTriggers: existing.map(\.trigger),
            glossary: glossary
        )
    }

    /// The word as WORDS would save it: trimmed, sounds-like split on commas.
    static func entry(canonical: String, variantsText: String) -> GlossaryEntry {
        var entry = GlossaryEntryDraft(canonical: canonical, variantsText: variantsText, notes: "").entry
        // Glossary.save trims too; trim here so the saved word is found again.
        entry.canonical = entry.canonical.trimmingCharacters(in: .whitespacesAndNewlines)
        return entry
    }

    static func snippet(trigger: String, expansion: String) -> Snippet {
        Snippet(trigger: trigger.trimmingCharacters(in: .whitespacesAndNewlines), expansion: expansion)
    }

    /// The saved list with the new item on top, like + ADD in WORDS.
    static func adding(_ entry: GlossaryEntry, to existing: [GlossaryEntry]) -> [GlossaryEntry] {
        [entry] + existing
    }

    static func adding(_ snippet: Snippet, to existing: [Snippet]) -> [Snippet] {
        [snippet] + existing
    }

    /// The word field's example: the user's surname, the kind of word a
    /// dictation model spells wrong. Falls back to the WORDS tab example.
    static func wordPlaceholder(fullName: String) -> String {
        let parts = fullName.split(whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count >= 2, let last = parts.last, last.count >= 3,
              last.allSatisfy({ $0.isLetter || $0 == "-" || $0 == "'" }) else {
            return GlossaryPlaceholders.writeItAs
        }
        return last
    }

    /// The confirmation under a saved word.
    static func wordConfirmation(_ entry: GlossaryEntry) -> String {
        if let variant = entry.variants.first {
            return L10n.tr("You say \"%@\", it writes \"%@\".", variant, entry.canonical)
        }
        return L10n.tr("It always writes \"%@\".", entry.canonical)
    }

    /// The confirmation under a saved snippet. Long text is cut short.
    static func snippetConfirmation(_ snippet: Snippet) -> String {
        L10n.tr("You say \"%@\", it pastes \"%@\".", snippet.trigger, preview(snippet.expansion))
    }

    static func preview(_ text: String, limit: Int = 32) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flat.count > limit else { return flat }
        return String(flat.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// TRY IT: the sentence to say, with the word and the snippet phrase.
    static func tryItSentence(word: GlossaryEntry, snippet: Snippet) -> String {
        L10n.tr("%@, here is %@.", word.canonical, snippet.trigger)
    }
}

/// TRY IT after a test dictation: did the word come out spelled the user's
/// way, and did the snippet expand? Pure, so the tests read every case.
struct OnboardingTryItCheck: Equatable, Sendable {
    struct Line: Equatable, Sendable {
        let ok: Bool
        let text: String
    }

    let wordFound: Bool
    let snippetFound: Bool
    /// Where to mark the transcript: the word and the pasted text.
    let wordRange: Range<String.Index>?
    let snippetRange: Range<String.Index>?

    init(text: String, word: GlossaryEntry, snippet: Snippet) {
        let pasted = snippet.expansion.trimmingCharacters(in: .whitespacesAndNewlines)
        snippetRange = pasted.isEmpty ? nil : text.range(of: pasted)
        // The exact spelling, outside the pasted text, so a word that is
        // also inside the snippet text is not credited by the snippet.
        var found: Range<String.Index>?
        var start = text.startIndex
        while start < text.endIndex, let range = text.range(of: word.canonical, range: start..<text.endIndex) {
            if let snippetRange, range.overlaps(snippetRange) {
                start = range.upperBound
                continue
            }
            found = range
            break
        }
        wordRange = found
        wordFound = found != nil
        snippetFound = snippetRange != nil
    }

    func lines(word: GlossaryEntry, snippet: Snippet) -> [Line] {
        [
            wordFound
                ? Line(ok: true, text: L10n.tr("Word: \"%@\" came out spelled your way.", word.canonical))
                : Line(ok: false, text: L10n.tr("\"%@\" isn't in the text. Say it again, or add how it sounds under SOUNDS LIKE in WORDS.", word.canonical)),
            snippetFound
                ? Line(ok: true, text: L10n.tr("Snippet: \"%@\" turned into your text.", snippet.trigger))
                : Line(ok: false, text: L10n.tr("The snippet didn't fire. Say \"%@\" exactly, as its own words, then try again.", snippet.trigger))
        ]
    }
}

// MARK: - Download status

/// The download strip under the permission and TRY IT screens.
struct OnboardingDownloadLine: Equatable, Sendable {
    let title: String
    let status: String
    /// 0...1, or nil when there is no bar to draw.
    let fraction: Double?
    let isError: Bool
    let isDone: Bool
}

enum OnboardingDownloads {
    static func speechLine(name: String, ready: Bool, progress: Double?, error: String?) -> OnboardingDownloadLine {
        if ready {
            return OnboardingDownloadLine(title: name, status: L10n.tr("READY"), fraction: 1, isError: false, isDone: true)
        }
        if let progress {
            let percent = Int(min(max(progress, 0), 1) * 100)
            return OnboardingDownloadLine(title: name, status: "\(percent)%", fraction: max(progress, 0), isError: false, isDone: false)
        }
        if let error {
            return OnboardingDownloadLine(title: name, status: error, fraction: nil, isError: true, isDone: false)
        }
        return OnboardingDownloadLine(title: name, status: L10n.tr("WAITING"), fraction: nil, isError: false, isDone: false)
    }

    /// nil when there is nothing to show for that kind.
    static func extraLine(name: String, phase: CleanupDownloadPhase, verified: Bool, queued: Bool) -> OnboardingDownloadLine? {
        if verified {
            return OnboardingDownloadLine(title: name, status: L10n.tr("READY"), fraction: 1, isError: false, isDone: true)
        }
        switch phase {
        case .downloading(let fraction):
            let status = fraction.map { "\(Int($0 * 100))%" } ?? L10n.tr("DOWNLOADING")
            return OnboardingDownloadLine(title: name, status: status, fraction: fraction, isError: false, isDone: false)
        case .verifying:
            return OnboardingDownloadLine(title: name, status: L10n.tr("VERIFYING"), fraction: nil, isError: false, isDone: false)
        case .failed(let message):
            return OnboardingDownloadLine(title: name, status: message, fraction: nil, isError: true, isDone: false)
        case .idle:
            return queued
                ? OnboardingDownloadLine(title: name, status: L10n.tr("AFTER THE SPEECH MODEL"), fraction: nil, isError: false, isDone: false)
                : nil
        }
    }
}
