#if DEBUG
import Foundation

// Self-tests owned by the "models" track (round 2): translation targets and
// models, config migration, and the SCAN MY MAC rules. Keep this track's
// assertions here so parallel tracks never edit the same test lines.
extension SelfTests {
    static func modelsTrackTests() {
        test("models.translationMigratesLegacySwitch") {
            let core = #""whisperBinaryPath":"/usr/local/bin/whisper-cli","language":"auto","additionalPrompt":"","maxRecordingSeconds":300,"restoreClipboardAfterPaste":true,"pasteWhenFocusIsUnclear":true"#
            let whisperOn = try JSONDecoder().decode(AppConfig.self, from: Data("{\(core),\"modelPath\":\"/tmp/ggml-large-v3-turbo.bin\",\"translateToEnglish\":true}".utf8))
            expectEqual(whisperOn.translation, .en)
            expectEqual(whisperOn.translationModelID, .whisperBuiltIn, "Whisper keeps its built-in translate")
            expect(whisperOn.whisperTranslates, "Whisper still gets -tr")
            expect(whisperOn.translateToEnglish, "older builds still read the switch as on")

            let parakeetOn = try JSONDecoder().decode(AppConfig.self, from: Data("{\(core),\"modelPath\":\"parakeet://v3\",\"translateToEnglish\":true}".utf8))
            expectEqual(parakeetOn.translation, .en)
            expectEqual(parakeetOn.translationModelID, TranslationCatalog.defaultModelID, "Parakeet moves to the default translation model")
            expect(!parakeetOn.whisperTranslates, "Parakeet never gets -tr")

            let off = try JSONDecoder().decode(AppConfig.self, from: Data("{\(core),\"modelPath\":\"parakeet://v3\",\"translateToEnglish\":false}".utf8))
            expectEqual(off.translation, .off)
        }

        test("models.translationRecoveryKeepsTargets") {
            let data = Data(#"{"whisperBinaryPath":"/usr/local/bin/whisper-cli","modelPath":"parakeet://v3","language":"auto","additionalPrompt":"","maxRecordingSeconds":300,"restoreClipboardAfterPaste":true,"pasteWhenFocusIsUnclear":true,"translateTarget":"ja","translationModel":"hy-mt2-7b","playSounds":"loud"}"#.utf8)
            let outcome = ConfigRecovery.decode(data: data, installDefaults: AppConfig.defaultConfig, lastSaved: { nil })
            expect(outcome.isDamaged, "a wrong-typed key is damage")
            expectEqual(outcome.config.translation, .ja, "a damaged file keeps its translation target")
            expectEqual(outcome.config.translationModelID, .hyMT2Best)
        }

        test("models.translationPlanRoutes") {
            expectEqual(TranslationPlan.make(target: .off, chosen: .hyMT2Fast, engine: .parakeet).route, .off)
            expectEqual(TranslationPlan.make(target: .en, chosen: .whisperBuiltIn, engine: .whisper).route, .whisperBuiltIn)
            let substituted = TranslationPlan.make(target: .fr, chosen: .whisperBuiltIn, engine: .whisper)
            expectEqual(substituted.route, .model(.hyMT2Fast), "Whisper cannot do French")
            expect(substituted.substitutedForWhisper, "the caption says Whisper was replaced")
            expectEqual(TranslationPlan.make(target: .en, chosen: .whisperBuiltIn, engine: .parakeet).route, .model(.hyMT2Fast))
            expectEqual(TranslationPlan.make(target: .ko, chosen: .hyMT2Best, engine: .parakeet).route, .model(.hyMT2Best))
        }

        test("models.translationPromptUsesModelCardTemplate") {
            let prompt = TranslationPrompt.make(text: "Bonjour", target: .en, protectedTerms: [])
            expect(prompt.hasPrefix("Translate the following text into English. Note that you should only output the translated result without any additional explanation:\n\n"), prompt)
            expect(prompt.hasSuffix("Bonjour"), "the text comes last")
            let terms = TranslationPrompt.make(text: "hola", target: .fr, protectedTerms: ["YappYapp"])
            expect(terms.hasPrefix("Reference the following translations:\nYappYapp translates to YappYapp"), terms)
        }

        test("models.translationArgsKeepTextOffArgv") {
            let job = TranslationJob(binaryPath: "/x/llama-completion", modelPath: "/m.gguf", prompt: "Translate PrivateClientName", maxTokens: 300, timeout: 10)
            let args = OneShotLlamaTranslationEngine.arguments(for: job, runtime: .completion)
            expect(!args.joined(separator: " ").contains("PrivateClientName"), "the transcript never enters argv")
            expect(args.contains("/dev/stdin"), "prompt comes from stdin")
            expect(!args.contains("-sys"), "Hy-MT2 has no system prompt")
        }

        test("models.translationFallsBackWithReason") {
            let plan = TranslationPlan.make(target: .es, chosen: .hyMT2Fast, engine: .parakeet)
            func environment(ready: Bool, reply: TranslationJobResult) -> TranslationEnvironment {
                struct Fixed: TranslationEngine {
                    let reply: TranslationJobResult
                    func complete(_ job: TranslationJob) -> TranslationJobResult { reply }
                }
                return TranslationEnvironment(binaryPath: { _ in "/x/llama-completion" }, modelReady: { _ in ready },
                                              modelPath: { _ in "/m.gguf" }, engine: Fixed(reply: reply))
            }
            let missing = Translator.translate(text: "hello there", plan: plan, environment: environment(ready: false, reply: .failed))
            expectEqual(missing, TranslationResult(text: "hello there", outcome: .fellBack(.modelMissing)))
            let slow = Translator.translate(text: "hello there", plan: plan, environment: environment(ready: true, reply: .timedOut))
            expectEqual(slow.text, "hello there", "a timeout never drops the dictation")
            let ok = Translator.translate(text: "hello there", plan: plan, environment: environment(ready: true, reply: .finished("hola")))
            expectEqual(ok, TranslationResult(text: "hola", outcome: .translated))
            let empty = Translator.translate(text: "hello there", plan: plan, environment: environment(ready: true, reply: .finished("  ")))
            expectEqual(empty.outcome, .fellBack(.failed))
            let same = Translator.translate(text: "hola", plan: plan, dictationLanguage: "es", environment: environment(ready: true, reply: .finished("x")))
            expectEqual(same.outcome, .skipped, "dictating in the target language runs nothing")
        }

        test("models.scanOwnersMac") {
            let m5Pro = HardwareProfile(chipName: "Apple M5 Pro", modelIdentifier: "Mac17,7", memoryBytes: 48 << 30,
                                        macOSVersion: "26.1", freeDiskBytes: 210_000_000_000, onBattery: false)
            expectEqual(m5Pro.summaryLine, "M5 Pro · 48 GB · macOS 26.1 · 210 GB free")
            let picks = ModelAdvisor.recommend(for: m5Pro)
            expectEqual(picks.map(\.choice), [.speech(modelID: "parakeet-ultra"), .cleanup(.clean), .translation(.hyMT2Best)])
        }

        test("models.groupHeadersAreShort") {
            for group in [ModelGroup.parakeet, .whisper, .qwen3asr, .translation] {
                expect(group.detail.count <= 32, "\(group.detail) must stay one line")
            }
            expectEqual(ModelGroup.whisper.detail, "MORE LANGUAGES")
        }
    }
}
#endif
