#if DEBUG
import Foundation

// QWEN3-ASR: self-tests for the third speech engine. Pure rules only; the
// latency harness (--qwen3asr-latency) covers the real model.
extension SelfTests {
    static func qwen3ASRTests() {
        test("engines.qwen3asr.catalog") {
            let qwen = ModelCatalog.options.filter { $0.engine == .qwen3asr }
            expectEqual(qwen.map(\.id), ["qwen3asr-0.6b", "qwen3asr-1.7b"])
            expectEqual(qwen.map(\.defaultPath), ["qwen3asr://0.6b", "qwen3asr://1.7b"])
            for option in qwen {
                expectEqual(ModelCatalog.engine(for: option.defaultPath), ModelEngine.qwen3asr)
                expectEqual(ModelCatalog.selectedID(for: option.defaultPath), option.id)
                expectEqual(option.downloadBytes, option.qwen3Variant?.downloadBytes)
            }
            let lastWhisper = ModelCatalog.options.lastIndex { $0.engine == .whisper }
            let firstQwen = ModelCatalog.options.firstIndex { $0.engine == .qwen3asr }
            expect(lastWhisper != nil && firstQwen != nil && lastWhisper! < firstQwen!, "Qwen3-ASR renders after Whisper")
            expectEqual(ModelGroup.qwen3asr.title(count: 2), "QWEN3-ASR (2)")
            expect(ModelGroup.qwen3asr.detail.count <= 32, "the header subtitle stays one line")
        }

        test("engines.qwen3asr.privacy") {
            // The recording and glossary travel in the request body; argv
            // carries only file paths and fixed flags.
            let arguments = Qwen3ASRCLI.arguments(
                variant: .large,
                modelURL: Qwen3ASRModelStore.modelURL(.large),
                projectorURL: Qwen3ASRModelStore.projectorURL(.large),
                audioPath: "/tmp/yappyapp-a.wav",
                maxTokens: 64
            )
            // WORDS-AS-HINTS: the prompt (context, audio marker, prefill)
            // comes from stdin; argv holds only the fixed chat template.
            expectEqual(arguments.firstIndex(of: "-f").map { arguments[$0 + 1] }, "/dev/stdin")
            expect(!arguments.contains("-p") && !arguments.contains("-sys") && !arguments.contains("--system-prompt"), "no context in argv")
            expectEqual(arguments.firstIndex(of: "--chat-template").map { arguments[$0 + 1] }, Qwen3ASRCLI.chatTemplate)
            let glossary = Glossary(entries: [GlossaryEntry(canonical: "Kvellio", variants: [], notes: nil)], lexicon: StaticWordLexicon([]))
            expect(!arguments.joined(separator: " ").contains("Kvellio"), "the user's words never reach argv")
            let prompt = Qwen3ASRCLI.stdinPrompt(context: Qwen3ASRPrompt.context(glossary: glossary), prefill: "language French<asr_text>")
            expectEqual(prompt.components(separatedBy: Qwen3ASRCLI.partSeparator), ["Kvellio", "<__media__>", "language French<asr_text>"])
            let server = LlamaServerPolicy.launchArguments(model: "/m", contextTokens: 8_192, port: 1, apiPrefix: "/x", projector: "/p")
            expect(server.contains("--log-disable") && server.contains("--no-webui"), "the warm server logs nothing and has no UI")
            expectEqual(server[server.firstIndex(of: "--host")! + 1], "127.0.0.1")
        }

        test("engines.qwen3asr.outputGuards") {
            expectEqual(Qwen3ASRPrompt.transcript(fromReply: "language None<asr_text>"), "")
            expectEqual(Qwen3ASRPrompt.transcript(fromReply: "language Japanese<asr_text>明日の朝9時"), "明日の朝9時")
            expectEqual(Qwen3ASRPrompt.collapsingRepetitions(String(repeating: "あ", count: 50)), "あ")
            expectEqual(Qwen3ASRPrompt.assistantPrefill(language: "auto"), nil)
            expectEqual(Qwen3ASRPrompt.assistantPrefill(language: "nl"), "language Dutch<asr_text>")
            // The silence hallucination guard applies to Qwen3-ASR output too.
            expectEqual(WhisperOutputGuard.verdict(output: "Thank you.", prompt: "", nearSilence: true), .dropHallucination)
            expectEqual(WhisperOutputGuard.verdict(output: "Genial, YappYapp", prompt: "Genial, YappYapp", nearSilence: false), .dropPromptEcho)
        }

        test("engines.qwen3asr.serverPolicy") {
            var config = AppConfig.defaultConfig
            config.modelPath = Qwen3ASRVariant.small.modelPath
            config.keepModelWarm = true
            let launch = Qwen3ASRServerPolicy.launch(
                config: config,
                runtimeBinary: "/A.app/Contents/Resources/bin/llama-completion",
                modelVerified: { _ in true },
                memoryPressureCritical: false,
                launchable: { $0 }
            )
            expectEqual(launch?.projector, Qwen3ASRModelStore.projectorURL(.small).path)
            config.modelPath = "parakeet://v3"
            expect(Qwen3ASRServerPolicy.launch(
                config: config,
                runtimeBinary: "/A.app/Contents/Resources/bin/llama-completion",
                modelVerified: { _ in true },
                memoryPressureCritical: false,
                launchable: { $0 }
            ) == nil, "no speech server for another engine")
            expectEqual(
                Qwen3ASRRuntime.cliBinaryPath(forRuntimeBinary: "/A.app/Contents/Resources/bin/llama-completion"),
                "/A.app/Contents/Resources/bin/llama-mtmd-cli"
            )
            expect(Qwen3ASRAudioParts.isPlainMono16kWAV(Qwen3ASRServerPolicy.silentWAV(seconds: 0.5)), "the warm-up clip is a plain WAV")
        }
    }
}
#endif
