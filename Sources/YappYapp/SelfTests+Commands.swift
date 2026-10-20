#if DEBUG
import AppKit
import Carbon
import Foundation

// Self-tests owned by the "commands" work track. Keep this track's new
// assertions here so parallel tracks never edit the same test lines.
//
// Everything runs on pure logic and fakes: no pasteboard, no AX writes, no
// key events, no hot keys. Temp files live under the self-test base.
extension SelfTests {
    static func commandsTrackTests() {
        commandsSpokenCommandTests()
        commandsSpokenCommandFalsePositiveTests()
        commandsUndoPlannerTests()
        commandsRetryLastTests()
        commandsConfigTests()
        commandsShortcutTests()
        commandsUITests()
    }

    private static func commandsScratchDirectory() throws -> URL {
        let base = ProcessInfo.processInfo.environment["YAPPYAPP_APP_SUPPORT_BASE"]
            .map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("commands-selftest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: - Spoken commands

    private static func commandsSpokenCommandTests() {
        test("commands.newLineAndParagraphInEveryLanguage") {
            let cases: [(String, String)] = [
                ("Dear Ana. New line. Thanks for the notes.", "Dear Ana.\nThanks for the notes."),
                ("Dear Ana, new line, thanks for the notes.", "Dear Ana,\nThanks for the notes."),
                ("First point. New paragraph. Second point.", "First point.\n\nSecond point."),
                ("Bonjour. Nouvelle ligne. Merci.", "Bonjour.\nMerci."),
                ("Bonjour. Nouveau paragraphe. Merci.", "Bonjour.\n\nMerci."),
                ("Bonjour, nouvelle ligne !", "Bonjour,\n"),
                ("Hola. Nueva línea. Gracias.", "Hola.\nGracias."),
                ("Hola. Nueva linea. Gracias.", "Hola.\nGracias."),
                ("Hola. Nuevo párrafo. Gracias.", "Hola.\n\nGracias."),
                ("Hallo. Nieuwe regel. Dank je.", "Hallo.\nDank je."),
                ("Hallo. Nieuwe alinea. Dank je.", "Hallo.\n\nDank je."),
                ("New line.", "\n"),
                ("Hello. Newline. Bye.", "Hello.\nBye.")
            ]
            for (input, expected) in cases {
                let result = SpokenCommands.apply(to: input)
                expectEqual(result.text, expected, input)
                expect(!result.undoPrevious, "\(input) never undoes the previous dictation")
            }
        }

        test("commands.scratchThatRemovesTheSentenceBefore") {
            expectEqual(
                SpokenCommands.apply(to: "I'll be there at five. Scratch that. I'll be there at six.").text,
                "I'll be there at six."
            )
            expectEqual(
                SpokenCommands.apply(to: "First. Second. Scratch that.").text,
                "First."
            )
            expectEqual(
                SpokenCommands.apply(to: "See you Monday. Delete that. See you Tuesday.").text,
                "See you Tuesday."
            )
            expectEqual(SpokenCommands.apply(to: "Lundi. Efface ça. Mardi.").text, "Mardi.")
            expectEqual(SpokenCommands.apply(to: "Lundi. Efface ca. Mardi.").text, "Mardi.")
            expectEqual(SpokenCommands.apply(to: "El lunes. Borra eso. El martes.").text, "El martes.")
            expectEqual(SpokenCommands.apply(to: "Maandag. Wis dat. Dinsdag.").text, "Dinsdag.")
            expectEqual(
                SpokenCommands.apply(to: "Hi team. Ship it friday. Scratch that. Ship it Monday.").text,
                "Hi team. Ship it Monday."
            )
        }

        test("commands.scratchThatAloneUndoesThePreviousDictation") {
            for phrase in ["Scratch that.", "scratch that", "Delete that!", "Efface ça.", "¡Borra eso!", "Wis dat."] {
                let result = SpokenCommands.apply(to: phrase)
                expect(result.undoPrevious, "\(phrase) takes the previous dictation back")
                expect(!result.hasContent, "\(phrase) leaves nothing to type")
            }
            let rest = SpokenCommands.apply(to: "Scratch that, I meant Tuesday.")
            expect(rest.undoPrevious, "an opening scratch undoes the previous dictation")
            expectEqual(rest.text, "I meant Tuesday.")
            expect(rest.hasContent, "the rest is still typed")
        }

        test("commands.processHonorsTheToggle") {
            let input = "Hello. New line. Bye."
            expectEqual(SpokenCommands.process(input, enabled: false).text, input, "off leaves the words alone")
            expectEqual(SpokenCommands.process(input, enabled: true).text, "Hello.\nBye.")
            let plain = "Nothing to see here, really."
            let untouched = SpokenCommands.process(plain, enabled: true)
            expectEqual(untouched.text, plain, "no command means the exact transcript")
            expectEqual(untouched.appliedCommands, 0)
        }

        test("commands.clausesAreLossless") {
            for text in [
                "It costs 3.5 dollars, maybe 4... who knows?!",
                "Hello. New line. Bye.",
                "  leading spaces, trailing ones  ",
                "e.g. this, i.e. that"
            ] {
                let joined = SpokenCommands.clauses(in: text).map { $0.body + $0.terminator }.joined()
                expectEqual(joined, text, "clauses rebuild the input")
            }
        }

        test("commands.tableCoversFourLanguagesAndThreeCommands") {
            let languages = Set(SpokenCommandTable.phrases.map(\.language))
            expectEqual(languages, ["en", "fr", "es", "nl"])
            for language in languages {
                let kinds = SpokenCommandTable.phrases.filter { $0.language == language }.map(\.kind)
                expect(kinds.contains(.newLine), "\(language) has new line")
                expect(kinds.contains(.newParagraph), "\(language) has new paragraph")
                expect(kinds.contains(.scratchThat), "\(language) has scratch that")
            }
            let folded = SpokenCommandTable.phrases.map { SpokenCommandTable.fold($0.phrase) }
            expectEqual(Set(folded).count, folded.count, "no phrase is listed twice")
        }
    }

    private static func commandsSpokenCommandFalsePositiveTests() {
        test("commands.ordinaryWordsAreNeverRewritten") {
            let untouched = [
                "We need a new line of products.",
                "Please delete that file before Friday.",
                "Can you delete that?",
                "Start a new paragraph after the quote, then stop.",
                "I said new line twice",
                "Hello new line how are you",
                "The new lines look great.",
                "Scratch that itch.",
                "Une nouvelle ligne de métro ouvre demain.",
                "Il faut que j'efface ça demain.",
                "Abrimos una nueva línea de producción.",
                "No borra eso que escribiste.",
                "Er komt een nieuwe regel voor parkeren.",
                "Ik wis dat bestand later.",
                "The period of time was long, comma included."
            ]
            for text in untouched {
                let result = SpokenCommands.process(text, enabled: true)
                expectEqual(result.text, text, "untouched: \(text)")
                expect(!result.undoPrevious, "no undo: \(text)")
            }
        }

        test("commands.copyHasNoEmDashes") {
            let copy = [
                SpokenCommandCopy.settingsNote,
                SpokenCommandCopy.scratchedStatus,
                InsertionUndoPresenter.menuTitle,
                RetryLastPresenter.menuTitle,
                RetryLastPresenter.couldNotPrepare
            ] + [
                InsertionUndoRefusal.nothingToUndo, .appChanged("Notes"), .appChanged(nil),
                .textChanged, .needsPermission, .busy, .modifiersHeld
            ].map(InsertionUndoPresenter.refusalText)
            for line in copy {
                expect(!line.contains("\u{2014}"), "no em dash: \(line)")
            }
        }
    }

    // MARK: - Undo last insertion

    private static func commandsUndoPlannerTests() {
        let text = " world"
        let ax = InsertionMethod.accessibility(location: 5, text: text)

        test("commands.undo.removesExactlyTheInsertion") {
            let plan = InsertionUndoPlanner.plan(
                method: ax, recordPID: 42, frontmostPID: 42, accessibilityTrusted: true,
                focusedElementMatches: true, currentValue: "Hello world, again"
            )
            expectEqual(plan, .removeText(NSRange(location: 5, length: 6)))
            if case .removeText(let range) = plan {
                expectEqual(InsertionUndoPlanner.removing(range, from: "Hello world, again"), "Hello, again")
            }
        }

        test("commands.undo.refusesWhenTheTextMoved") {
            let edited = InsertionUndoPlanner.plan(
                method: ax, recordPID: 42, frontmostPID: 42, accessibilityTrusted: true,
                focusedElementMatches: true, currentValue: "Hi! Hello world"
            )
            expectEqual(edited, .refuse(.textChanged), "text shifted, so nothing is guessed")
            let otherField = InsertionUndoPlanner.plan(
                method: ax, recordPID: 42, frontmostPID: 42, accessibilityTrusted: true,
                focusedElementMatches: false, currentValue: "Hello world"
            )
            expectEqual(otherField, .refuse(.textChanged), "another field has focus")
            let short = InsertionUndoPlanner.plan(
                method: ax, recordPID: 42, frontmostPID: 42, accessibilityTrusted: true,
                focusedElementMatches: true, currentValue: "Hello"
            )
            expectEqual(short, .refuse(.textChanged), "range past the end")
            let normalized = InsertionUndoPlanner.plan(
                method: .accessibilityNormalized, recordPID: 42, frontmostPID: 42, accessibilityTrusted: true,
                focusedElementMatches: true, currentValue: "Hello world"
            )
            expectEqual(normalized, .refuse(.textChanged), "a reformatted insert is never guessed at")
        }

        test("commands.undo.commandZOnlyInTheSameApp") {
            expectEqual(
                InsertionUndoPlanner.plan(
                    method: .keystroke, recordPID: 7, frontmostPID: 7, accessibilityTrusted: true,
                    focusedElementMatches: false, currentValue: nil
                ),
                .sendCommandZ
            )
            expectEqual(
                InsertionUndoPlanner.plan(
                    method: .keystroke, recordPID: 7, frontmostPID: 8, accessibilityTrusted: true,
                    focusedElementMatches: false, currentValue: nil
                ),
                .refuse(.appChanged(nil)),
                "another app is in front"
            )
            expectEqual(
                InsertionUndoPlanner.plan(
                    method: ax, recordPID: 7, frontmostPID: nil, accessibilityTrusted: true,
                    focusedElementMatches: true, currentValue: "Hello world"
                ),
                .refuse(.appChanged(nil))
            )
        }

        test("commands.undo.nothingAndPermission") {
            expectEqual(
                InsertionUndoPlanner.plan(
                    method: nil, recordPID: nil, frontmostPID: 1, accessibilityTrusted: true,
                    focusedElementMatches: false, currentValue: nil
                ),
                .refuse(.nothingToUndo)
            )
            expectEqual(
                InsertionUndoPlanner.plan(
                    method: .keystroke, recordPID: 1, frontmostPID: 1, accessibilityTrusted: false,
                    focusedElementMatches: false, currentValue: nil
                ),
                .refuse(.needsPermission)
            )
            expectEqual(InsertionUndoPlanner.exactRange(of: "", at: 0, in: "abc"), nil, "empty insert")
            expectEqual(InsertionUndoPlanner.exactRange(of: "b", at: -1, in: "abc"), nil, "negative offset")
            expectEqual(InsertionUndoPlanner.exactRange(of: "😀!", at: 2, in: "a 😀!"), NSRange(location: 2, length: 3), "UTF-16 offsets")
        }

        test("commands.undo.copy") {
            expectEqual(InsertionUndoPresenter.statusText(for: .removed), "Removed your last dictation.")
            expectEqual(
                InsertionUndoPresenter.statusText(for: .refused(.appChanged("Notes"))),
                "Switch back to Notes to undo the last dictation."
            )
            expect(
                InsertionUndoPresenter.statusText(for: .sentUndoKey).contains("Check"),
                "Cmd+Z cannot be confirmed, so the copy says so"
            )
        }
    }

    // MARK: - Retry last

    private static func commandsRetryLastTests() {
        let kept = LastRecording(id: UUID(), wav: Data([1, 2, 3]), signalProfile: nil, failed: false)
        var failed = kept
        failed.failed = true

        test("commands.retry.plan") {
            func plan(
                _ phase: CapturePhase = .idle,
                processing: Bool = false,
                pasting: Bool = false,
                memory: LastRecording? = nil,
                hasFailed: Bool = false
            ) -> RetryLastPlan {
                RetryLastPlanner.plan(
                    phase: phase, isProcessing: processing, pasteInFlight: pasting,
                    memory: memory, hasFailedDictation: hasFailed
                )
            }
            expectEqual(plan(), .nothingYet)
            expectEqual(plan(memory: kept), .retranscribe, "a delivered dictation runs from memory")
            expectEqual(plan(memory: failed, hasFailed: true), .retryFailed, "a failed one runs from its kept file")
            expectEqual(plan(memory: failed, hasFailed: false), .retranscribe, "kept file gone, memory still works")
            expectEqual(plan(memory: nil, hasFailed: true), .retryFailed, "an older failure is still retried")
            expectEqual(plan(.recording, memory: kept), .busyRecording)
            expectEqual(plan(.transcribing, memory: kept), .busyTranscribing)
            expectEqual(plan(processing: true, memory: kept), .busyTranscribing)
            expectEqual(plan(pasting: true, memory: kept), .busyPasting)
            expectEqual(plan(.error("Timed out."), memory: failed, hasFailed: true), .retryFailed, "RETRY after an error")
            expectEqual(RetryLastPresenter.statusText(for: .retranscribe), nil)
            expectEqual(
                RetryLastPresenter.statusText(for: .nothingYet),
                "Nothing to retry yet. Dictate something first."
            )
        }

        test("commands.retry.memoryLifecycle") {
            let directory = try commandsScratchDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let wav = directory.appendingPathComponent("yappyapp-source.wav")
            let bytes = Data((0..<4096).map { UInt8($0 % 251) })
            try bytes.write(to: wav)

            let memory = LastRecordingMemory()
            expect(!memory.hasRecording, "starts empty")
            expect(try memory.materialize(in: directory) == nil, "nothing to write while empty")
            expect(memory.remember(contentsOf: wav, signalProfile: nil), "remembers a recording")
            try FileManager.default.removeItem(at: wav)
            expectEqual(memory.recording?.wav, bytes, "kept in memory after the file is gone")

            let retryURL = try memory.materialize(in: directory)
            expect(retryURL != nil, "writes a temp WAV for the retry")
            if let retryURL {
                expect(retryURL.lastPathComponent.hasPrefix(TempFileSweeper.prefix), "the launch sweep knows the name")
                expectEqual(try Data(contentsOf: retryURL), bytes)
                let permissions = try FileManager.default.attributesOfItem(atPath: retryURL.path)[.posixPermissions] as? NSNumber
                expectEqual(permissions?.intValue, PrivateFile.filePermissions, "owner-only temp file")
            }

            memory.markFailed()
            expectEqual(memory.recording?.failed, true)
            memory.markRecovered()
            expectEqual(memory.recording?.failed, false)
            memory.clear()
            expect(!memory.hasRecording, "cleared on the next dictation and on quit")
            expect(!memory.remember(contentsOf: wav, signalProfile: nil), "a missing file is not remembered")
        }

        test("commands.retry.hudOffersRetryOnlyAfterAKeptFailure") {
            expect(RetryLastPresenter.offersRetry(phase: .error("Timed out."), retryAvailable: true), "error with kept audio")
            expect(!RetryLastPresenter.offersRetry(phase: .error("Timed out."), retryAvailable: false), "nothing kept")
            expect(!RetryLastPresenter.offersRetry(phase: .pasted, retryAvailable: true), "success")
            expect(HUDPresenter.acceptsMouse(.error("x"), retryAvailable: true), "RETRY is clickable")
            expect(!HUDPresenter.acceptsMouse(.error("x"), retryAvailable: false), "plain errors stay click-through")
            expect(HUDPresenter.acceptsMouse(.recording, retryAvailable: false), "stop button unchanged")
        }
    }

    // MARK: - Config

    private static func commandsConfigTests() {
        test("commands.config.defaultsOnAndRoundTrips") {
            expect(AppConfig.defaultConfig.spokenCommands, "on by default")
            let legacy = #"{"whisperBinaryPath":"/x","modelPath":"parakeet://v3","language":"auto","additionalPrompt":"","maxRecordingSeconds":300,"restoreClipboardAfterPaste":true,"pasteWhenFocusIsUnclear":true}"#
            let decoded = try JSONDecoder().decode(AppConfig.self, from: Data(legacy.utf8))
            expect(decoded.spokenCommands, "an older config turns it on")

            var config = AppConfig.defaultConfig
            config.spokenCommands = false
            let data = try JSONEncoder().encode(config)
            expectEqual(try JSONDecoder().decode(AppConfig.self, from: data).spokenCommands, false)
            let recovered = ConfigRecovery.decode(
                data: data,
                installDefaults: AppConfig.defaultConfig,
                lastSaved: { nil }
            )
            expectEqual(recovered.config.spokenCommands, false, "config repair keeps the toggle")
            expectEqual(ConfigRecovery.fieldTypes["spokenCommands"] != nil, true)

            let wrongType = #"{"whisperBinaryPath":"/x","modelPath":"parakeet://v3","language":"auto","additionalPrompt":"","maxRecordingSeconds":300,"restoreClipboardAfterPaste":true,"pasteWhenFocusIsUnclear":true,"spokenCommands":"yes"}"#
            expect(try JSONDecoder().decode(AppConfig.self, from: Data(wrongType.utf8)).spokenCommands, "a damaged value falls back to on")
        }
    }

    // MARK: - Shortcuts

    private final class CommandsFakeRegistrar: HotKeyRegistering {
        var entries: [UInt32: (chord: KeyChord, onPress: () -> Void)] = [:]
        var nextID: UInt32 = 1

        func register(chord: KeyChord, onPress: @escaping () -> Void, onRelease: (() -> Void)?) -> UInt32? {
            let id = nextID
            nextID += 1
            entries[id] = (chord, onPress)
            return id
        }

        func unregister(id: UInt32) {
            entries.removeValue(forKey: id)
        }

        func press(_ chord: KeyChord) {
            entries.values.first(where: { $0.chord == chord })?.onPress()
        }
    }

    private final class CommandsFakeMonitor: ModifierEventMonitoring {
        func start(_ handler: @escaping @MainActor (ModifierMonitorEvent) -> Void) -> Bool { true }
        func stop() {}
    }

    private static func commandsShortcutTests() {
        test("commands.shortcuts.undoLastIsUnboundByDefault") {
            expectEqual(ShortcutSettings.default.chord(for: .undoLast), nil, "opt-in, nothing grabbed")
            expectEqual(ShortcutAction.undoLast.title, "UNDO LAST")
            let older = #"{"mode":"toggle","bindings":[{"action":"toggleDictation","chord":{"keyCode":49,"modifiers":2048}}]}"#
            let decoded = try JSONDecoder().decode(ShortcutSettings.self, from: Data(older.utf8))
            expectEqual(decoded.chord(for: .undoLast), nil, "older shortcut blocks gain the action unbound")
            expectEqual(decoded.bindings.count, ShortcutAction.allCases.count)
        }

        test("commands.shortcuts.undoLastFiresItsHandler") {
            let registrar = CommandsFakeRegistrar()
            var undoCount = 0
            var retryCount = 0
            let coordinator = ShortcutCoordinator(
                registrar: registrar,
                modifierMonitor: CommandsFakeMonitor(),
                now: { 0 },
                handlers: ShortcutCoordinator.Handlers(
                    isRecording: { false },
                    onDictation: { _ in },
                    onPasteLast: {},
                    onRetryLast: { retryCount += 1 },
                    onCancel: {},
                    onUndoLast: { undoCount += 1 }
                )
            )
            var settings = ShortcutSettings.default
            let undoChord = KeyChord(keyCode: UInt32(kVK_ANSI_Z), modifiers: UInt32(controlKey | optionKey))
            let retryChord = KeyChord(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(controlKey | optionKey))
            settings.setChord(undoChord, for: .undoLast)
            settings.setChord(retryChord, for: .retryLast)
            let failed = coordinator.apply(settings)
            expectEqual(failed, [], "both register")
            registrar.press(undoChord)
            registrar.press(retryChord)
            expectEqual(undoCount, 1, "undo shortcut runs undo")
            expectEqual(retryCount, 1, "retry shortcut runs retry")
        }
    }

    // MARK: - UI

    private static func commandsUITests() {
        test("commands.ui.hudAndHomeRenderRetry") {
            let state = YappYappState()
            state.phase = .error("Transcription timed out.")
            state.retryAvailable = true
            expect(renderImage(BrutalistHUDView(state: state), width: 320, height: 56) != nil, "HUD renders RETRY")
            expect(renderImage(RetryFailedButton(action: {}), width: 120, height: 40) != nil, "MIC tab RETRY renders")
        }
    }
}
#endif
