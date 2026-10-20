#if DEBUG
import Foundation

// Self-tests owned by the "engines" work track. Keep this track's new
// assertions here so parallel tracks never edit the same test lines.
extension SelfTests {
    static func enginesTrackTests() {
        enginesFillerTests()
        enginesGlossaryTests()
        enginesWhisperPrivacyTests()
        enginesOutputGuardTests()
        enginesTimeoutAndRetryTests()
        enginesServerHardeningTests()
        enginesParakeetTests()
        qwen3ASRTests()
        learnFromFixesTests()
    }

    /// Scratch space under the self-test base when one is set, so these
    /// tests never write next to real user data.
    private static func enginesScratchDirectory() throws -> URL {
        let base = ProcessInfo.processInfo.environment["YAPPYAPP_APP_SUPPORT_BASE"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("engines-selftest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func posixPermissions(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber)?.intValue ?? -1
    }

    // MARK: - YA-47 fillers

    private static func enginesFillerTests() {
        test("engines.fillers.sentenceEndKeepsOneMark") {
            expectEqual(FillerWords.removing(from: "I think um."), "I think.")
            expectEqual(FillerWords.removing(from: "I think, um..."), "I think...")
            expectEqual(FillerWords.removing(from: "Bon, euh."), "Bon.")
            expectEqual(FillerWords.removing(from: "Is it ready uh?"), "Is it ready?")
        }

        test("engines.fillers.noLeadingPunctuation") {
            expectEqual(FillerWords.removing(from: "Um. So we start."), "So we start.")
            expectEqual(FillerWords.removing(from: "Uh, ok."), "Ok.")
        }

        test("engines.fillers.capitalizesNewSentenceStart") {
            expectEqual(FillerWords.removing(from: "um hello there"), "Hello there")
            expectEqual(FillerWords.removing(from: "Done. uh, then we go."), "Done. Then we go.")
            expectEqual(FillerWords.removing(from: "First.\num second line"), "First.\nSecond line")
        }

        test("engines.fillers.midSentenceKeepsCase") {
            expectEqual(FillerWords.removing(from: "I was like, um, you know"), "I was like, you know")
            expectEqual(FillerWords.removing(from: "I said um, uh, no."), "I said no.")
        }

        test("engines.fillers.keepsHyphenatedAndApostropheWords") {
            expectEqual(FillerWords.removing(from: "Uh-oh, that broke."), "Uh-oh, that broke.")
            expectEqual(FillerWords.removing(from: "She said uh-huh to it."), "She said uh-huh to it.")
            expectEqual(FillerWords.removing(from: "Hmm'd twice"), "Hmm'd twice")
        }

        test("engines.fillers.allCapsIsAnAcronym") {
            expectEqual(FillerWords.removing(from: "The UM campus opens today."), "The UM campus opens today.")
            expectEqual(FillerWords.removing(from: "UH and UM merged."), "UH and UM merged.")
            // Sentence-case fillers still go.
            expectEqual(FillerWords.removing(from: "Um the UM campus."), "The UM campus.")
        }

        test("engines.fillers.realEllipsisSurvives") {
            expectEqual(FillerWords.removing(from: "Wait... no."), "Wait... no.")
            expectEqual(FillerWords.removing(from: "Wait... um no."), "Wait... no.")
        }
    }

    // MARK: - YA-36 / YA-52 glossary

    private static func enginesGlossaryTests() {
        test("engines.glossary.shortVariantFires") {
            let glossary = Glossary(entries: [GlossaryEntry(canonical: "GPT", variants: ["jpt", "gp"], notes: nil)])
            expectEqual(glossary.applyingCorrections(to: "ask jpt now"), "ask GPT now")
            expectEqual(glossary.applyingCorrections(to: "Jpt, then gp."), "GPT, then GPT.")
        }

        test("engines.glossary.shortVariantRespectsWordBoundaries") {
            let glossary = Glossary(entries: [GlossaryEntry(canonical: "GPT", variants: ["jpt"], notes: nil)])
            expectEqual(glossary.applyingCorrections(to: "jpts and ajpt"), "jpts and ajpt")
            let apostrophe = Glossary(entries: [GlossaryEntry(canonical: "OpenAI", variants: ["oa"], notes: nil)])
            expectEqual(apostrophe.applyingCorrections(to: "l'oa and oa-x"), "l'oa and oa-x", "short variant must not touch apostrophe or hyphen words")
            expectEqual(apostrophe.applyingCorrections(to: "use oa today"), "use OpenAI today")
        }

        test("engines.glossary.unsafeVariantsNeverFire") {
            let glossary = Glossary(entries: [GlossaryEntry(canonical: "Genial", variants: ["a", "the", "est", "dans"], notes: nil)])
            let text = "a cat is the best, c'est dans la boite"
            expectEqual(glossary.applyingCorrections(to: text), text)
            expect(GlossaryVariantSafety.issue(for: "x") != nil, "one letter is unsafe")
            expect(GlossaryVariantSafety.issue(for: "The") != nil, "common words are unsafe in any case")
            expect(GlossaryVariantSafety.isSafe("jpt"), "a misheard short spelling is safe")
            expect(GlossaryVariantSafety.isSafe("lou mex"), "a phrase is safe")
        }

        test("engines.glossary.validatorShowsEveryProblem") {
            expectEqual(GlossaryDraftValidator.issue(canonical: "", variantsText: "jenial"), "Add the spelling to write.")
            expectEqual(GlossaryDraftValidator.issue(canonical: "", variantsText: " , "), nil, "an empty row is no problem")
            expect(GlossaryDraftValidator.issue(canonical: "Genial", variantsText: "jenial, the") != nil, "unsafe variant is flagged")
            expectEqual(GlossaryDraftValidator.issue(canonical: "Genial", variantsText: "jenial"), nil)

            let issues = GlossaryDraftValidator.issues(for: [
                (canonical: "Genial", variantsText: "jenial"),
                (canonical: "genial ", variantsText: "jen yal"),
                (canonical: "", variantsText: ""),
                (canonical: "", variantsText: "lou mex")
            ])
            expectEqual(issues.keys.sorted(), [1, 3], "duplicate and missing spelling are flagged, the blank row is not")
            expect(GlossaryDraftValidator.isBlank(canonical: " ", variantsText: " , "), "whitespace-only row is blank")
            expect(!GlossaryDraftValidator.isBlank(canonical: "", variantsText: "x"), "a row with a variant is not blank")
        }

        test("engines.words.deleteIsInstantAndCountsFollowRows") {
            let saved = [
                GlossaryEntry(canonical: "Genial", variants: ["jenial"], notes: nil),
                GlossaryEntry(canonical: "Tarvex", variants: ["tar vecks"], notes: nil)
            ]
            var drafts = saved.map(GlossaryEntryDraft.init)
            drafts.insert(GlossaryEntryDraft(canonical: "", variantsText: "", notes: ""), at: 0)
            expectEqual(WordsDeletion.visibleCount(drafts), 2, "a blank new row is not counted")

            // X on a saved word writes the list without it, right away.
            let deleted = drafts[1]
            drafts.removeAll { $0.id == deleted.id }
            let remaining = WordsDeletion.glossary(afterDeleting: deleted.savedCanonical, from: saved)
            expectEqual(remaining?.map(\.canonical), ["Tarvex"], "the saved word is deleted on the spot")
            expectEqual(WordsDeletion.visibleCount(drafts), 1, "WORDS count drops with the row")
            expect(WordsDeletion.isSingleDeletion(old: saved, new: remaining ?? []), "reads as a delete")
            // An edited row still deletes the saved spelling it came from.
            var edited = GlossaryEntryDraft(entry: saved[1])
            edited.canonical = "Cazarín"
            expectEqual(WordsDeletion.glossary(afterDeleting: edited.savedCanonical, from: saved)?.map(\.canonical), ["Genial"])
            expect(WordsDeletion.glossary(afterDeleting: nil, from: saved) == nil, "an unsaved row writes nothing")
            // Delete everything: zero, not the old count.
            expectEqual(WordsDeletion.visibleCount([GlossaryEntryDraft]()), 0)

            let snippets = [
                Snippet(trigger: "my email address", expansion: "a@b.c"),
                Snippet(trigger: "sign off", expansion: "Best")
            ]
            var snippetDrafts = snippets.map(SnippetDraft.init(snippet:))
            snippetDrafts.append(SnippetDraft(trigger: " ", expansion: ""))
            expectEqual(WordsDeletion.visibleCount(snippetDrafts), 2)
            let left = WordsDeletion.snippets(afterDeleting: snippets[0].id, from: snippets)
            expectEqual(left?.map(\.trigger), ["sign off"])
            snippetDrafts.removeAll { $0.id == snippets[0].id }
            expectEqual(WordsDeletion.visibleCount(snippetDrafts), 1, "SNIPPETS count drops with the row")
            expect(WordsDeletion.snippets(afterDeleting: UUID(), from: snippets) == nil, "an unsaved snippet writes nothing")
            expect(!WordsDeletion.isSingleDeletion(old: snippets, new: snippets), "a plain save is not a delete")
            expect(!WordsDeletion.isSingleDeletion(old: [1, 2, 3], new: [3, 1]), "reordered lists are not a delete")
            expect(WordsDeletion.isSingleDeletion(old: [1, 2, 3], new: [1, 2]), "last one removed")
        }

        test("engines.history.noFixAction") {
            // History rows offer COPY only. The fix-a-word editor and its
            // strings are gone in every language; words live in WORDS.
            for language in ["en", "fr", "es", "nl"] {
                let table = L10n.table(for: language)
                for key in ["FIX", "Fix a word YappYapp got wrong", "CLICK THE WORD IT GOT WRONG:", "Fix %@",
                            "Opens Words with this word, ready for your spelling"] {
                    expect(table[key] == nil, "\(language) still has \(key)")
                }
                expect(table["COPY"] != nil, "\(language) keeps COPY")
            }
        }

        test("engines.glossary.placeholderCannotRewriteRealWords") {
            let variants = GlossaryDraftValidator.variantList(from: GlossaryPlaceholders.soundsLike)
            expect(!variants.isEmpty, "placeholder offers examples")
            for variant in variants {
                expect(GlossaryVariantSafety.isSafe(variant), "placeholder variant \(variant) is safe")
            }
            let glossary = Glossary(entries: [
                GlossaryEntry(canonical: GlossaryPlaceholders.writeItAs, variants: variants, notes: nil)
            ])
            let french = "C'est génial, vraiment génial. Genial est génial."
            expectEqual(glossary.applyingCorrections(to: french), french, "copying the placeholder must not rewrite French génial")
            expect(!GlossaryPlaceholders.soundsLike.lowercased().contains("génial"), "placeholder no longer suggests génial")
        }
    }

    // MARK: - YA-49 prompt privacy

    private static func enginesWhisperPrivacyTests() {
        test("engines.whisperCLI.promptNeverInArguments") {
            var config = AppConfig.defaultConfig
            config.additionalPrompt = "SecretClientName"
            config.language = "fr"
            config.quietVoiceBoost = true
            let promptFile = URL(fileURLWithPath: "/private/tmp/yappyapp-prompt-x/prompt.txt")

            let supported = WhisperTranscriber.cliArguments(
                modelPath: "/m.bin", audioPath: "/a.wav", outputBasePath: "/o",
                config: config, promptFile: promptFile, binarySupportsPromptFile: true
            )
            expect(!supported.joined(separator: " ").contains("SecretClientName"), "prompt text must not enter argv")
            expect(!supported.contains("--prompt"), "the plain --prompt flag is never used")
            expectEqual(Array(supported.suffix(2)), ["--prompt-file", promptFile.path])
            expect(supported.contains("-bs"), "beam search flags still apply")

            let unsupported = WhisperTranscriber.cliArguments(
                modelPath: "/m.bin", audioPath: "/a.wav", outputBasePath: "/o",
                config: config, promptFile: promptFile, binarySupportsPromptFile: false
            )
            expect(!unsupported.contains("--prompt-file"), "an unpatched whisper-cli gets no prompt at all")
            expect(!unsupported.contains("--prompt"), "an unpatched whisper-cli never gets the prompt in argv")
        }

        test("engines.whisperCLI.promptFileIsPrivate") {
            let directory = try enginesScratchDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }

            expectEqual(try WhisperPromptFile.write("   ", in: directory), nil, "no file for an empty prompt")
            guard let url = try WhisperPromptFile.write(" Company vocabulary: Genial. ", in: directory) else {
                expect(false, "prompt file was not written")
                return
            }
            expectEqual(try String(contentsOf: url, encoding: .utf8), "Company vocabulary: Genial.")
            expectEqual(posixPermissions(url), 0o600, "prompt file is owner-only")
            expectEqual(posixPermissions(url.deletingLastPathComponent()), 0o700, "prompt folder is owner-only")
            WhisperPromptFile.remove(url)
            expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path), "prompt folder is removed")
        }

        test("engines.whisperCLI.promptFileSupportDetection") {
            expect(WhisperPromptFile.helpAdvertisesPromptFile("  --prompt-file FNAME  read the initial prompt"), "patched help is detected")
            expect(!WhisperPromptFile.helpAdvertisesPromptFile("  --prompt PROMPT  initial prompt"), "stock help is not")
        }
    }

    // MARK: - YA-48 silence hallucinations and prompt echo

    private static func enginesOutputGuardTests() {
        let prompt = "Company vocabulary and exact spellings: YappYapp, LUMEX. Product names."

        test("engines.outputGuard.hallucinationOnlyNearSilence") {
            expectEqual(WhisperOutputGuard.verdict(output: "Thank you.", prompt: prompt, nearSilence: true), .dropHallucination)
            expectEqual(WhisperOutputGuard.verdict(output: "Thank you.", prompt: prompt, nearSilence: false), .keep, "a spoken thank you at normal volume is kept")
            expectEqual(WhisperOutputGuard.verdict(output: "Thanks for watching! Thank you.", prompt: prompt, nearSilence: true), .dropHallucination)
            expectEqual(WhisperOutputGuard.verdict(output: "Sous-titres réalisés par la communauté d'Amara.org", prompt: prompt, nearSilence: true), .dropHallucination)
            expectEqual(WhisperOutputGuard.verdict(output: "Thank you for the update on LUMEX.", prompt: prompt, nearSilence: true), .keep, "a real sentence is never dropped")
        }

        test("engines.outputGuard.promptEcho") {
            expectEqual(WhisperOutputGuard.verdict(output: " company vocabulary and exact spellings: YappYapp, LUMEX. Product names ", prompt: prompt, nearSilence: false), .dropPromptEcho)
            expectEqual(WhisperOutputGuard.verdict(output: "YappYapp, LUMEX.", prompt: prompt, promptParts: ["YappYapp, LUMEX"], nearSilence: false), .dropPromptEcho)
            expectEqual(WhisperOutputGuard.verdict(output: "YappYapp is great.", prompt: prompt, promptParts: ["YappYapp, LUMEX"], nearSilence: false), .keep)
        }

        test("engines.outputGuard.nonSpeechTags") {
            expectEqual(WhisperOutputGuard.verdict(output: "[BLANK_AUDIO]", prompt: "", nearSilence: false), .dropNonSpeech)
            expectEqual(WhisperOutputGuard.verdict(output: "(music) [silence]", prompt: "", nearSilence: false), .dropNonSpeech)
            expectEqual(WhisperOutputGuard.verdict(output: "Ship it (today).", prompt: "", nearSilence: false), .keep)
        }

        test("engines.outputGuard.nearSilenceThreshold") {
            expect(WhisperOutputGuard.isNearSilence(AudioSignalProfile(sampleCount: 32_000, referencePeak: 0.002)), "faint noise is near silence")
            expect(!WhisperOutputGuard.isNearSilence(AudioSignalProfile(sampleCount: 32_000, referencePeak: 0.02)), "a whisper is not near silence")
            expect(!WhisperOutputGuard.isNearSilence(nil), "unknown level never drops anything")
        }

        test("engines.outputGuard.promptParts") {
            var config = AppConfig.defaultConfig
            config.additionalPrompt = "Extra words."
            let glossary = Glossary(entries: [GlossaryEntry(canonical: "LUMEX", variants: [], notes: nil)])
            let parts = WhisperOutputGuard.promptParts(config: config, glossary: glossary)
            expect(parts.contains("LUMEX"), "bare word list is an echo candidate")
            expect(parts.contains("Extra words."), "additional prompt is an echo candidate")
        }
    }

    // MARK: - YA-05 timeouts, fallback and retry

    private static func enginesTimeoutAndRetryTests() {
        test("engines.timeouts.scaleWithAudioAndBeamSearch") {
            expectEqual(TranscriptionTimeouts.serverRequestTimeout(audioSeconds: 5, beamSearch: false), 60, "short audio keeps the old floor")
            let longGreedy = TranscriptionTimeouts.serverRequestTimeout(audioSeconds: 600, beamSearch: false)
            let longBeam = TranscriptionTimeouts.serverRequestTimeout(audioSeconds: 600, beamSearch: true)
            expect(longGreedy > 600, "ten minutes of audio gets more than ten minutes: \(longGreedy)")
            expect(longBeam > longGreedy, "beam search gets a longer leash")
            expect(TranscriptionTimeouts.serverRequestTimeout(audioSeconds: 100_000, beamSearch: true) <= TranscriptionTimeouts.serverMaximum, "capped")

            let watchdog = TranscriptionTimeouts.whisperWatchdog(audioSeconds: 600, beamSearch: true)
            expect(watchdog > longBeam, "the app watchdog outlasts the server request")
            expect(watchdog > TranscriptionTimeouts.cliTimeout(audioSeconds: 600, beamSearch: true), "and the CLI run")
            expectEqual(TranscriptionTimeouts.whisperWatchdog(audioSeconds: 0, beamSearch: false), 90, "a short dictation keeps the old 90s watchdog")
            // YA-01 merged: the cold load budget is 180s, no download leash.
            expectEqual(TranscriptionTimeouts.parakeetWatchdog(audioSeconds: 10, modelLoaded: false), 180)
            expect(TranscriptionTimeouts.parakeetWatchdog(audioSeconds: 900, modelLoaded: false) > 180, "a long cold Parakeet dictation scales too")
            expectEqual(TranscriptionTimeouts.parakeetWatchdog(audioSeconds: 10, modelLoaded: true), 90)
            expect(TranscriptionTimeouts.parakeetWatchdog(audioSeconds: 900, modelLoaded: true) > 90, "fifteen-minute Parakeet dictations scale too")
        }

        test("engines.timeouts.audioDurationFromWAV") {
            let url = try writeWAV(frames: 32_000, amplitude: 0.3)
            defer { try? FileManager.default.removeItem(at: url) }
            let duration = TranscriptionTimeouts.audioDuration(of: url) ?? -1
            expect(abs(duration - 2.0) < 0.01, "two seconds of 16 kHz audio: \(duration)")
            expectEqual(TranscriptionTimeouts.audioDuration(of: URL(fileURLWithPath: "/nonexistent.wav")), nil)
        }

        test("engines.serverFailure.fallbackOnlyWhenUnreachable") {
            expect(WhisperServerFailure.shouldFallBackToCLI(URLError(.cannotConnectToHost)), "refused connection falls back")
            expect(WhisperServerFailure.shouldFallBackToCLI(URLError(.networkConnectionLost)), "dropped connection falls back")
            expect(WhisperServerFailure.shouldFallBackToCLI(WhisperServerControllerError.notRunning), "no server falls back")
            expect(WhisperServerFailure.shouldFallBackToCLI(WhisperError.serverFailed("HTTP 500")), "an instant HTTP error falls back")
            expect(!WhisperServerFailure.shouldFallBackToCLI(URLError(.timedOut)), "a timeout never starts a second model")
            expect(!WhisperServerFailure.shouldFallBackToCLI(WhisperError.emptyTranscript), "silence is not retried on the CLI")
            expect(WhisperServerFailure.isTimeout(URLError(.timedOut)), "timeouts are recognised")
            expect(!WhisperServerFailure.isTimeout(URLError(.cannotConnectToHost)), "refusals are not timeouts")
        }

        test("engines.retry.storeKeepsAndReleasesAudio") {
            let directory = try enginesScratchDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = FailedDictationStore(directory: directory)
            let profile = AudioSignalProfile(sampleCount: 16_000, referencePeak: 0.2)

            let recording = directory.appendingPathComponent("yappyapp-recording.wav")
            try Data("RIFF".utf8).write(to: recording)
            expect(store.keep(audioURL: recording, signalProfile: profile), "a failed recording is kept")
            expect(!FileManager.default.fileExists(atPath: recording.path), "the recorder's file moved")
            guard let kept = store.take() else {
                expect(false, "nothing to retry")
                return
            }
            expect(kept.audioURL.lastPathComponent.hasPrefix(FailedDictationStore.filePrefix), "kept under the retry prefix")
            expectEqual(kept.signalProfile, profile)
            expectEqual(posixPermissions(kept.audioURL), 0o600, "kept audio is owner-only")
            expect(store.hasPending, "take does not delete before the retry finishes")

            // A retry that fails again keeps the same file.
            expect(store.keep(audioURL: kept.audioURL, signalProfile: profile), "a failing retry keeps the audio")
            expectEqual(store.take()?.audioURL, kept.audioURL)

            store.finished(kept)
            expect(!store.hasPending, "a delivered retry clears the slot")
            expect(!FileManager.default.fileExists(atPath: kept.audioURL.path), "and deletes the audio")

            // A newer failure replaces the older one.
            let first = directory.appendingPathComponent("first.wav")
            let second = directory.appendingPathComponent("second.wav")
            try Data("1".utf8).write(to: first)
            try Data("2".utf8).write(to: second)
            store.keep(audioURL: first, signalProfile: nil)
            let firstKept = store.take()?.audioURL
            store.keep(audioURL: second, signalProfile: nil)
            expect(firstKept.map { !FileManager.default.fileExists(atPath: $0.path) } ?? false, "older kept audio is deleted")
            store.discard()
            expect(!store.hasPending, "discard clears the slot")
            expect(!store.keep(audioURL: directory.appendingPathComponent("missing.wav"), signalProfile: nil), "a missing file cannot be kept")
        }

        test("engines.retry.honestMessages") {
            expect(DictationFailurePresenter.keepsAudio(for: WhisperError.timedOut), "timeouts keep the audio")
            expect(DictationFailurePresenter.keepsAudio(for: URLError(.cannotConnectToHost)), "engine failures keep the audio")
            expect(!DictationFailurePresenter.keepsAudio(for: WhisperError.noSpeech), "silence is not kept")
            expect(!DictationFailurePresenter.keepsAudio(for: WhisperError.emptyTranscript), "empty output is not kept")
            let kept = DictationFailurePresenter.message(for: WhisperError.timedOut, audioKept: true)
            expect(kept.contains("took too long") && kept.contains("Retry Last Dictation"), "kept message says how to retry: \(kept)")
            expectEqual(DictationFailurePresenter.message(for: WhisperError.timedOut, audioKept: false), "Transcribing took too long.")
            expect(!kept.contains("\u{2014}"), "no em dash in copy")
        }
    }

    // MARK: - YA-11 warm server hardening

    private static func enginesServerHardeningTests() {
        test("engines.server.randomEndpointPerLaunch") {
            let first = WhisperServerEndpoint.random(port: 40_001)
            let second = WhisperServerEndpoint.random(port: 40_001)
            expect(first.requestPath != second.requestPath, "every launch gets a new secret")
            expect(first.requestPath.hasPrefix(WhisperServerEndpoint.requestPathPrefix), "secret path prefix")
            let secret = first.requestPath.dropFirst(WhisperServerEndpoint.requestPathPrefix.count)
            expectEqual(secret.count, 32, "128-bit secret")
            expect(secret.allSatisfy { $0.isHexDigit }, "secret is hex")
            expectEqual(first.inferenceURL.absoluteString, "http://127.0.0.1:40001\(first.requestPath)/inference")
            expectEqual(first.healthURL.absoluteString, "http://127.0.0.1:40001\(first.requestPath)/health")
        }

        test("engines.server.freePortIsLocalAndNonZero") {
            let port = LocalPortAllocator.freePort()
            expect((port ?? 0) > 1024, "kernel hands out an unprivileged port: \(String(describing: port))")
        }

        test("engines.server.launchArgumentsCarrySecretAndPort") {
            let arguments = WhisperServerController.launchArguments(
                model: "/m.bin", language: "en", prompt: "PrivateClient", translate: false, quietBoost: false,
                port: 40_123, requestPath: "/yappyapp-abc"
            )
            expectEqual(Array(arguments.prefix(9)), ["-m", "/m.bin", "--host", "127.0.0.1", "--port", "40123", "-nt", "-sns", "--request-path"])
            expect(arguments.contains("/yappyapp-abc"), "request path secret is passed")
            expect(!arguments.contains("PrivateClient"), "prompt still never in argv")
        }

        test("engines.server.requestUsesSecretPathAndScaledTimeout") {
            let directory = try enginesScratchDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let audio = directory.appendingPathComponent("a.wav")
            try Data("RIFF".utf8).write(to: audio)
            let endpoint = WhisperServerEndpoint(port: 40_555, requestPath: "/yappyapp-secret")
            let request = try WhisperServerController.buildInferenceRequest(
                endpoint: endpoint, audioURL: audio, prompt: "Genial", timeout: 412
            )
            expectEqual(request.url?.absoluteString, "http://127.0.0.1:40555/yappyapp-secret/inference")
            expectEqual(request.timeoutInterval, 412)
            expectEqual(request.httpMethod, "POST")
            expectEqual(request.value(forHTTPHeaderField: "Origin"), nil, "the app never sends Origin, which the patched server refuses")
        }

        test("engines.server.listenerMustBeOurChild") {
            expect(WhisperServerListenerCheck.ownsListener(listenerPIDs: [4242], childPID: 4242), "our child")
            expect(!WhisperServerListenerCheck.ownsListener(listenerPIDs: [999], childPID: 4242), "a squatter is not trusted")
            expect(!WhisperServerListenerCheck.ownsListener(listenerPIDs: [4242, 999], childPID: 4242), "a shared port is not trusted")
            expect(!WhisperServerListenerCheck.ownsListener(listenerPIDs: [], childPID: 4242), "nobody listening")
            expect(!WhisperServerListenerCheck.ownsListener(listenerPIDs: [0], childPID: 0), "no child")
        }

        test("engines.server.strandedServersAreOrphansOfOurBinary") {
            let binary = "/Applications/YappYapp.app/Contents/Resources/bin/whisper-server"
            let ps = """
              101     1 \(binary)
              102   555 \(binary)
              103     1 /opt/homebrew/bin/whisper-server
              104     1 /Users/me/Library/Application Support/YappYapp/whisper-server
            garbage line
            """
            expectEqual(StrandedWhisperServers.pids(psOutput: ps, binaryPath: binary), [101])
            expectEqual(
                StrandedWhisperServers.pids(psOutput: ps, binaryPath: "/Users/me/Library/Application Support/YappYapp/whisper-server"),
                [104],
                "paths with spaces still match"
            )
        }

        test("engines.server.restartBackoffIsExponentialAndResets") {
            var backoff = WhisperServerRestartBackoff()
            let start = Date(timeIntervalSince1970: 1_000)
            expectEqual(backoff.nextDelay(now: start), 1)
            expectEqual(backoff.nextDelay(now: start), 2)
            expectEqual(backoff.nextDelay(now: start), 4)
            for _ in 0..<10 { _ = backoff.nextDelay(now: start) }
            expectEqual(backoff.nextDelay(now: start), WhisperServerRestartBackoff.maximumDelay, "capped at a minute")

            backoff.markReady(at: start)
            expectEqual(backoff.nextDelay(now: start.addingTimeInterval(5)), WhisperServerRestartBackoff.maximumDelay, "a quick crash keeps backing off")
            backoff.markReady(at: start)
            expectEqual(backoff.nextDelay(now: start.addingTimeInterval(600)), 1, "a long healthy run starts over")
            backoff.reset()
            expectEqual(backoff.consecutiveFailures, 0)
        }

        test("engines.server.hardeningPatchShipsWithBootstrap") {
            let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            let patch = root.appendingPathComponent("scripts/patches/whisper-server-hardening.patch")
            let bootstrap = root.appendingPathComponent("scripts/bootstrap_whisper_cpp.sh")
            guard FileManager.default.fileExists(atPath: patch.path) else {
                // Running outside the source tree (for example a packaged build).
                return
            }
            let patchText = try String(contentsOf: patch, encoding: .utf8)
            expect(patchText.contains("-                             {\"Access-Control-Allow-Origin\", \"*\"},"), "patch removes the CORS header")
            expect(patchText.contains("-    svr->Post(sparams.request_path + \"/load\""), "patch removes /load")
            expect(patchText.contains("has_header(\"Origin\")"), "patch refuses browser requests")
            let script = try String(contentsOf: bootstrap, encoding: .utf8)
            expect(script.contains("apply --reverse --check"), "bootstrap applies patches idempotently")
            expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("scripts/patches/whisper-cli-prompt-file.patch").path), "prompt-file patch ships")
        }
    }

    // MARK: - YA-50 / YA-51 Parakeet

    private static func enginesParakeetTests() {
        test("engines.parakeet.memoryPolicy") {
            expectEqual(
                ParakeetMemoryPolicy.action(engine: .whisper, parakeetVariant: nil, selectedInstalled: true, keepModelWarm: true, atLaunch: false),
                .release, "switching to Whisper frees Parakeet"
            )
            expectEqual(
                ParakeetMemoryPolicy.action(engine: .whisper, parakeetVariant: nil, selectedInstalled: true, keepModelWarm: true, atLaunch: true),
                .release
            )
            expectEqual(
                ParakeetMemoryPolicy.action(engine: .parakeet, parakeetVariant: "v3", selectedInstalled: true, keepModelWarm: true, atLaunch: true),
                .preload(variant: "v3"), "installed Parakeet loads at launch"
            )
            expectEqual(
                ParakeetMemoryPolicy.action(engine: .parakeet, parakeetVariant: "ultra", selectedInstalled: true, keepModelWarm: true, atLaunch: true),
                .preload(variant: "ultra"), "Ultra stays warm exactly like v3"
            )
            expectEqual(
                ParakeetMemoryPolicy.action(engine: .parakeet, parakeetVariant: "v3", selectedInstalled: false, keepModelWarm: true, atLaunch: true),
                .none, "nothing to load when not installed"
            )
            expectEqual(
                ParakeetMemoryPolicy.action(engine: .parakeet, parakeetVariant: "v3", selectedInstalled: true, keepModelWarm: false, atLaunch: true),
                .none, "keep-warm off means load on demand"
            )
            expectEqual(
                ParakeetMemoryPolicy.action(engine: .parakeet, parakeetVariant: "v3", selectedInstalled: true, keepModelWarm: true, atLaunch: false),
                .none, "activation already preloads through its own path"
            )
        }

        test("engines.parakeet.byteProgress") {
            let progress = ParakeetByteProgress(totalBytes: 1_000)
            expectEqual(progress.fraction, 0)
            progress.update(file: "encoder", receivedBytes: 250, expectedBytes: 800)
            expectEqual(progress.fraction, 0.25, "progress moves inside a single file")
            progress.update(file: "vocab", receivedBytes: 200, expectedBytes: 200)
            expectEqual(progress.fraction, 0.45)
            progress.update(file: "encoder", receivedBytes: 100, expectedBytes: 800)
            expectEqual(progress.fraction, 0.45, "never moves backwards")
            progress.update(file: "encoder", receivedBytes: 9_999, expectedBytes: 800)
            expectEqual(progress.fraction, 1, "capped at the expected size")

            let throttled = ParakeetByteProgress(totalBytes: 10_000)
            throttled.update(file: "a", receivedBytes: 1, expectedBytes: 10_000)
            expectEqual(throttled.fractionToReport(), 0.0001, "first update reports")
            throttled.update(file: "a", receivedBytes: 2, expectedBytes: 10_000)
            expectEqual(throttled.fractionToReport(), nil, "tiny steps are not reported")
            throttled.update(file: "a", receivedBytes: 10_000, expectedBytes: 10_000)
            expectEqual(throttled.fractionToReport(), 1, "completion always reports")
            expectEqual(ParakeetByteProgress(totalBytes: 0).fraction, 0, "empty plan")
        }
    }
}
#endif
