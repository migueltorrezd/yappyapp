#if DEBUG
import Foundation
import NaturalLanguage
import SwiftUI

// Self-tests owned by the "cleanup" work track. Keep this track's new
// assertions here so parallel tracks never edit the same test lines.
extension SelfTests {
    static func cleanupTrackTests() {
        cleanupModeConfigTests()
        cleanupSelfCorrectionTests()
        cleanupAcceptanceTests()
        cleanupRunTests()
        cleanupRuntimeTests()
        cleanupModelStoreTests()
        cleanupReadinessTests()
    }

    // MARK: - Modes and config

    private static func cleanupModeConfigTests() {
        test("cleanup.modeDefaultsToVerbatim") {
            expectEqual(AppConfig.defaultConfig.cleanup, .verbatim, "cleanup stays opt-in")
            expectEqual(AppConfig.defaultConfig.cleanupMode, "verbatim")
            expect(!CleanupMode.verbatim.usesModel, "Verbatim never loads the model")
            expect(CleanupMode.allCases.filter(\.usesModel).count == 4, "Clean, Email, List and Notes use the model")
        }

        test("cleanup.legacyConfigFollowsOnOffSwitch") {
            let core = #""whisperBinaryPath":"/usr/local/bin/whisper-cli","modelPath":"/tmp/m.bin","language":"auto","additionalPrompt":"","maxRecordingSeconds":300,"restoreClipboardAfterPaste":true,"pasteWhenFocusIsUnclear":true"#
            let on = try JSONDecoder().decode(AppConfig.self, from: Data("{\(core),\"llmCleanup\":true}".utf8))
            expectEqual(on.cleanup, .clean, "an old ON switch means Clean")
            let off = try JSONDecoder().decode(AppConfig.self, from: Data("{\(core),\"llmCleanup\":false}".utf8))
            expectEqual(off.cleanup, .verbatim)
            let missing = try JSONDecoder().decode(AppConfig.self, from: Data("{\(core)}".utf8))
            expectEqual(missing.cleanup, .verbatim, "no key at all stays off")
            let email = try JSONDecoder().decode(AppConfig.self, from: Data("{\(core),\"llmCleanup\":true,\"cleanupMode\":\"email\"}".utf8))
            expectEqual(email.cleanup, .email)
            let bogus = try JSONDecoder().decode(AppConfig.self, from: Data("{\(core),\"llmCleanup\":true,\"cleanupMode\":\"poetry\"}".utf8))
            expectEqual(bogus.cleanup, .clean, "an unknown mode falls back to the switch")
            let wrongType = try JSONDecoder().decode(AppConfig.self, from: Data("{\(core),\"cleanupMode\":7}".utf8))
            expectEqual(wrongType.cleanup, .verbatim, "a damaged mode costs only that value")
        }

        test("cleanup.modeRoundTripsAndSyncsLegacyFlag") {
            var config = AppConfig.defaultConfig
            config.cleanup = .list
            expect(config.llmCleanup, "a model mode keeps the legacy flag on for older builds")
            let decoded = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config))
            expectEqual(decoded.cleanup, .list)
            config.cleanup = .verbatim
            expect(!config.llmCleanup, "Verbatim turns the legacy flag off")
            let initialized = AppConfig(
                whisperBinaryPath: "/x", modelPath: "/m", language: "auto", additionalPrompt: "",
                maxRecordingSeconds: 60, pasteWhenFocusIsUnclear: true,
                llmCleanup: true
            )
            expectEqual(initialized.cleanup, .clean, "the memberwise init derives the mode from the switch")
        }

        test("cleanup.configRepairKeepsMode") {
            let damaged = Data(#"{"whisperBinaryPath":"/w","modelPath":"/m","language":"auto","additionalPrompt":"","maxRecordingSeconds":"broken","restoreClipboardAfterPaste":true,"pasteWhenFocusIsUnclear":true,"cleanupMode":"notes","llmCleanup":true}"#.utf8)
            let outcome = ConfigRecovery.decode(data: damaged, installDefaults: .defaultConfig, lastSaved: { nil })
            expect(outcome.isDamaged, "fixture is damaged")
            expectEqual(outcome.config.cleanup, .notes, "repair keeps the cleanup mode")
            let legacy = Data(#"{"whisperBinaryPath":"/w","modelPath":"/m","language":"auto","additionalPrompt":"","maxRecordingSeconds":"broken","restoreClipboardAfterPaste":true,"pasteWhenFocusIsUnclear":true,"llmCleanup":true}"#.utf8)
            expectEqual(
                ConfigRecovery.decode(data: legacy, installDefaults: .defaultConfig, lastSaved: { nil }).config.cleanup,
                .clean,
                "repair of an old file follows its on/off switch"
            )
            expectEqual(ConfigRecovery.fieldTypes["cleanupMode"], .string)
        }

        test("cleanup.modeCopy") {
            for mode in CleanupMode.allCases {
                expect(!mode.summary.isEmpty && !mode.summary.contains("\u{2014}"), "\(mode) summary is plain")
                expect(mode.hudNote.hasPrefix("CLEANING UP"), "\(mode) HUD note says CLEANING")
            }
            expectEqual(CleanupMode.clean.hudNote, "CLEANING UP")
            expectEqual(CleanupMode.email.hudNote, "CLEANING UP · EMAIL")
        }
    }

    // MARK: - Self-corrections

    private static func cleanupSelfCorrectionTests() {
        test("cleanup.selfCorrectionAnchored") {
            expectEqual(
                SelfCorrection.resolve("so um i think we should uh ship the beta on monday no wait on tuesday after the standup"),
                "so um i think we should uh ship the beta on tuesday after the standup",
                "the repeated word anchors the correction even without punctuation"
            )
            expectEqual(
                SelfCorrection.resolve("Send the report, no wait, the slides to Anna."),
                "Send the slides to Anna."
            )
            expectEqual(
                SelfCorrection.resolve("Let's meet on Monday. No wait, on Tuesday."),
                "Let's meet on Tuesday.",
                "a correction opening a new sentence reaches back into the previous one"
            )
            expectEqual(
                SelfCorrection.resolve("We land at 5, sorry I meant at 6 tonight."),
                "We land at 6 tonight."
            )
        }

        test("cleanup.selfCorrectionUnanchored") {
            expectEqual(SelfCorrection.resolve("Send it to John, no wait, Mary."), "Send it to Mary.")
            expectEqual(SelfCorrection.resolve("Meet at 5, no wait, 6."), "Meet at 6.")
            expectEqual(
                SelfCorrection.resolve("Call Anna. No wait, call Maria."),
                "Call Maria.",
                "replacing the first word keeps a capital"
            )
            expectEqual(
                SelfCorrection.resolve("Tuesday, no wait, Wednesday works."),
                "Tuesday, no wait, Wednesday works.",
                "a correction longer than what it could replace stays as spoken"
            )
        }

        test("cleanup.selfCorrectionOtherLanguages") {
            expectEqual(SelfCorrection.resolve("On se voit lundi, non je veux dire mardi."), "On se voit mardi.")
            expectEqual(SelfCorrection.resolve("Envoie le à Paul, non, je voulais dire à Marc."), "Envoie le à Marc.")
            expectEqual(SelfCorrection.resolve("Nos vemos el lunes, no, espera, el martes."), "Nos vemos el martes.")
            expectEqual(SelfCorrection.resolve("Wir treffen uns am Montag, nein warte, am Dienstag."), "Wir treffen uns am Dienstag.")
            expectEqual(SelfCorrection.resolve("We zien elkaar maandag, nee wacht, dinsdag."), "We zien elkaar dinsdag.")
        }

        test("cleanup.selfCorrectionLeavesAmbiguityAlone") {
            for text in [
                "there is no wait time at the clinic",
                "I said no, wait for me at the door",
                "No wait, it is fine.",
                "Okay, no wait, I will do it later today.",
                "the queue has no wait",
                "je veux dire merci à toute l'équipe",
                "I meant what I said yesterday",
            ] {
                expectEqual(SelfCorrection.resolve(text), text, "unchanged: \(text)")
            }
        }

        test("cleanup.selfCorrectionHandlesRepeats") {
            expectEqual(
                SelfCorrection.resolve("Book it for Monday, no wait, Tuesday. Invite Anna, no wait, Hannah."),
                "Book it for Tuesday. Invite Hannah."
            )
        }
    }

    // MARK: - Acceptance

    private static func cleanupAcceptanceTests() {
        let original = "so um I think we should ship the beta on tuesday after the standup meeting with the design team"

        test("cleanup.acceptsATidy") {
            expectEqual(
                CleanupAcceptance.evaluate(original: original, cleaned: "I think we should ship the beta on Tuesday, after the standup meeting with the design team.", mode: .clean),
                nil
            )
            expectEqual(
                CleanupAcceptance.evaluate(
                    original: "groceries eggs milk um bread and two lemons for the cake tonight",
                    cleaned: "- Eggs\n- Milk\n- Bread\n- Two lemons for the cake tonight",
                    mode: .list
                ),
                nil,
                "a list keeps the words and only adds bullets"
            )
            expectEqual(
                CleanupAcceptance.evaluate(
                    original: "hi sarah thanks for the update um I will send the contract on friday best miguel",
                    cleaned: "Hi Sarah,\n\nThanks for the update. I will send the contract on Friday.\n\nBest,\nMiguel",
                    mode: .email
                ),
                nil
            )
        }

        test("cleanup.rejectsTranslation") {
            let french = "bonjour je voudrais réserver une table pour deux personnes ce soir vers huit heures"
            let rejection = CleanupAcceptance.evaluate(
                original: french,
                cleaned: "Hello, I would like to book a table for two people tonight around eight o'clock.",
                mode: .clean
            )
            expect(rejection == .newWords || rejection == .languageChanged, "a translation is not a cleanup (got \(String(describing: rejection)))")
        }

        test("cleanup.rejectsAnswers") {
            expectEqual(
                CleanupAcceptance.evaluate(
                    original: "what is the capital of france and why does it matter for our trip planning",
                    cleaned: "Sure! The capital of France is Paris, which matters for your trip planning.",
                    mode: .clean
                ),
                .answered
            )
            let answer = CleanupAcceptance.evaluate(
                original: "what is the capital of france and why does it matter for our trip planning",
                cleaned: "The capital of France is Paris. It matters because flights there are cheaper in spring.",
                mode: .clean
            )
            expect(answer != nil, "an answer without an opener is still rejected (got \(String(describing: answer)))")
            expectEqual(
                CleanupAcceptance.evaluate(
                    original: "sure thing we can move the call to thursday afternoon if that works",
                    cleaned: "Sure thing, we can move the call to Thursday afternoon if that works.",
                    mode: .clean
                ),
                nil,
                "a spoken \"sure\" is the user's own word"
            )
        }

        test("cleanup.rejectsLeaksDropsAndDrift") {
            expectEqual(
                CleanupAcceptance.evaluate(original: original, cleaned: "Transcript: I think we should ship the beta on Tuesday after the standup meeting.", mode: .clean),
                .promptLeak
            )
            expectEqual(
                CleanupAcceptance.evaluate(original: original, cleaned: "We ship the beta Tuesday after standup with design.", mode: .clean),
                .droppedWords
            )
            expectEqual(CleanupAcceptance.evaluate(original: original, cleaned: "Ship it.", mode: .clean), .lengthDrift)
            expectEqual(CleanupAcceptance.evaluate(original: original, cleaned: " \n", mode: .clean), .empty)
            expectEqual(CleanupAcceptance.evaluate(original: "", cleaned: "anything", mode: .clean), .empty)
            expect(!LLMCleaner.accept(original: original, cleaned: "Ship it."), "the legacy entry point uses the same guard")
        }

        test("cleanup.languageCheck") {
            expectEqual(CleanupAcceptance.dominantLanguage("Je voudrais réserver une table pour deux personnes ce soir, s'il vous plaît."), .french)
            expectEqual(CleanupAcceptance.dominantLanguage("I would like to book a table for two people tonight, please."), .english)
            expect(
                CleanupAcceptance.languageChanged(
                    from: "Je voudrais réserver une table pour deux personnes ce soir, s'il vous plaît.",
                    to: "I would like to book a table for two people tonight, please.",
                    wordCount: 14
                ),
                "French in, English out is a language change"
            )
            expect(!CleanupAcceptance.languageChanged(from: "ok", to: "fine", wordCount: 1), "short text is never judged")
        }

        test("cleanup.rejectionReasonsArePlain") {
            for rejection in [CleanupRejection.empty, .lengthDrift, .newWords, .droppedWords, .languageChanged, .answered, .promptLeak] {
                expect(!rejection.reason.isEmpty && !rejection.reason.contains("\u{2014}"), "\(rejection) has a plain reason")
            }
        }
    }

    // MARK: - One run, with a fake runtime

    private final class RunRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [CleanupInvocation] = []
        func record(_ invocation: CleanupInvocation) {
            lock.lock(); stored.append(invocation); lock.unlock()
        }
        var invocations: [CleanupInvocation] {
            lock.lock(); defer { lock.unlock() }
            return stored
        }
    }

    private static func fakeEnvironment(
        binary: String? = "/Applications/YappYapp.app/Contents/Resources/bin/llama-completion",
        modelReady: Bool = true,
        recorder: RunRecorder,
        result: @escaping @Sendable (CleanupInvocation) -> CleanupRunResult
    ) -> CleanupEnvironment {
        CleanupEnvironment(
            binaryPath: { _ in binary },
            modelReady: { modelReady },
            modelPath: { "/tmp/qwen.gguf" },
            run: { invocation in
                recorder.record(invocation)
                return result(invocation)
            }
        )
    }

    private static func cleanupRunTests() {
        let spoken = "so um I think we should ship the beta on monday no wait on tuesday after the standup meeting"

        test("cleanup.verbatimNeverRunsTheModel") {
            let recorder = RunRecorder()
            let result = LLMCleaner.cleanup(text: spoken, mode: .verbatim, environment: fakeEnvironment(recorder: recorder) { _ in .timedOut })
            expectEqual(result, CleanupResult(text: spoken, outcome: .skipped))
            expect(recorder.invocations.isEmpty, "Verbatim must not start llama.cpp")
            let short = LLMCleaner.cleanup(text: "send it now", mode: .clean, environment: fakeEnvironment(recorder: recorder) { _ in .timedOut })
            expectEqual(short.outcome, .skipped, "short dictations skip the model load")
            expect(recorder.invocations.isEmpty, "a skipped run starts nothing")
        }

        test("cleanup.missingPiecesFallBackHonestly") {
            let recorder = RunRecorder()
            let noRuntime = LLMCleaner.cleanup(text: spoken, mode: .clean, environment: fakeEnvironment(binary: nil, recorder: recorder) { _ in .launchFailed })
            expectEqual(noRuntime, CleanupResult(text: spoken, outcome: .fellBack(.runtimeMissing)))
            let noModel = LLMCleaner.cleanup(text: spoken, mode: .clean, environment: fakeEnvironment(modelReady: false, recorder: recorder) { _ in .launchFailed })
            expectEqual(noModel, CleanupResult(text: spoken, outcome: .fellBack(.modelMissing)))
            expect(recorder.invocations.isEmpty, "nothing runs without runtime and verified model")
        }

        test("cleanup.timeoutAndErrorsReturnRawText") {
            let recorder = RunRecorder()
            let timedOut = LLMCleaner.cleanup(text: spoken, mode: .clean, environment: fakeEnvironment(recorder: recorder) { _ in .timedOut })
            expectEqual(timedOut, CleanupResult(text: spoken, outcome: .fellBack(.timedOut)))
            let crashed = LLMCleaner.cleanup(text: spoken, mode: .clean, environment: fakeEnvironment(recorder: recorder) { _ in .finished(status: 1, output: "Ship it on Tuesday.") })
            expectEqual(crashed, CleanupResult(text: spoken, outcome: .fellBack(.failed)))
            let launch = LLMCleaner.cleanup(text: spoken, mode: .clean, environment: fakeEnvironment(recorder: recorder) { _ in .launchFailed })
            expectEqual(launch.outcome, .fellBack(.failed))
            expectEqual(launch.text, spoken)
            if let timeout = recorder.invocations.first?.timeout {
                expect(timeout >= 8 && timeout <= 20, "hard timeout stays between 8 and 20 seconds (\(timeout))")
            } else {
                expect(false, "the runner was not called")
            }
        }

        test("cleanup.cleanedOutputReplacesTranscript") {
            let recorder = RunRecorder()
            let result = LLMCleaner.cleanup(
                text: spoken,
                mode: .clean,
                protectedTerms: ["YappYapp"],
                environment: fakeEnvironment(recorder: recorder) { _ in
                    .finished(status: 0, output: "I think we should ship the beta on Tuesday, after the standup meeting. [end of text]\n")
                }
            )
            expectEqual(result, CleanupResult(text: "I think we should ship the beta on Tuesday, after the standup meeting.", outcome: .cleaned))
            guard let invocation = recorder.invocations.first else {
                expect(false, "the runner was not called")
                return
            }
            expect(invocation.input.contains("ship the beta on tuesday after the standup"), "the correction is applied before the model sees the text")
            expect(!invocation.input.contains("monday"), "the corrected-away word never reaches the model")
            expect(invocation.input.contains("Protected spellings: YappYapp"), "glossary terms travel on stdin")
            let joined = invocation.arguments.joined(separator: " ")
            expect(!joined.contains("standup") && !joined.contains("YappYapp"), "no user text in argv")
            expect(!invocation.arguments.contains("--log-disable"), "llama-completion would print nothing with --log-disable")
            expect(joined.contains("-c 4096"), "context is capped")
            expect(joined.contains("-m /tmp/qwen.gguf"), "the verified model path is used")
        }

        test("cleanup.rejectedOutputReturnsRawText") {
            let recorder = RunRecorder()
            let result = LLMCleaner.cleanup(
                text: "bonjour je voudrais réserver une table pour deux personnes ce soir vers huit heures",
                mode: .clean,
                environment: fakeEnvironment(recorder: recorder) { _ in
                    .finished(status: 0, output: "Hello, I would like to book a table for two people tonight around eight o'clock.")
                }
            )
            expectEqual(result.text, "bonjour je voudrais réserver une table pour deux personnes ce soir vers huit heures")
            if case .fellBack(.rejected) = result.outcome {
                expect(true, "translation rejected")
            } else {
                expect(false, "translation should be rejected, got \(result.outcome)")
            }
        }

        test("cleanup.listModeShapesBullets") {
            let recorder = RunRecorder()
            let result = LLMCleaner.cleanup(
                text: "groceries eggs milk um bread and two lemons for the cake tonight",
                mode: .list,
                environment: fakeEnvironment(recorder: recorder) { _ in
                    .finished(status: 0, output: "* Eggs\n\u{2022} Milk\n\n- Bread\n- Two lemons for the cake tonight\n")
                }
            )
            expectEqual(result.outcome, .cleaned)
            expectEqual(result.text, "- Eggs\n- Milk\n- Bread\n- Two lemons for the cake tonight")
            let prompt = recorder.invocations.first.flatMap { invocation in
                invocation.arguments.firstIndex(of: "-sys").map { invocation.arguments[$0 + 1] }
            } ?? ""
            expect(prompt.contains("one item per line"), "list mode sends the list rules")
        }

        test("cleanup.cliRuntimeKeepsItsParser") {
            let recorder = RunRecorder()
            let output = """
            Loading model...
            build      : b11429-d81235049

            > so um I think we should ship the beta on tuesday after the standup meeting

            I think we should ship the beta on Tuesday, after the standup meeting.

            [ Prompt: 611.8 t/s | Generation: 180.9 t/s ]

            Exiting...
            """
            let result = LLMCleaner.cleanup(
                text: spoken,
                mode: .clean,
                environment: fakeEnvironment(binary: "/opt/homebrew/bin/llama-cli", recorder: recorder) { _ in
                    .finished(status: 0, output: output)
                }
            )
            expectEqual(result.outcome, .cleaned)
            expectEqual(result.text, "I think we should ship the beta on Tuesday, after the standup meeting.")
            expect(recorder.invocations.first?.arguments.contains("--log-disable") == true, "llama-cli keeps logging off")
        }

        test("cleanup.fallbackCopy") {
            let fallbacks: [CleanupFallback] = [.runtimeMissing, .modelMissing, .timedOut, .failed, .rejected(.newWords)]
            for fallback in fallbacks {
                expect(fallback.message.hasPrefix("Kept your words as spoken"), "\(fallback) says the text went out as spoken")
                expect(fallback.hudNote.hasPrefix("AS SPOKEN"), "\(fallback) HUD note starts with AS SPOKEN")
                expect(!fallback.message.lowercased().contains("raw"), "\(fallback) never says raw")
                expect(!fallback.message.contains("\u{2014}"), "\(fallback) copy has no em dash")
            }
            expectEqual(
                HUDPresenter.caption(for: .transcribing, escCancels: true, countdown: nil, note: CleanupMode.notes.hudNote),
                "CLEANING UP · NOTES",
                "the HUD shows the CLEANING phase over the processing sweep"
            )
        }

        test("cleanup.budgets") {
            expectEqual(LLMCleaner.hardTimeout(for: "one two three"), 8 + 3.0 / 25)
            expectEqual(LLMCleaner.hardTimeout(for: String(repeating: "word ", count: 2_000)), 20)
            expectEqual(LLMCleaner.tokenBudget(for: "short"), 128)
            expectEqual(LLMCleaner.tokenBudget(for: String(repeating: "x", count: 10_000)), 2_048)
        }
    }

    // MARK: - Runtime and prompts

    private static func cleanupRuntimeTests() {
        test("cleanup.runtimeKinds") {
            expectEqual(LLMCleaner.Runtime.of(binaryPath: "/Applications/YappYapp.app/Contents/Resources/bin/llama-completion"), .completion)
            expectEqual(LLMCleaner.Runtime.of(binaryPath: "/opt/homebrew/bin/llama-cli"), .cli)
            expectEqual(LLMCleaner.bundledBinaryPath, nil, "the CLI test process is not an app bundle")
        }

        test("cleanup.bundledRuntimeComesFirst") {
            let bundled = "/Applications/YappYapp.app/Contents/Resources/bin/llama-completion"
            expectEqual(
                LLMCleaner.binaryCandidates(configured: LLMCleaner.stockBinaryPath, bundledPath: bundled),
                [bundled, "/opt/homebrew/bin/llama-cli", "/usr/local/bin/llama-cli"],
                "bundled runtime first, Homebrew only as the fallback"
            )
            expectEqual(
                LLMCleaner.binaryCandidates(configured: "/Users/me/llama/llama-cli", bundledPath: bundled),
                ["/Users/me/llama/llama-cli"],
                "a chosen path still never falls back"
            )
        }

        test("cleanup.modePrompts") {
            expectEqual(
                LLMCleaner.systemPrompt(mode: .clean, protectedTerms: ["LUMEX"]),
                LLMCleaner.systemPrompt(protectedTerms: ["LUMEX"]),
                "Clean keeps the tuned prompt exactly"
            )
            for mode in [CleanupMode.email, .list, .notes] {
                let prompt = LLMCleaner.systemPrompt(mode: mode, protectedTerms: [])
                expect(!prompt.lowercased().contains("example"), "\(mode) prompt has no examples")
                expect(prompt.contains("SAME language"), "\(mode) prompt pins the language")
                expect(prompt.contains("Never answer questions"), "\(mode) prompt forbids answers")
                expect(prompt.contains("translate"), "\(mode) prompt forbids translation")
                expect(prompt.contains("Protected spellings"), "\(mode) prompt defines protected spellings")
                expect(!prompt.contains("\u{2014}"), "\(mode) prompt has no em dash")
                let withTerms = LLMCleaner.systemPrompt(mode: mode, protectedTerms: ["YappYapp"])
                expect(withTerms.contains("Protected spellings: YappYapp."), "\(mode) prompt carries glossary terms")
            }
            expect(LLMCleaner.systemPrompt(mode: .email, protectedTerms: []).contains("email body"), "email rules")
            expect(LLMCleaner.systemPrompt(mode: .notes, protectedTerms: []).contains("Keep every fact"), "notes keep facts")
        }

        test("cleanup.bulletNormalization") {
            expectEqual(LLMCleaner.normalizeBullets("* one\n  \u{2022} two\n\n\u{2013} three\n- four"), "- one\n- two\n- three\n- four")
            expectEqual(LLMCleaner.finish("okay so that is it.", mode: .clean), "Okay so that is it.")
        }

        test("cleanup.processRunnerRealProcess") {
            let echo = LLMCleaner.runProcess(CleanupInvocation(binaryPath: "/bin/cat", arguments: [], input: "hello from stdin", timeout: 5))
            expectEqual(echo, .finished(status: 0, output: "hello from stdin"), "input travels over stdin")
            let started = Date()
            let slow = LLMCleaner.runProcess(CleanupInvocation(binaryPath: "/bin/sleep", arguments: ["10"], input: "", timeout: 0.5))
            expectEqual(slow, .timedOut, "the hard timeout stops a slow helper")
            expect(Date().timeIntervalSince(started) < 4, "the timeout returns promptly")
            let missing = LLMCleaner.runProcess(CleanupInvocation(binaryPath: "/nonexistent/llama-completion", arguments: [], input: "x", timeout: 1))
            expectEqual(missing, .launchFailed)
            let early = LLMCleaner.runProcess(CleanupInvocation(
                binaryPath: "/usr/bin/true",
                arguments: [],
                input: String(repeating: "x", count: 200_000),
                timeout: 5
            ))
            expectEqual(early, .finished(status: 0, output: ""), "a helper that exits without reading cannot crash the app")
        }
    }

    // MARK: - Model on disk

    private static func cleanupModelStoreTests() {
        test("cleanup.installVerifiesAndStamps") {
            try withTemporaryApplicationSupportBase { base in
                let models = base.appendingPathComponent("models", isDirectory: true)
                try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
                let model = models.appendingPathComponent("model.gguf")
                let stamp = models.appendingPathComponent(".model.verified.json")
                let staged = models.appendingPathComponent("model.gguf.download")
                try Data("pretend weights".utf8).write(to: staged)

                try CleanupModelStore.install(downloadedFile: staged, modelURL: model, stampURL: stamp, expectedSHA1: "abc123", sha1: { _ in "ABC123" })
                expect(FileManager.default.fileExists(atPath: model.path), "verified download is installed")
                expect(!FileManager.default.fileExists(atPath: staged.path), "staging file is moved")
                expect(CleanupModelStore.isVerified(modelURL: model, stampURL: stamp, expectedSHA1: "abc123"), "stamp marks the model verified")
                expect(!CleanupModelStore.isVerified(modelURL: model, stampURL: stamp, expectedSHA1: "fff000"), "a different pin is not verified")

                try Data("tampered weights, longer".utf8).write(to: model)
                expect(!CleanupModelStore.isVerified(modelURL: model, stampURL: stamp, expectedSHA1: "abc123"), "a changed file loses its stamp")
            }
        }

        test("cleanup.badChecksumNeverInstalls") {
            try withTemporaryApplicationSupportBase { base in
                let model = base.appendingPathComponent("model.gguf")
                let stamp = base.appendingPathComponent(".model.verified.json")
                let staged = base.appendingPathComponent("model.gguf.download")
                try Data("wrong".utf8).write(to: staged)
                do {
                    try CleanupModelStore.install(downloadedFile: staged, modelURL: model, stampURL: stamp, expectedSHA1: "abc123", sha1: { _ in "999999" })
                    expect(false, "a checksum mismatch must throw")
                } catch let error as CleanupModelError {
                    expectEqual(error, .checksumMismatch(expected: "abc123", actual: "999999"))
                }
                expect(!FileManager.default.fileExists(atPath: model.path), "nothing installed")
                expect(!FileManager.default.fileExists(atPath: staged.path), "the bad download is deleted")
                expect(!CleanupModelStore.isVerified(modelURL: model, stampURL: stamp, expectedSHA1: "abc123"), "not verified")
            }
        }

        test("cleanup.verifyExistingStampsOldInstalls") {
            try withTemporaryApplicationSupportBase { base in
                let model = base.appendingPathComponent("model.gguf")
                let stamp = base.appendingPathComponent(".model.verified.json")
                try Data("old install".utf8).write(to: model)
                expect(!CleanupModelStore.isVerified(modelURL: model, stampURL: stamp, expectedSHA1: "abc123"), "no stamp yet")
                expect(!(try CleanupModelStore.verifyExisting(modelURL: model, stampURL: stamp, expectedSHA1: "abc123", sha1: { _ in "nope" })), "wrong file is not stamped")
                expect(try CleanupModelStore.verifyExisting(modelURL: model, stampURL: stamp, expectedSHA1: "abc123", sha1: { _ in "abc123" }), "pinned file is stamped")
                expect(CleanupModelStore.isVerified(modelURL: model, stampURL: stamp, expectedSHA1: "abc123"), "stamped")
                let realSHA1 = try ModelIntegrity.sha1Hex(for: model)
                expect(try CleanupModelStore.verifyExisting(modelURL: model, stampURL: stamp, expectedSHA1: realSHA1), "the real hash path works")
            }
        }

        test("cleanup.pathsStayInModelsDirectory") {
            try withTemporaryApplicationSupportBase { base in
                expect(CleanupModelStore.stampURL.path.hasPrefix(base.path), "stamp follows the support override")
                expect(CleanupModelStore.stagingURL.path.hasPrefix(base.path), "staging follows the support override")
                expect(!CleanupModelStore.isVerified(), "an empty support folder has no verified model")
            }
        }

        test("cleanup.downloaderReportsPercentSteps") {
            expect(CleanupModelDownloader.shouldReport(percent: 1, last: 0), "new percent reports")
            expect(!CleanupModelDownloader.shouldReport(percent: 1, last: 1), "same percent is quiet")
            expectEqual(CleanupModelError.canceled.errorDescription, "Cleanup model download canceled.")
        }
    }

    // MARK: - What Setup says

    private static func cleanupReadinessTests() {
        test("cleanup.readinessGatesTheDownload") {
            func evaluate(
                _ mode: CleanupMode,
                runtime: Bool,
                verified: Bool,
                downloads: Bool = true,
                phase: CleanupDownloadPhase = .idle
            ) -> CleanupReadiness {
                CleanupReadiness.evaluate(mode: mode, runtimeAvailable: runtime, modelVerified: verified, downloadsAllowed: downloads, download: phase)
            }
            expectEqual(evaluate(.verbatim, runtime: false, verified: false), .off)
            expectEqual(evaluate(.clean, runtime: false, verified: false), .needsRuntime)
            expectEqual(evaluate(.clean, runtime: false, verified: true), .needsRuntime, "a model without the runtime is not ready")
            expect(!evaluate(.clean, runtime: false, verified: false).canDownload, "no runtime, no download")
            expectEqual(evaluate(.email, runtime: true, verified: false), .needsModel(downloadsAllowed: true))
            expect(evaluate(.email, runtime: true, verified: false).canDownload, "runtime present: the model can download")
            expect(!evaluate(.email, runtime: true, verified: false, downloads: false).canDownload, "downloads off: no download button")
            expectEqual(evaluate(.list, runtime: true, verified: false, phase: .downloading(fraction: 0.42)), .downloading(fraction: 0.42))
            expect(evaluate(.list, runtime: true, verified: false, phase: .downloading(fraction: 0.42)).canCancel, "a download can be canceled")
            expectEqual(evaluate(.notes, runtime: true, verified: false, phase: .verifying), .verifying)
            expectEqual(evaluate(.clean, runtime: true, verified: true, phase: .downloading(fraction: 0.1)), .ready)
            expect(evaluate(.clean, runtime: true, verified: false, phase: .failed("x")).canDownload, "a failed download can retry")
        }

        test("cleanup.readinessCopy") {
            expectEqual(CleanupReadiness.needsRuntime.headline, "THIS COPY CAN'T RUN CLEANUP")
            expect(CleanupReadiness.needsRuntime.detail.hasPrefix("This copy of YappYapp can't run cleanup"), "runtime copy")
            expectEqual(CleanupReadiness.ready.headline, "CLEANUP MODEL READY")
            expectEqual(CleanupReadiness.ready.detail, "Cleanup model ready.")
            expectEqual(CleanupReadiness.downloading(fraction: 0.427).headline, "DOWNLOADING 42%")
            expectEqual(CleanupReadiness.downloading(fraction: nil).headline, "DOWNLOADING")
            let all: [CleanupReadiness] = [
                .off, .needsRuntime, .needsModel(downloadsAllowed: true), .needsModel(downloadsAllowed: false),
                .downloading(fraction: 0.5), .verifying, .failed("Cleanup model download failed."), .ready,
            ]
            for readiness in all {
                expect(!readiness.headline.contains("\u{2014}") && !readiness.detail.contains("\u{2014}"), "\(readiness) copy has no em dash")
            }
        }

        test("cleanup.settingsControlRenders") {
            for readiness in [CleanupReadiness.needsRuntime, .downloading(fraction: 0.3), .ready, .failed("Cleanup model download failed.")] {
                let view = CleanupSettingsControl(
                    mode: .constant(.email),
                    readiness: readiness,
                    onDownload: {},
                    onCancel: {}
                )
                .padding(12)
                .background(Brutal.paper)
                expect(renderImage(view, width: 400, height: 200) != nil, "\(readiness) renders")
            }
        }
    }
}
#endif
