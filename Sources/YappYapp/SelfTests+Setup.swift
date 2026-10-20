#if DEBUG
import AppKit
import Carbon
import Foundation
import SwiftUI

// Self-tests for the SETUP tab structure (SETUP-ORDER). Keep this track's
// assertions here so parallel tracks never edit the same test lines.
extension SelfTests {
    static func setupTrackTests() {
        setupOrderTests()
        setupCancelMergeTests()
        setupCopyTruthTests()
        setupConsistencyTests()
        setupClipboardTests()
    }

    private static func setupOrderTests() {
        test("setup.sectionOrder") {
            // By how often people change them and what they need first: how
            // to dictate and what comes out, the mic, where text goes, per-app
            // tweaks, then the rarer rows.
            expectEqual(SetupSection.allCases.map(\.rawValue), [
                "DICTATION", "MICROPHONE", "PASTING", "APP PROFILES",
                "INDICATOR AND SOUND", "SPEED", "APP", "HELP"
            ])
            let english = L10n.table(for: "en")
            for section in SetupSection.allCases {
                expect(english[section.rawValue] != nil, "\"\(section.rawValue)\" is translatable")
            }
            for removed in ["PERFORMANCE", "GENERAL", "TRANSCRIPT", "ENGINE", "PER-APP PROFILES", "LLM CLEANUP", "ESC CANCELS DICTATION",
                            "SHORTCUTS", "LANGUAGE AND CLEANUP", "LOOK AND SOUND", "DOWNLOADS AND UPDATES"] {
                expect(english[removed] == nil, "the old SETUP heading or row \(removed) is gone")
            }
        }

        test("setup.moreShortcutsDisclosure") {
            let shown = ShortcutAction.primaryInSetup + ShortcutAction.moreInSetup
            expectEqual(Set(shown), Set(ShortcutAction.allCases), "every shortcut stays reachable")
            expectEqual(shown.count, ShortcutAction.allCases.count, "no shortcut shows twice")
            expectEqual(ShortcutAction.primaryInSetup, [.toggleDictation, .cancel])
            expectEqual(ShortcutAction.moreInSetup, [.pasteLast, .retryLast, .undoLast])

            var settings = ShortcutSettings.default
            expect(!settings.hasMoreShortcutsSet, "a fresh install keeps MORE SHORTCUTS closed")
            settings.setChord(KeyChord(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | shiftKey)), for: .pasteLast)
            expect(settings.hasMoreShortcutsSet, "a bound paste last opens MORE SHORTCUTS")

            for open in [true, false] {
                let section = ShortcutSettingsSection(settings: .constant(settings), cancelEnabled: .constant(true), isAccessibilityTrusted: true, moreOpen: open)
                expect(renderImage(section, width: 404, height: 900) != nil, "the shortcuts section renders with MORE SHORTCUTS \(open ? "open" : "closed")")
            }
        }
    }

    private static func setupCancelMergeTests() {
        test("setup.oneCancelControl") {
            // One stored switch (escCancelsRecording) plus the cancel chord.
            // SETUP shows them as the single CANCEL row.
            let settings = ShortcutSettings.default
            expectEqual(settings.effectiveCancelChord(cancelEnabled: true), .escape)
            expectEqual(settings.effectiveCancelChord(cancelEnabled: false), nil, "a switched-off Esc shows as NOT SET")
            expectEqual(settings.effective(cancelEnabled: true), settings)
            expectEqual(settings.effective(cancelEnabled: false).chord(for: .cancel), nil, "an off cancel claims no keys")
            expectEqual(settings.effective(cancelEnabled: false).chord(for: .toggleDictation), .optionSpace, "other shortcuts are untouched")

            // The HUD uses the same rule as the CANCEL row.
            var config = AppConfig.defaultConfig
            config.escCancelsRecording = false
            let hudCancels = config.escCancelsRecording && config.shortcuts.chord(for: .cancel) != nil
            expectEqual(hudCancels, config.shortcuts.effectiveCancelChord(cancelEnabled: config.escCancelsRecording) != nil)
        }
    }

    private static func setupCopyTruthTests() {
        test("setup.copyMatchesBehavior") {
            // INSTANT START says the ring holds 1.5 seconds: 24,000 samples at 16 kHz.
            expectEqual(Double(RecordingController.warmRingCapacity) / 16_000, 1.5)
            // The mic check title says six seconds.
            expectEqual(MicCheckController.duration, 6)
            // Mode chips use plain words.
            expectEqual(RecordingMode.allCases.map(\.chipLabel), ["PRESS", "HOLD", "BOTH"])
            // No jargon in the SETUP copy this track owns.
            let lines: [String] = CleanupMode.allCases.flatMap { [$0.label, $0.summary] }
                + [CleanupReadiness.needsRuntime, .needsModel(downloadsAllowed: true), .needsModel(downloadsAllowed: false), .verifying, .off]
                    .flatMap { [$0.headline, $0.detail] }
                + RecordingMode.allCases.flatMap { [$0.chipLabel, $0.explanation] }
                + ShortcutAction.allCases.map(\.detail)
                + [AppProfileCopy.intro, AppProfileCopy.empty, AppProfileCopy.modelMissing, AppProfileCopy.cleanupModelMissing]
            for line in lines {
                for banned in ["LLM", "llama", "runtime", "verbatim", "Verbatim", "HUD", "OPT-IN", "sanitized", "toggle", "hybrid", "combo", "raw"] {
                    expect(!line.contains(banned), "\"\(line)\" avoids \(banned)")
                }
            }
            expect(CleanupReadiness.needsModel(downloadsAllowed: false).detail.contains("IT admin"), "managed Macs are told to ask their IT admin")
            expect(MicCheckCopy.message(for: .micBlocked, pickerAbove: false).contains("System Settings > Privacy & Security > Microphone"), "System Settings path in full")
        }

        test("setup.tabRendersEveryLanguage") {
            let previous = L10n.language
            defer { L10n.apply(previous) }
            for language in L10n.supportedLanguages {
                L10n.apply(language)
                let state = makeUIState()
                state.managedConfigKeys = Set(ManagedConfigKey.allCases)
                expect(renderImage(makeBrutalPopover(state).settingsTab, width: 404, height: 3_000) != nil, "\(language) SETUP renders with every lock")
            }
        }
    }

    private static func setupConsistencyTests() {
        test("setup.typeScale") {
            // One family (the system sans), two weights, one case rule per role.
            let roles = BrutalTextStyle.allCases
            expectEqual(roles.count, 6, "section title, row label, control, value, caption, action")
            expectEqual(Set(roles.map(\.weight)).count, 2, "black for what you scan or press, medium for what you read")
            expectEqual(roles.filter { !$0.isUppercase }, [.caption], "captions are the only sentence-case role")
            expect(roles.allSatisfy { $0.size >= BrutalTypeScale.minimumPointSize }, "every role sits at or above the 9pt floor")
            expect(BrutalTextStyle.rowLabel.size > BrutalTextStyle.control.size, "a row label reads above its control text")
        }

        test("setup.oneControlPerKindOfChoice") {
            // Every pick-one row draws through the same components, at one
            // height, so they cannot drift apart again.
            expectEqual(SetupChoices.indicatorPositions.map(\.value), ["bottom", "top", "left", "right", "off"])
            let english = L10n.table(for: "en")
            for label in ["BOTTOM", "TOP", "LEFT", "RIGHT", "OFF"] {
                expect(english[label] != nil, "\(label) is translatable")
            }
            for language in ["fr", "es", "nl"] {
                let table = L10n.table(for: language)
                expect(table["LEFT"] != nil && table["RIGHT"] != nil, "\(language) has LEFT and RIGHT")
            }
            expectEqual(BrutalControl.height, 26)
            // Five options fit one even row at popover width; nothing wraps.
            let segmented = BrutalSegmented(
                choices: ModifierHoldKey.allCases.map { BrutalChoice(value: $0, title: $0.chipLabel) },
                selection: ModifierHoldKey.rightOption,
                hint: ""
            ) { _ in }
            let fitted = NSHostingView(rootView: segmented.frame(width: 356)).fittingSize.height
            expect(fitted <= BrutalControl.height + 1, "a five-option row stays on one line, got \(fitted)")
            for open in [true, false] {
                let section = BrutalSettingsCard(SetupSection.dictation.title) {
                    ShortcutSettingsSection(settings: .constant(.default), cancelEnabled: .constant(true), isAccessibilityTrusted: false, moreOpen: open)
                }
                expect(renderImage(section, width: 404, height: 1_200) != nil, "DICTATION renders with MORE SHORTCUTS \(open ? "open" : "closed")")
            }
        }
    }

    private static func setupClipboardTests() {
        test("setup.clipboardAlwaysRestored") {
            // The PUT MY CLIPBOARD BACK AFTER row is gone; the clipboard
            // always comes back after an inserted paste.
            for language in L10n.supportedLanguages {
                expect(L10n.table(for: language)["PUT MY CLIPBOARD BACK AFTER"] == nil, "\(language) no longer has the clipboard row")
            }
            expect(AppConfig.defaultConfig.restoreClipboardAfterPaste, "restore is on by default")
            let old = Data(#"{"restoreClipboardAfterPaste":false}"#.utf8)
            expect(try JSONDecoder().decode(AppConfig.self, from: old).restoreClipboardAfterPaste, "an old false is ignored")
            let repaired = ConfigRecovery.decode(data: old, installDefaults: .defaultConfig, lastSaved: { nil })
            expect(repaired.config.restoreClipboardAfterPaste, "config recovery ignores an old false too")
            expect(ClipboardInjector.shouldRestoreClipboard(after: .pasted), "an inserted paste restores")
            expect(!ClipboardInjector.shouldRestoreClipboard(after: .copiedOnly(.focusUnclear)), "copy-only still never restores")
            let report = SupportReport.render(supportReportInput())
            expect(!report.contains("Restore clipboard"), "the support report drops the removed setting")
        }
    }
}
#endif
