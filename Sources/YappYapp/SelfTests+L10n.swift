#if DEBUG
import AppKit
import Foundation
import SwiftUI

// Self-tests owned by the "l10n" work track. Keep this track's new
// assertions here so parallel tracks never edit the same test lines.
extension SelfTests {
    static func l10nTrackTests() {
        l10nTableTests()
        l10nLookupTests()
        l10nConfigTests()
        l10nCopyTests()
        l10nFitTests()
        l10nRenderTests()
    }

    // MARK: - Tables

    private static let l10nTranslations = ["fr", "es", "nl"]

    /// Argument index to type ("@" or "lld") for every placeholder in `text`.
    static func l10nPlaceholders(_ text: String) -> [Int: String] {
        guard let regex = try? NSRegularExpression(pattern: #"%(?:(\d+)\$)?(@|lld|ld|d|%)"#) else { return [:] }
        var result: [Int: String] = [:]
        var next = 0
        let range = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: range) {
            guard let typeRange = Range(match.range(at: 2), in: text) else { continue }
            let type = String(text[typeRange])
            if type == "%" { continue }
            next += 1
            if let indexRange = Range(match.range(at: 1), in: text), let index = Int(text[indexRange]) {
                result[index] = type
            } else {
                result[next] = type
            }
        }
        return result
    }

    private static func l10nTableTests() {
        test("l10n.resourceBundleIsFound") {
            expect(L10n.resourceBundleURL != nil, "the YappYapp resource bundle is reachable")
            for language in L10n.supportedLanguages {
                expect(L10n.lprojURL(for: language) != nil, "\(language).lproj exists")
            }
        }

        test("l10n.statusDiagnosticReportsEveryLanguage") {
            let lines = L10nDiagnostics.statusLines()
            expect(lines.first?.hasPrefix("l10n.bundle=/") == true, "status names the bundle path")
            for language in L10n.supportedLanguages {
                expect(lines.contains { $0.hasPrefix("l10n.\(language).strings=") && !$0.hasSuffix("=0") }, "\(language) table is counted")
            }
        }

        test("l10n.everyKeyExistsInAllFourLanguages") {
            let english = L10n.table(for: "en")
            expect(english.count > 900, "the English table carries the whole UI (\(english.count) keys)")
            for (key, value) in english {
                expectEqual(value, key, "English values are their keys")
            }
            for language in l10nTranslations {
                let table = L10n.table(for: language)
                let missing = english.keys.filter { table[$0] == nil }.sorted()
                let extra = table.keys.filter { english[$0] == nil }.sorted()
                expect(missing.isEmpty, "\(language) misses \(missing.prefix(5))")
                expect(extra.isEmpty, "\(language) has keys English lacks: \(extra.prefix(5))")
                let empty = table.filter { $0.value.trimmingCharacters(in: .whitespaces).isEmpty && !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }
                expect(empty.isEmpty, "\(language) has empty values: \(empty.keys.sorted().prefix(5))")
            }
        }

        test("l10n.formatSpecifiersMatch") {
            let english = L10n.table(for: "en")
            for language in l10nTranslations {
                let table = L10n.table(for: language)
                for (key, value) in table {
                    let expected = l10nPlaceholders(key)
                    let actual = l10nPlaceholders(value)
                    if expected != actual {
                        failures.append("[\(currentTest)] \(language) \"\(key)\" placeholders \(actual) != \(expected)")
                    } else {
                        passed += 1
                    }
                }
            }
            // Shortcut copy is rewritten after translation, so these tokens
            // must survive in every language that the English key carries.
            for token in [ShortcutCopy.defaultInline, "Option Space"] {
                for key in english.keys where key.contains(token) {
                    for language in l10nTranslations {
                        expect(L10n.string(key, language: language).contains(token), "\(language) keeps \(token) in \"\(key)\"")
                    }
                }
            }
        }

        test("l10n.pluralRulesMatchAcrossLanguages") {
            let english = L10n.pluralTable(for: "en")
            expect(english.count >= 8, "plural keys are present")
            for language in L10n.supportedLanguages {
                let table = L10n.pluralTable(for: language)
                expectEqual(Set(table.keys), Set(english.keys), "\(language) plural keys")
                for (key, entry) in table {
                    guard let rule = entry as? [String: Any], let count = rule["count"] as? [String: Any] else {
                        failures.append("[\(currentTest)] \(language) \(key) is not a plural rule")
                        continue
                    }
                    for category in ["one", "other"] {
                        let text = count[category] as? String ?? ""
                        expectEqual(l10nPlaceholders(text), [1: "lld"], "\(language) \(key).\(category) has one count")
                    }
                }
            }
        }

        test("l10n.noDashesAndNoTranslationCollisions") {
            let english = L10n.table(for: "en")
            for language in L10n.supportedLanguages {
                let table = L10n.table(for: language)
                let dashed = table.values.filter { $0.contains("\u{2014}") || $0.contains("\u{2013}") }
                expect(dashed.isEmpty, "\(language) has dashes: \(dashed.prefix(3))")
                // Choke-point views translate text that is already
                // translated. That is only safe when no translation is also
                // a different English key that translates to something else.
                for (key, value) in table where value != key {
                    if english[value] != nil, table[value] != value {
                        failures.append("[\(currentTest)] \(language) \"\(key)\" -> \"\(value)\" collides with another key")
                    } else {
                        passed += 1
                    }
                }
            }
        }

        test("l10n.catalogCopyIsInTheTables") {
            let english = L10n.table(for: "en")
            var keys: [String] = []
            keys += ModelCatalog.options.flatMap { [$0.badge, $0.summary] }
            keys += BrutalTab.allCases.map(\.rawValue)
            keys += PetKind.allCases.filter { $0 != .clawd }.map(\.label)
            keys += PetAccessory.allCases.map(\.label)
            keys += DailyQuest.allCases.map(\.title)
            keys += CleanupMode.allCases.flatMap { [$0.label, $0.summary] }
            keys += ShortcutAction.allCases.flatMap { [$0.title, $0.detail] }
            keys += RecordingMode.allCases.flatMap { [$0.chipLabel, $0.explanation, $0.headline] }
            keys += ModifierHoldKey.allCases.flatMap { [$0.chipLabel, $0.spokenName] }
            keys += ProfilePasteBehavior.allCases.map(\.label)
            keys += AppLanguage.allCases.filter { $0 == .system }.map { _ in "SYSTEM" }
            for key in keys {
                expect(english[key] != nil, "\"\(key)\" is translatable")
            }
        }
    }

    // MARK: - Lookup

    private static func l10nLookupTests() {
        test("l10n.systemLanguageResolution") {
            expectEqual(L10n.resolve("system", preferredLanguages: ["fr-FR", "en-US"]), "fr")
            expectEqual(L10n.resolve("system", preferredLanguages: ["de-DE", "es-419"]), "es")
            expectEqual(L10n.resolve("system", preferredLanguages: ["nl-BE"]), "nl")
            expectEqual(L10n.resolve("system", preferredLanguages: ["de-DE", "ja-JP"]), "en")
            expectEqual(L10n.resolve("system", preferredLanguages: []), "en")
            expectEqual(L10n.resolve("es", preferredLanguages: ["fr-FR"]), "es")
            expectEqual(L10n.resolve("klingon", preferredLanguages: ["nl-NL"]), "nl", "unknown values follow the system")
            expectEqual(AppLanguage(configValue: "fr"), .fr)
            expectEqual(AppLanguage(configValue: ""), .system)
        }

        test("l10n.applyAndFallback") {
            let previous = L10n.language
            defer { L10n.apply(previous) }
            expectEqual(previous, "en", "tests and CLI flags start in English")

            L10n.apply("fr")
            expectEqual(L10n.language, "fr")
            expectEqual(L10n.tr("SETUP"), "RÉGLAGES")
            expectEqual(L10n.tr("Shows the %@ tab", "mots"), "Affiche l'onglet mots")
            expectEqual(L10n.tr("A device name nobody translates"), "A device name nobody translates")
            expectEqual(BrutalTextSize.small.label, "PETIT")
            expectEqual(PetKind.fox.label, "Renard")

            L10n.apply("es")
            expectEqual(L10n.tr("Ready"), "Listo")
            expectEqual(CapturePhase.recording.label, "Escuchando")
            L10n.apply("nl")
            expectEqual(L10n.tr("COPY"), "KOPIËER")
            L10n.apply("en")
            expectEqual(L10n.tr("COPY"), "COPY")
        }

        test("l10n.pluralsFollowEachLanguage") {
            expectEqual(L10n.plural("%lld words", 1, language: "en"), "1 word")
            expectEqual(L10n.plural("%lld words", 0, language: "en"), "0 words")
            expectEqual(L10n.plural("%lld words", 0, language: "fr"), "0 mot", "French treats zero as singular")
            expectEqual(L10n.plural("%lld words", 2, language: "fr"), "2 mots")
            expectEqual(L10n.plural("%lld words", 0, language: "es"), "0 palabras")
            expectEqual(L10n.plural("%lld words", 1, language: "nl"), "1 woord")
            expectEqual(L10n.plural("%lld DAYS", 3, language: "es"), "3 DÍAS")
            expectEqual(L10n.plural("%lld words", 12_345, language: "en"), "12,345 words", "large counts keep grouping")
            expectEqual(L10n.plural("A key with no rule %lld", 4, language: "nl"), "A key with no rule 4")
            expectEqual(FileTranscriptionPresenter.detail(for: .finished(fileName: "x", words: 1)), "1 WORD · READY TO COPY OR SAVE")
        }

        test("l10n.retranslateSwapsAFixedLine") {
            let previous = L10n.language
            defer { L10n.apply(previous) }
            let english = StatusFlavor.idlePrompt[0]
            L10n.apply("nl")
            let dutch = L10n.retranslate(english)
            expectEqual(dutch, StatusFlavor.idlePrompt[0])
            expect(dutch != english, "the idle prompt switches language")
            L10n.apply("fr")
            expectEqual(L10n.retranslate(dutch), StatusFlavor.idlePrompt[0], "works from any language")
            expectEqual(L10n.retranslate("Built from a format 42"), "Built from a format 42")
        }
    }

    // MARK: - Config

    private static func l10nConfigTests() {
        test("l10n.appLanguageConfigIsBackwardCompatible") {
            let legacy = Data(#"{"whisperBinaryPath":"/x","modelPath":"parakeet://v3","language":"auto","additionalPrompt":"","maxRecordingSeconds":60,"restoreClipboardAfterPaste":true,"pasteWhenFocusIsUnclear":true}"#.utf8)
            let decoded = try JSONDecoder().decode(AppConfig.self, from: legacy)
            expectEqual(decoded.appLanguage, "system", "older configs follow the system")
            expectEqual(AppConfig.defaultConfig.appLanguage, "system")

            var config = AppConfig.defaultConfig
            config.appLanguage = "nl"
            let roundTrip = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config))
            expectEqual(roundTrip.appLanguage, "nl")

            let wrongType = Data(#"{"whisperBinaryPath":"/x","modelPath":"parakeet://v3","language":"auto","additionalPrompt":"","maxRecordingSeconds":60,"restoreClipboardAfterPaste":true,"pasteWhenFocusIsUnclear":true,"appLanguage":7}"#.utf8)
            expectEqual(try JSONDecoder().decode(AppConfig.self, from: wrongType).appLanguage, "system")
            expectEqual(ConfigRecovery.fieldTypes["appLanguage"], .string, "recovery knows the key")

            let outcome = ConfigRecovery.decode(
                data: Data(#"{"modelPath":"parakeet://v3","appLanguage":"es"}"#.utf8),
                installDefaults: AppConfig.defaultConfig,
                lastSaved: { nil }
            )
            expectEqual(outcome.config.appLanguage, "es", "a repaired file keeps a readable app language")
        }
    }

    // MARK: - Copy that logic reads

    private static func l10nCopyTests() {
        test("l10n.errorLabelsClassifyEveryLanguage") {
            let previous = L10n.language
            defer { L10n.apply(previous) }
            let messages = [
                "Heard nothing.",
                "Mic stopped. Transcribing what it caught.",
                "Mic changed. Transcribing what it caught.",
                "This Parakeet model didn't verify. Download it again in MODELS.",
                "Missing Whisper model at %@.",
                "YappYapp needs the mic. Allow it in System Settings > Privacy & Security > Microphone."
            ]
            for message in messages {
                L10n.apply("en")
                let expected = PasteOutcomePresenter.errorShortLabel(message)
                expect(expected != "FAILED", "\"\(message)\" has a class")
                for language in l10nTranslations {
                    L10n.apply(language)
                    let translated = L10n.string(message, language: language)
                    expectEqual(
                        PasteOutcomePresenter.errorShortLabel(translated),
                        L10n.tr(expected),
                        "\(language) \"\(translated)\""
                    )
                }
            }
        }

        test("l10n.shortcutCopyStillPersonalizes") {
            let previous = L10n.language
            defer { L10n.apply(previous) }
            L10n.apply("fr")
            var settings = ShortcutSettings.default
            settings.modifierHold = .rightOption
            settings.setChord(nil, for: .toggleDictation)
            let line = ShortcutCopy.personalize(StatusFlavor.idlePrompt[0], settings)
            expect(!line.contains(ShortcutCopy.defaultInline), "the default chord is swapped out in French: \(line)")
            expect(line.contains(ModifierHoldKey.rightOption.spokenName.lowercased()), "the French key name is used: \(line)")
        }
    }

    // MARK: - Fit

    /// Width of one line in the system black weight, as the Brutal type scale draws it.
    static func l10nWidth(_ text: String, size: CGFloat, kerning: CGFloat, monospaced: Bool = false) -> CGFloat {
        let font = monospaced
            ? NSFont.monospacedSystemFont(ofSize: size, weight: .black)
            : NSFont.systemFont(ofSize: size, weight: .black)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .kern: kerning]
        return ceil((text as NSString).size(withAttributes: attributes).width)
    }

    private static func l10nFitTests() {
        test("l10n.fixedWidthLabelsFitInEveryLanguage") {
            let previous = L10n.language
            defer { L10n.apply(previous) }
            for language in L10n.supportedLanguages {
                L10n.apply(language)
                // Six tabs share the 404 pt row. UX-WRITING: each cell is its
                // label plus padding plus an equal share of the spare room, so
                // the labels together must leave a real gap in every language.
                var tabRow: CGFloat = 0
                for tab in BrutalTab.allCases {
                    let label = L10n.tr(tab.rawValue)
                    let width = l10nWidth(label, size: BrutalTabRowLayout.fontSize, kerning: BrutalTabRowLayout.kerning)
                    expect(width <= 76, "\(language) tab \(label) is \(width) pt")
                    tabRow += width
                }
                // At least 16 pt between neighbouring labels (padding included).
                let gaps = CGFloat(BrutalTab.allCases.count - 1)
                expect(tabRow + gaps * max(12, 2 * BrutalTabRowLayout.labelPadding) <= 404, "\(language) tab labels leave under 12 pt between them (\(tabRow) pt)")
                // The HUD's trailing block is 72 pt wide and may shrink to 60%.
                let hudLabels = [
                    HUDLabelPresenter.trailingLabel(phase: .pasted, recordingSeconds: 0),
                    HUDLabelPresenter.trailingLabel(phase: .copied, recordingSeconds: 0),
                    HUDLabelPresenter.trailingLabel(phase: .sentUnconfirmed, recordingSeconds: 0),
                    HUDLabelPresenter.trailingLabel(phase: .canceled, recordingSeconds: 0),
                    HUDLabelPresenter.trailingLabel(phase: .idle, recordingSeconds: 0),
                    HUDLabelPresenter.trailingLabel(phase: .error("x"), recordingSeconds: 0),
                    MissingModelNotice.hudLabel,
                    PasteOutcomePresenter.copiedOnlyHeadline,
                    PasteOutcomePresenter.notPastedHeadline,
                    RetryLastPresenter.buttonTitle
                ]
                for label in hudLabels {
                    let width = l10nWidth(label, size: 11, kerning: 0, monospaced: true)
                    expect(width * 0.6 <= 66, "\(language) HUD label \(label) is \(width) pt")
                }
                // Four text size chips share one row with a 0.8 shrink floor.
                for size in BrutalTextSize.allCases {
                    let width = l10nWidth(size.label, size: 9, kerning: 0.6)
                    expect(width * 0.8 <= 81, "\(language) text size \(size.label) is \(width) pt")
                }
                // ON/OFF sits in a 42 pt box.
                for state in ["ON", "OFF"] {
                    let width = l10nWidth(L10n.tr(state), size: 9, kerning: 0.8)
                    expect(width <= 38, "\(language) toggle \(L10n.tr(state)) is \(width) pt")
                }
                // Header chip, beside the 22 pt wordmark.
                for label in ["NOT READY", "ALMOST READY", "READY", "Listening", "Transcribing", "Needs attention"] {
                    let text = L10n.tr(label).uppercased()
                    expect(l10nWidth(text, size: 10, kerning: 0.8) <= 190, "\(language) header chip \(text)")
                }
                // WORDS tab: IMPORT and EXPORT sit in 74 pt buttons that may
                // shrink to 85% and must not wrap.
                for label in ["IMPORT", "EXPORT"] {
                    let width = l10nWidth(L10n.tr(label), size: 11, kerning: 0.8)
                    expect(width * 0.85 <= 66, "\(language) \(L10n.tr(label)) is \(width) pt")
                }
                // App language chips wrap in a flow row, but each must fit the row.
                for choice in AppLanguage.allCases {
                    expect(l10nWidth(choice.chipLabel, size: 9, kerning: 0.6) + 16 <= 376, "\(language) \(choice.chipLabel)")
                }
            }
        }
    }

    // MARK: - Render

    private static func l10nDrawnPixels<V: View>(_ view: V, width: CGFloat, height: CGFloat) -> Int {
        guard let snapshot = renderPixelSnapshot(view, width: width, height: height) else { return 0 }
        var count = 0
        var index = 0
        while index + 3 < snapshot.rgba.count {
            let red = snapshot.rgba[index], green = snapshot.rgba[index + 1], blue = snapshot.rgba[index + 2]
            // Paper is a warm off-white; ink and fills are far from it.
            if Int(red) + Int(green) + Int(blue) < 600 { count += 1 }
            index += 4
        }
        return count
    }

    /// Manual QA aid: set YAPPYAPP_L10N_SNAPSHOT_DIR to get one PNG per
    /// language and screen. Nothing is written otherwise.
    private static func l10nWriteSnapshot(_ image: NSImage?, name: String) {
        guard let directory = ProcessInfo.processInfo.environment["YAPPYAPP_L10N_SNAPSHOT_DIR"],
              let image,
              let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            return
        }
        let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? png.write(to: url)
    }

    private static func l10nRenderTests() {
        MainActor.assumeIsolated {
            test("l10n.keyScreensRenderInEveryLanguage") {
                let previous = L10n.language
                defer { L10n.apply(previous) }
                var english: [String: Int] = [:]
                for language in ["en"] + l10nTranslations {
                    L10n.apply(language)
                    let state = makeUIState()
                    state.config.appLanguage = language
                    let popover = makeBrutalPopover(state)
                    let screens: [(String, AnyView, CGFloat, CGFloat)] = [
                        ("popover", AnyView(popover), 440, 600),
                        ("home", AnyView(popover.homeTab.background(Brutal.paper)), 404, 420),
                        ("files", AnyView(popover.filesTab.background(Brutal.paper)), 404, 420),
                        ("models", AnyView(popover.modelsTab.background(Brutal.paper)), 404, 420),
                        ("words", AnyView(popover.wordsTab.background(Brutal.paper)), 404, 420),
                        ("pet", AnyView(popover.petTab.background(Brutal.paper)), 404, 420),
                        ("settings", AnyView(popover.settingsTab.background(Brutal.paper)), 404, 1600),
                        ("hud", AnyView(BrutalistHUDView(state: makeUIState(phase: .recording))), 320, 56)
                    ]
                    for (name, view, width, height) in screens {
                        let image = renderImage(view, width: width, height: height)
                        expect(image != nil, "\(language) \(name) renders")
                        l10nWriteSnapshot(image, name: "\(language)-\(name)")
                        let drawn = l10nDrawnPixels(view, width: width, height: height)
                        expect(drawn > 0, "\(language) \(name) draws content")
                        if language == "en" {
                            english[name] = drawn
                        } else if let base = english[name], name != "hud" {
                            // Same layout, other words: the ink amount stays in the
                            // same range, so nothing collapsed or blew up.
                            expect(drawn > base / 3 && drawn < base * 3, "\(language) \(name) drew \(drawn) vs \(base) in English")
                        }
                    }
                }
            }

            test("l10n.settingsShowsAppLanguageRow") {
                let previous = L10n.language
                defer { L10n.apply(previous) }
                L10n.apply("es")
                let popover = makeBrutalPopover(makeUIState())
                expect(renderImage(popover.appLanguageRow.background(Brutal.paper), width: 376, height: 80) != nil, "app language row renders")
                expectEqual(AppLanguage.system.chipLabel, "SISTEMA")
                expectEqual(AppLanguage.es.chipLabel, "ESPAÑOL", "language names stay in their own language")
            }
        }
    }
}
#endif
