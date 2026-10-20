#if DEBUG
import AppKit
import Foundation
import SwiftUI

// Self-tests owned by the "firstrun" work track. Keep this track's new
// assertions here so parallel tracks never edit the same test lines.
extension SelfTests {
    static func firstrunTrackTests() {
        firstrunIntegrationTests()
        firstrunReadinessTests()
        firstrunPrerequisiteTests()
        firstrunLanguageTests()
        firstrunSetupCopyTests()
        firstrunChipAndHUDTests()
        firstrunDownloadErrorTests()
        firstrunHotkeyAndRuntimeTests()
        firstrunWindowAndMenuTests()
        firstrunFeedbackTests()
        firstrunRenderTests()
    }

    /// Wave 1 merge: the YA-33 chip and YA-75 labels cover the pipeline's
    /// delivery phases, and the watchdog keeps both YA-01 and YA-05.
    private static func firstrunIntegrationTests() {
        test("firstrunIntegration.chipAndHUDCoverDeliveryPhases") {
            expectEqual(HeaderChipPresenter.chip(phase: .sentUnconfirmed, readiness: .ready).tone, .unconfirmed)
            expectEqual(HeaderChipPresenter.chip(phase: .notDelivered(headline: "NOT PASTED", reason: "x"), readiness: .ready).tone, .error)
            expectEqual(HeaderChipPresenter.chip(phase: .canceled, readiness: .ready).tone, .idle)
            expectEqual(HUDLabelPresenter.trailingLabel(phase: .sentUnconfirmed, recordingSeconds: 0), "PASTED?")
            expectEqual(HUDLabelPresenter.trailingLabel(phase: .canceled, recordingSeconds: 0), "KEEP")
            expectEqual(HUDPresenter.trailingLabel(for: .idle, elapsed: 0), "READY", "one wording for the HUD")
        }

        test("firstrunIntegration.watchdogScalesAboveTheFloors") {
            expectEqual(TranscriptionWatchdog.timeoutSeconds(isParakeet: false, isLoaded: false, audioSeconds: 600, beamSearch: true),
                        UInt64(TranscriptionTimeouts.whisperWatchdog(audioSeconds: 600, beamSearch: true).rounded(.up)))
            expect(TranscriptionWatchdog.timeoutSeconds(isParakeet: true, isLoaded: false, audioSeconds: 900) < 900 + 180,
                   "no download leash on a cold Parakeet load")
        }

        test("firstrunIntegration.refusedBinaryExplainsItself") {
            let message = WhisperRuntimeCopy.missingBlockedMessage(isPackagedApp: false, binaryPath: "relative/whisper-cli")
            expect(message.lowercased().contains("whisper"), "source builds still name the engine: \(message)")
        }
    }

    // MARK: - YA-01 readiness

    private static func firstrunReadinessTests() {
        test("firstrun.parakeetReadyOnlyWhenInstalled") {
            var config = AppConfig.defaultConfig
            config.modelPath = "parakeet://v3"
            for downloads in [true, false] {
                config.allowModelDownloads = downloads
                let missing = ModelReadinessPresenter.snapshot(
                    config: config,
                    whisperReadiness: (binary: false, model: false),
                    selectedModelInstalled: false
                )
                expect(!missing.isModelReady, "downloads=\(downloads) without a model is not ready")
                let installed = ModelReadinessPresenter.snapshot(
                    config: config,
                    whisperReadiness: (binary: false, model: false),
                    selectedModelInstalled: true
                )
                expect(installed.isModelReady, "downloads=\(downloads) with the model installed is ready")
            }
        }

        test("firstrun.freshInstallWizardShowsDownloadStep") {
            let rows = SetupReadinessPresenter.guidedRows(for: SetupReadinessInput(
                isWhisperReady: true,
                isModelReady: false,
                isAccessibilityTrusted: false,
                pasteWhenFocusIsUnclear: true,
                allowModelDownloads: true,
                activeDownloadProgress: nil,
                isMicrophoneAuthorized: false,
                isGuidedFirstRun: true,
                recommendedModelName: "Parakeet TDT v3"
            ))
            expectEqual(rows.count, 1)
            expectEqual(rows.first?.id, "model-missing")
            expectEqual(rows.first?.action, .downloadRecommendedModel)
            expectEqual(rows.first?.actionTitle, "Download")
            expect(rows.first?.detail.contains("Parakeet TDT v3") == true, "the offer names the model it downloads")
            expectEqual(rows.first?.stepBadge, "Step 1 of 3")

            let downloading = SetupReadinessPresenter.guidedRows(for: SetupReadinessInput(
                isWhisperReady: true,
                isModelReady: false,
                isAccessibilityTrusted: false,
                pasteWhenFocusIsUnclear: true,
                allowModelDownloads: true,
                activeDownloadProgress: 0.37,
                isMicrophoneAuthorized: false,
                isGuidedFirstRun: true
            ))
            expectEqual(downloading.first?.id, "model-download")
            expectEqual(downloading.first?.actionTitle, "37%")
        }

        test("firstrun.catalogAndStatusCopyNeverPromiseAutoDownload") {
            for option in ModelCatalog.options {
                let summary = option.summary.lowercased()
                expect(!summary.contains("auto-download"), "\(option.id) summary promises auto-download")
                expect(!summary.contains("first use"), "\(option.id) summary promises a first-use download")
            }
            let first = ModelDownloadPresenter.startedStatus(
                optionName: "Parakeet TDT v3",
                selectedModelName: "Parakeet TDT v3",
                selectedModelInstalled: false
            )
            expect(!first.contains("stays active"), "a first download has nothing active to keep")
            expectEqual(first, "Downloading Parakeet TDT v3\u{2026} You can dictate the moment it's done.")
            expectEqual(
                ModelDownloadPresenter.startedStatus(optionName: "Large v3 Turbo", selectedModelName: "Tiny English", selectedModelInstalled: true),
                "Downloading Large v3 Turbo\u{2026} Keep dictating with Tiny English meanwhile."
            )
        }

        test("firstrun.watchdogHasNoFirstRunDownloadLeash") {
            expectEqual(TranscriptionWatchdog.timeoutSeconds(isParakeet: false, isLoaded: false), 90)
            expectEqual(TranscriptionWatchdog.timeoutSeconds(isParakeet: true, isLoaded: true), 90)
            expectEqual(TranscriptionWatchdog.timeoutSeconds(isParakeet: true, isLoaded: false), 180)
            expect(TranscriptionWatchdog.timeoutSeconds(isParakeet: true, isLoaded: false) < 900, "the 900 s download leash is gone")
        }
    }

    // MARK: - YA-01 blocked dictation

    private static func firstrunPrerequisiteTests() {
        let v3 = ModelCatalog.option(for: "parakeet-v3")
        let turbo = ModelCatalog.option(for: "large-v3-turbo")

        test("firstrun.missingParakeetOffersDownload") {
            var config = AppConfig.defaultConfig
            config.modelPath = "parakeet://v3"
            config.allowModelDownloads = true
            let result = RecordingPrerequisite.evaluate(
                config: config,
                selectedOption: v3,
                selectedModelInstalled: false,
                downloadProgress: nil,
                whisperReadiness: (binary: false, model: false)
            )
            guard case .missingModel(let notice) = result else {
                expect(false, "expected a missing-model block, got \(result)")
                return
            }
            expect(notice.offersDownload, "downloads on and nothing in flight offers DOWNLOAD")
            expectEqual(notice.modelID, "parakeet-v3")
            expectEqual(notice.message, "No voice model yet. Download Parakeet TDT v3 below to start dictating.")
            expect(result.message?.hasPrefix(MissingModelNotice.messagePrefix) == true, "message carries the HUD prefix")
        }

        test("firstrun.missingParakeetWhileDownloadingOrOffline") {
            var config = AppConfig.defaultConfig
            config.modelPath = "parakeet://v3"
            let downloading = RecordingPrerequisite.evaluate(
                config: config,
                selectedOption: v3,
                selectedModelInstalled: false,
                downloadProgress: 0.5,
                whisperReadiness: (binary: false, model: false)
            )
            expectEqual(
                downloading.message,
                "No voice model yet. Downloading Parakeet TDT v3 (50%). You can dictate the moment it finishes."
            )
            if case .missingModel(let notice) = downloading {
                expect(!notice.offersDownload, "no second DOWNLOAD while one runs")
            }
            let optimizing = MissingModelNotice(modelID: "parakeet-v3", modelName: "Parakeet TDT v3", downloadsAllowed: true, downloadProgress: -1)
            expect(optimizing.message.contains("almost ready"), "the optimizing phase reads as almost ready")

            config.allowModelDownloads = false
            let offline = RecordingPrerequisite.evaluate(
                config: config,
                selectedOption: v3,
                selectedModelInstalled: false,
                downloadProgress: nil,
                whisperReadiness: (binary: false, model: false)
            )
            if case .missingModel(let notice) = offline {
                expect(!notice.offersDownload, "downloads off never offers DOWNLOAD")
                expect(notice.message.contains("Model downloads are off"), "offline copy explains why")
                expect(notice.message.contains("ask your IT admin"), "a managed Mac knows who to ask")
                expect(!notice.message.contains("Settings"), "the in-app tab is Setup")
            } else {
                expect(false, "offline Parakeet without a model must block")
            }
        }

        test("firstrun.readyAndWhisperBranches") {
            var config = AppConfig.defaultConfig
            config.modelPath = "parakeet://v3"
            expectEqual(
                RecordingPrerequisite.evaluate(
                    config: config, selectedOption: v3, selectedModelInstalled: true,
                    downloadProgress: nil, whisperReadiness: (binary: false, model: false)
                ),
                .ready
            )

            config.modelPath = turbo?.defaultPath ?? ""
            let noBinaryPackaged = RecordingPrerequisite.evaluate(
                config: config, selectedOption: turbo, selectedModelInstalled: false,
                downloadProgress: nil, whisperReadiness: (binary: false, model: true),
                isPackagedApp: true
            )
            expect(noBinaryPackaged.message?.contains("whisper-cli") == false, "DMG users get no file paths")
            expect(noBinaryPackaged.message?.contains("Parakeet") == true, "DMG users get a way forward")

            let noModel = RecordingPrerequisite.evaluate(
                config: config, selectedOption: turbo, selectedModelInstalled: false,
                downloadProgress: nil, whisperReadiness: (binary: true, model: false)
            )
            if case .missingModel(let notice) = noModel {
                expectEqual(notice.modelID, "large-v3-turbo")
            } else {
                expect(false, "a catalog Whisper model without its file is a one-click download")
            }

            config.modelPath = "/tmp/custom.gguf"
            let custom = RecordingPrerequisite.evaluate(
                config: config, selectedOption: nil, selectedModelInstalled: false,
                downloadProgress: nil, whisperReadiness: (binary: true, model: false)
            )
            if case .blocked = custom {} else {
                expect(false, "a custom model path cannot be downloaded")
            }
        }
    }

    // MARK: - YA-24 / YA-25 language

    private static func firstrunLanguageTests() {
        test("firstrun.englishOnlyModelKeepsSavedLanguage") {
            var config = AppConfig.defaultConfig
            config.language = "fr"
            for id in ["parakeet-v2", "parakeet-110m", "small-en"] {
                guard let option = ModelCatalog.option(for: id) else { continue }
                let plan = ModelActivationPlanner.plan(currentConfig: config, option: option)
                expectEqual(plan.config.language, "fr", "\(id) activation keeps the saved language")
                expectEqual(TranscriptionLanguage.effectiveLanguage(for: plan.config), "en", "\(id) transcribes English")
                let copy = TranscriptionLanguage.transcriptionConfig(from: plan.config)
                expectEqual(copy.language, "en")
                expectEqual(plan.config.language, "fr", "the transcription copy never touches the saved config")
            }

            guard let v3 = ModelCatalog.option(for: "parakeet-v3") else { return }
            let multilingual = ModelActivationPlanner.plan(currentConfig: config, option: v3)
            expectEqual(TranscriptionLanguage.effectiveLanguage(for: multilingual.config), "fr")
        }

        test("firstrun.engineNotesAreHonest") {
            var config = AppConfig.defaultConfig
            config.modelPath = "parakeet://v3"
            let parakeet = EngineSettingsNotes.notes(for: config)
            // SETUP > DICTATION has one shared caption, not one per row.
            expect(parakeet.languageAndTranslate?.contains("Parakeet picks the language itself") == true, "v3 explains auto-detect in one caption")
            expect(parakeet.languageAndTranslate?.contains("changes Whisper and Qwen3-ASR models") == true, "the caption says what the pick changes")
            expect(parakeet.quietVoiceBoost != nil, "quiet boost is annotated on Parakeet")
            expect(!EngineSettingsNotes.translateApplies(for: config), "Whisper built-in translate does nothing on Parakeet")
            expectEqual(EngineSettingsNotes.menuLanguageTitle(for: config), "Dictation Language (Not for Parakeet)")
            let status = EngineSettingsNotes.menuLanguageStatus(label: "Français", config: config)
            expect(status.contains("Parakeet picks the language itself"), "menu status no longer claims Parakeet uses the pick")
            expect(!status.hasPrefix("Dictation language:"), "menu copy is honest on Parakeet")

            config.modelPath = "parakeet://v2"
            expect(EngineSettingsNotes.notes(for: config).languageAndTranslate?.contains("only does English") == true, "v2 says English-only")

            if let turbo = ModelCatalog.option(for: "large-v3-turbo") {
                config.modelPath = turbo.defaultPath
                expectEqual(EngineSettingsNotes.notes(for: config), EngineSettingsNotes(languageAndTranslate: nil, quietVoiceBoost: nil))
                expectEqual(EngineSettingsNotes.menuLanguageTitle(for: config), "Dictation Language")
                expectEqual(EngineSettingsNotes.menuLanguageStatus(label: "Français", config: config), "Dictation language: Français.")
                expect(EngineSettingsNotes.translateApplies(for: config), "translate works on Whisper")
            }
            if let smallEN = ModelCatalog.option(for: "small-en") {
                config.modelPath = smallEN.defaultPath
                config.language = "fr"
                expect(EngineSettingsNotes.notes(for: config).languageAndTranslate?.contains("only does English") == true, "Whisper English-only is annotated")
                expect(EngineSettingsNotes.menuLanguageStatus(label: "Français", config: config).contains("only does English"), "menu says the model is English-only")
            }

            // QWEN3-ASR honors the language pick (AUTO detects), has no
            // built-in translate and no beam search, and no live preview.
            config.modelPath = Qwen3ASRVariant.large.modelPath
            config.language = "fr"
            let qwen = EngineSettingsNotes.notes(for: config)
            expect(qwen.languageAndTranslate?.contains("Qwen3-ASR picks the language itself on AUTO") == true, "Qwen3-ASR explains AUTO and the hint")
            expect(qwen.quietVoiceBoost?.contains("With Qwen3-ASR, only the level meter changes") == true, "quiet boost is honest on Qwen3-ASR")
            expect(!EngineSettingsNotes.translateApplies(for: config), "Whisper built-in translate does nothing on Qwen3-ASR")
            expectEqual(EngineSettingsNotes.menuLanguageTitle(for: config), "Dictation Language")
            expectEqual(EngineSettingsNotes.menuLanguageStatus(label: "Français", config: config), "Dictation language: Français.")
            config.livePreview = true
            expect(!LivePreviewPolicy.isEligible(config: config), "live preview stays Parakeet only")
            expect(LivePreviewPolicy.settingsNote(config: config).contains("only with Parakeet"), "the live preview caption says so")
        }
    }

    // MARK: - YA-35 / YA-73 setup copy

    private static func firstrunSetupCopyTests() {
        func accessibilityRow(firstRun: Bool, stale: Bool) -> SetupReadinessRow? {
            SetupReadinessPresenter.rows(for: SetupReadinessInput(
                isWhisperReady: true,
                isModelReady: true,
                isAccessibilityTrusted: false,
                pasteWhenFocusIsUnclear: true,
                allowModelDownloads: true,
                activeDownloadProgress: nil,
                isGuidedFirstRun: firstRun,
                isAccessibilityStale: stale
            )).first { $0.id == "accessibility" }
        }

        test("firstrun.autoPasteCopyFirstTimeVersusReinstall") {
            expectEqual(accessibilityRow(firstRun: true, stale: false)?.detail, AutoPastePrompt.firstTimeDetail)
            expect(accessibilityRow(firstRun: true, stale: true)?.detail.contains("older YappYapp") == true, "stale grant gets reinstall copy")
            expect(accessibilityRow(firstRun: false, stale: false)?.detail.contains("older YappYapp") == true, "a lost grant after setup is the reinstall case")
            expect(!AutoPastePrompt.firstTimeDetail.contains("old"), "first-time copy never mentions an old build")
        }

        test("firstrun.singleAutoPastePrompt") {
            // Wizard: no banner; the numbered step asks.
            expect(!AutoPastePrompt.showsBanner(accessibilityTrusted: false, autoPasteEnabled: true, isGuidedFirstRun: true), "no banner during the wizard")
            // After the wizard: the banner asks and the setup list does not.
            expect(AutoPastePrompt.showsBanner(accessibilityTrusted: false, autoPasteEnabled: true, isGuidedFirstRun: false), "banner after the wizard")
            let rows = SetupReadinessPresenter.guidedRows(for: SetupReadinessInput(
                isWhisperReady: true,
                isModelReady: true,
                isAccessibilityTrusted: false,
                pasteWhenFocusIsUnclear: true,
                allowModelDownloads: true,
                activeDownloadProgress: nil,
                isGuidedFirstRun: false
            ))
            expect(!rows.contains { $0.id == "accessibility" }, "the banner is the only prompt after setup")
            // Copy-only by choice, or already trusted: nothing asks.
            expect(!AutoPastePrompt.showsBanner(accessibilityTrusted: false, autoPasteEnabled: false, isGuidedFirstRun: false), "copy-only never nags")
            expect(!AutoPastePrompt.showsBanner(accessibilityTrusted: true, autoPasteEnabled: true, isGuidedFirstRun: false), "trusted has no banner")
            expectEqual(AutoPastePrompt.bannerActionTitle(isStale: true), "RESET")
            expectEqual(AutoPastePrompt.bannerActionTitle(isStale: false), "ALLOW")
            expect(AutoPastePrompt.bannerDetail(isStale: true).contains("older YappYapp"), "stale banner explains the reset")
            for text in [AutoPastePrompt.bannerTitle, AutoPastePrompt.bannerDetail(isStale: true), AutoPastePrompt.bannerDetail(isStale: false), AutoPastePrompt.firstTimeDetail] {
                expect(!text.lowercased().contains("trust") && !text.lowercased().contains("grant"), "no trusted or re-grant in: \(text)")
            }
            expect(AutoPastePrompt.firstTimeDetail.contains("System Settings > Privacy & Security > Accessibility"), "the full macOS path")
        }

        test("firstrun.dmgUsersSeeNoTerminalCopy") {
            let packaged = SetupReadinessPresenter.rows(for: SetupReadinessInput(
                isWhisperReady: false,
                isModelReady: true,
                isAccessibilityTrusted: true,
                pasteWhenFocusIsUnclear: true,
                allowModelDownloads: true,
                activeDownloadProgress: nil,
                isPackagedApp: true
            )).first { $0.id == "whisper-runtime" }
            expect(packaged?.detail.contains("brew") == false, "no Homebrew command for DMG users")
            expectEqual(packaged?.action, .showModels)
            expect(WhisperRuntimeCopy.missingDetail(isPackagedApp: false).contains("brew install"), "source builds keep the developer hint")
            expect(!WhisperRuntimeCopy.showsBinaryPathField(isPackagedApp: true), "DMG users do not edit a whisper-cli path")
            expect(WhisperRuntimeCopy.showsBinaryPathField(isPackagedApp: false), "source builds can edit it")
            expect(!WhisperRuntimeCopy.missingBlockedMessage(isPackagedApp: true, binaryPath: "/x/whisper-cli").contains("/x/"), "no path in DMG copy")
        }

        test("firstrun.setupCopyHasNoEmDashes") {
            let strings = [
                AutoPastePrompt.firstTimeDetail,
                AutoPastePrompt.bannerDetail(isStale: true),
                AutoPastePrompt.bannerDetail(isStale: false),
                WhisperRuntimeCopy.missingDetail(isPackagedApp: true),
                WhisperRuntimeCopy.missingBlockedMessage(isPackagedApp: true, binaryPath: ""),
                HotkeyStatusCopy.unavailableDetail,
                HotkeyStatusCopy.unavailableStatus,
                DownloadErrorCopy.offline, DownloadErrorCopy.integrity, DownloadErrorCopy.generic,
                MissingModelNotice(modelID: "a", modelName: "A", downloadsAllowed: true, downloadProgress: nil).message,
            ]
            for string in strings {
                expect(!string.contains("\u{2014}"), "em dash in: \(string)")
            }
        }
    }

    // MARK: - YA-33 / YA-75 chip and HUD

    private static func firstrunChipAndHUDTests() {
        test("firstrun.headerChipFollowsSetup") {
            expectEqual(HeaderChipPresenter.chip(phase: .idle, readiness: .notReady), HeaderChip(label: "NOT READY", tone: .setup))
            expectEqual(HeaderChipPresenter.chip(phase: .idle, readiness: .almostReady), HeaderChip(label: "ALMOST READY", tone: .setup))
            expectEqual(HomeReadiness.evaluate(canDictate: false, setupIncomplete: true), .notReady)
            expectEqual(HomeReadiness.evaluate(canDictate: false, setupIncomplete: false), .notReady)
            expectEqual(HomeReadiness.evaluate(canDictate: true, setupIncomplete: true), .almostReady)
            expectEqual(HomeReadiness.evaluate(canDictate: true, setupIncomplete: false), .ready)
            expect(!HomeReadiness.canDictate(isWhisperReady: true, isModelReady: false, isMicrophoneAuthorized: true), "no model, no dictation")
            expect(!HomeReadiness.canDictate(isWhisperReady: true, isModelReady: true, isMicrophoneAuthorized: false), "no mic, no dictation")
            expect(!HomeReadiness.canDictate(isWhisperReady: false, isModelReady: true, isMicrophoneAuthorized: true), "no Whisper, no dictation")
            expect(HomeReadiness.canDictate(isWhisperReady: true, isModelReady: true, isMicrophoneAuthorized: true), "all three, dictation")
            expectEqual(HeaderChipPresenter.chip(phase: .idle, readiness: .ready), HeaderChip(label: "READY", tone: .idle))
            expectEqual(HeaderChipPresenter.chip(phase: .error("x"), readiness: .ready).tone, .error)
            expectEqual(HeaderChipPresenter.chip(phase: .error("x"), readiness: .ready).label, "NEEDS ATTENTION")
            expectEqual(HeaderChipPresenter.chip(phase: .recording, readiness: .notReady).tone, .recording)
            expectEqual(HeaderChipPresenter.chip(phase: .pasted, readiness: .ready).tone, .success)
        }

        test("firstrun.homeHasOneAttentionSlotInPriorityOrder") {
            func slot(_ phase: CapturePhase, setup: Bool = false, hotkey: Bool = false, paste: Bool = false) -> HomeAttention? {
                HomeScreenPresenter.attention(phase: phase, hasSetupRows: setup, hotkeyUnavailable: hotkey, autoPasteNotAllowed: paste)
            }
            expectEqual(slot(.idle), nil)
            expectEqual(slot(.idle, setup: true, hotkey: true, paste: true), .setup, "a setup step wins")
            expectEqual(slot(.error("Boom"), setup: true), .setup, "setup beats an error")
            expectEqual(slot(.error("Boom"), hotkey: true, paste: true), .error("Boom"), "an error beats the shortcut")
            expectEqual(slot(.idle, hotkey: true, paste: true), .shortcutTaken, "the shortcut beats auto-paste")
            expectEqual(slot(.idle, paste: true), .autoPaste)
            expectEqual(slot(.pasted, paste: true), .autoPaste)

            // The green READY banner: idle and nothing to flag, never next
            // to an error, a setup step or a busy phase.
            expect(HomeScreenPresenter.showsReadyBanner(phase: .idle, attention: nil), "idle and set up")
            for phase: CapturePhase in [.recording, .transcribing, .pasted, .copied, .sentUnconfirmed,
                                        .notDelivered(headline: "NOT PASTED", reason: "x"), .canceled, .error("x")] {
                expect(!HomeScreenPresenter.showsReadyBanner(phase: phase, attention: nil), "no READY banner while \(phase)")
            }
            for attention: HomeAttention in [.setup, .error("x"), .shortcutTaken, .autoPaste] {
                expect(!HomeScreenPresenter.showsReadyBanner(phase: .idle, attention: attention), "no READY banner next to \(attention)")
            }
            expectEqual(HomeScreenPresenter.readyBannerTitle(autoPaste: true), "READY. TEXT PASTES AT YOUR CURSOR.")
            expect(!HomeScreenPresenter.readyBannerTitle(autoPaste: false).contains("PASTES"), "copy-only never promises a paste")
        }

        test("firstrun.homeHeadlineFollowsThePhase") {
            func headline(_ phase: CapturePhase, ready: Bool = true, cleaning: Bool = false, mode: RecordingMode = .toggle) -> String {
                HomeScreenPresenter.headline(phase: phase, canDictate: ready, isCleaning: cleaning, mode: mode)
            }
            expectEqual(headline(.idle), "PRESS TO TALK")
            expectEqual(headline(.idle, mode: .hold), "HOLD TO TALK")
            expectEqual(headline(.idle, mode: .hybrid), "TAP OR HOLD")
            expectEqual(headline(.idle, ready: false), "NOT READY YET", "fresh install")
            expectEqual(headline(.recording), "LISTENING")
            expectEqual(headline(.transcribing), "TRANSCRIBING")
            expectEqual(headline(.transcribing, cleaning: true), "CLEANING UP")
            expectEqual(headline(.pasted), "PASTED")
            expectEqual(headline(.copied), "COPIED")
            expectEqual(headline(.sentUnconfirmed), "PASTED?")
            expectEqual(headline(.notDelivered(headline: "NOT PASTED", reason: "x")), "NOT PASTED")
            expectEqual(headline(.canceled), "CANCELED")
            expectEqual(headline(.error("Boom")), "DIDN'T WORK")
            let missing = MissingModelNotice(modelID: "parakeet-v3", modelName: "Parakeet TDT v3", downloadsAllowed: true, downloadProgress: nil)
            expectEqual(headline(.error(missing.message), ready: false), "NOT READY YET", "a press without a model")
            // The mode wording is only for idle and ready.
            for phase: CapturePhase in [.recording, .transcribing, .pasted, .copied, .canceled, .error("x")] {
                expect(!["PRESS TO TALK", "HOLD TO TALK", "TAP OR HOLD"].contains(headline(phase)), "mode headline while \(phase)")
            }
            expect(!headline(.idle, ready: false).contains("TALK"), "never PRESS TO TALK before setup")

            // CLEANING UP follows the HUD note of any cleanup mode.
            expect(HomeScreenPresenter.isCleaning(phase: .transcribing, hudNote: CleanupMode.email.hudNote), "email cleanup")
            expect(HomeScreenPresenter.isCleaning(phase: .transcribing, hudNote: CleanupMode.clean.hudNote), "clean cleanup")
            expect(!HomeScreenPresenter.isCleaning(phase: .transcribing, hudNote: nil), "plain transcribing")
            expect(!HomeScreenPresenter.isCleaning(phase: .transcribing, hudNote: L10n.tr("TIME LIMIT")), "another note")
            expect(!HomeScreenPresenter.isCleaning(phase: .idle, hudNote: CleanupMode.clean.hudNote), "only while transcribing")
        }

        test("firstrun.tabRowGivesEveryLabelTheSameGap") {
            let widths = BrutalTabRowLayout.widths(ideal: [40, 80, 50, 40, 60], available: 400)
            expectEqual(widths.reduce(0, +), 400)
            for (cell, ideal) in zip(widths, [CGFloat(40), 80, 50, 40, 60]) {
                expectEqual(cell - ideal, 26, "equal spare room per tab")
            }
            let tight = BrutalTabRowLayout.widths(ideal: [100, 100, 100, 100, 100], available: 400)
            expectEqual(tight, [80, 80, 80, 80, 80], "too wide shrinks in proportion")
            expectEqual(BrutalTabRowLayout.widths(ideal: [], available: 400), [])
        }

        test("firstrun.homeStatusLineSaysEachThingOnce") {
            let prompt = StatusFlavor.idlePrompt[0]
            func line(_ text: String, _ phase: CapturePhase = .idle, _ attention: HomeAttention? = nil, ready: Bool = true, failure: String? = nil) -> String? {
                HomeScreenPresenter.statusLine(statusText: text, phase: phase, attention: attention, canDictate: ready, shortcutFailureText: failure)
            }
            expectEqual(line(prompt), prompt, "ready keeps the prompt")
            expectEqual(line(prompt, .idle, .setup, ready: false), "Finish the step below, then ⌥ space works in any app.", "no false promise before setup")
            expectEqual(line("Could not download it.", .idle, .setup, ready: false), "Could not download it.", "real news stays")
            expectEqual(line("Boom", .error("Boom"), .error("Boom")), nil, "the error row says it")
            expectEqual(line("Boom", .error("Boom"), .setup, ready: false), "Boom", "with the slot busy, the line keeps the error")
            expectEqual(line(prompt, .idle, .shortcutTaken), nil, "a dead shortcut is never promised")
            expectEqual(line("Could not register it.", .idle, .shortcutTaken, failure: "Could not register it."), nil, "the shortcut row says it")
            expectEqual(line("Pasted.", .pasted, .shortcutTaken), "Pasted.", "outcomes still show")

            // RETRY sits in the error row, so the menu path goes.
            let message = "Transcription took too long. " + DictationFailurePresenter.retryHint
            let detail = HomeScreenPresenter.errorDetail(message: message, retryOffered: true)
            expect(!detail.contains(DictationFailurePresenter.retryHint), "no menu path next to RETRY")
            expect(detail.hasPrefix("Transcription took too long."), "the reason stays")
            expect(detail.hasSuffix(L10n.tr("Your audio is kept.")), "says the audio is safe")
            expectEqual(HomeScreenPresenter.errorDetail(message: message, retryOffered: false), message, "no RETRY, full message")

            expect(!HomeScreenPresenter.showsTips(guidedSetupDone: false), "no tips during first run")
            expect(HomeScreenPresenter.showsTips(guidedSetupDone: true), "tips after first run")
            expect(!HomeScreenPresenter.showsGuidedMicCheck(canTranscribe: false), "no mic check before the model")
        }

        test("firstrun.hudLabelsAreWords") {
            let missing = MissingModelNotice(modelID: "parakeet-v3", modelName: "Parakeet TDT v3", downloadsAllowed: true, downloadProgress: nil)
            expectEqual(HUDLabelPresenter.trailingLabel(phase: .pasted, recordingSeconds: 0), "PASTED")
            expectEqual(HUDLabelPresenter.trailingLabel(phase: .copied, recordingSeconds: 0), "COPIED")
            expectEqual(HUDLabelPresenter.trailingLabel(phase: .idle, recordingSeconds: 0), "READY")
            expectEqual(HUDLabelPresenter.trailingLabel(phase: .error("Mic failed"), recordingSeconds: 0), "DIDN'T WORK")
            expectEqual(HUDLabelPresenter.trailingLabel(phase: .error(missing.message), recordingSeconds: 0), "NO MODEL")
            expectEqual(HUDLabelPresenter.trailingLabel(phase: .recording, recordingSeconds: 75), "1:15")
            for phase: CapturePhase in [.idle, .pasted, .copied, .error("x")] {
                let label = HUDLabelPresenter.trailingLabel(phase: phase, recordingSeconds: 0)
                expect(!["IN", "ERR", "RDY"].contains(label), "cryptic HUD label \(label)")
            }
        }

        test("firstrun.modelRowNotes") {
            expectEqual(ModelRowStatus.note(isInstalled: true, downloadsAllowed: false, downloadError: "x"), nil)
            // The chip already says FAILED, so the note is only the reason.
            expectEqual(
                ModelRowStatus.note(isInstalled: false, downloadsAllowed: true, downloadError: DownloadErrorCopy.offline),
                ModelRowStatus(text: DownloadErrorCopy.offline, isError: true)
            )
            // "Downloads are off" is said once, by the chip and footnote.
            expectEqual(ModelRowStatus.note(isInstalled: false, downloadsAllowed: false, downloadError: nil), nil)
            expectEqual(ModelRowStatus.note(isInstalled: false, downloadsAllowed: true, downloadError: nil), nil)
        }

        test("models.chipVocabulary") {
            func chip(installed: Bool = false, selected: Bool = false, progress: Double? = nil, error: String? = nil, allowed: Bool = true) -> ModelRowChip {
                ModelRowChip.state(isInstalled: installed, isSelected: selected, downloadProgress: progress, downloadError: error, downloadsAllowed: allowed)
            }
            expectEqual(chip(), .download)
            expectEqual(chip(progress: 0.42), .downloading(percent: 42))
            expectEqual(chip(progress: -1), .preparing)
            expectEqual(chip(installed: true), .downloaded)
            expectEqual(chip(installed: true, selected: true), .inUse)
            expectEqual(chip(error: "offline"), .failed)
            expectEqual(chip(allowed: false), .downloadsOff)
            expectEqual(chip(installed: true, allowed: false), .downloaded, "an installed model works with downloads off")
            expectEqual(chip(progress: 0.5, error: "old"), .downloading(percent: 50), "a retry hides the old failure")
            expectEqual(
                [ModelRowChip.download, .downloading(percent: 42), .preparing, .downloaded, .inUse, .failed, .downloadsOff].map(\.text),
                ["DOWNLOAD", "42%", "PREPARING\u{2026}", "DOWNLOADED", "IN USE", "FAILED", "DOWNLOADS OFF"]
            )
        }

        test("models.recommendedIsTheDefault") {
            expectEqual(ModelCatalog.recommendedID, ModelCatalog.selectedID(for: AppConfig.defaultConfig.modelPath))
            let recommended = ModelCatalog.options.filter(ModelListPolicy.isRecommended)
            expectEqual(recommended.map(\.id), ["parakeet-ultra"])
        }

        test("models.everyRowHasAVerifiedSize") {
            for option in ModelCatalog.options {
                expect((option.downloadBytes ?? 0) > 0, "\(option.id) has a size")
                expect(option.sizeLabel != nil, "\(option.id) shows a size")
            }
            // The summaries no longer carry a size of their own.
            expect(!ModelCatalog.options.contains { $0.summary.contains("GB") }, "no size inside summaries")
        }

        test("models.whisperCollapsesUnlessInPlay") {
            let parakeet = ModelCatalog.recommendedID
            expectEqual(ModelListPolicy.whisperOpensByDefault(selectedID: parakeet, downloads: [:], errors: [:]), false)
            expectEqual(ModelListPolicy.whisperOpensByDefault(selectedID: "small-en", downloads: [:], errors: [:]), true, "in use")
            expectEqual(ModelListPolicy.whisperOpensByDefault(selectedID: parakeet, downloads: ["medium": 0.1], errors: [:]), true, "downloading")
            expectEqual(ModelListPolicy.whisperOpensByDefault(selectedID: parakeet, downloads: [:], errors: ["tiny": "x"]), true, "failed row stays visible")
            expectEqual(ModelListPolicy.whisperOpensByDefault(selectedID: parakeet, downloads: ["parakeet-ja": 0.1], errors: ["parakeet-ja": "x"]), false, "Parakeet activity keeps it closed")
        }

        test("models.parakeetGroupIsCollapsibleLikeWhisper") {
            expect(ModelListPolicy.parakeetOpensByDefault, "Parakeet starts open")
            // Same rule for both families: the default until the user clicks.
            expect(ModelGroupDisclosure.isOpen(userChoice: nil, opensByDefault: true), "default open")
            expect(!ModelGroupDisclosure.isOpen(userChoice: false, opensByDefault: true), "Parakeet can be closed")
            expect(ModelGroupDisclosure.isOpen(userChoice: true, opensByDefault: false), "Whisper can be opened")
            expect(!ModelGroupDisclosure.isOpen(userChoice: nil, opensByDefault: false), "default closed")
            expectEqual(ModelGroupDisclosure.chevron(isOpen: true), "\u{25B2}")
            expectEqual(ModelGroupDisclosure.chevron(isOpen: false), "\u{25BC}")
            let parakeetCount = ModelCatalog.options.filter { $0.engine == .parakeet }.count
            expectEqual(ModelGroup.parakeet.title(count: parakeetCount), "PARAKEET (\(parakeetCount))")
            expectEqual(ModelGroup.whisper.title(count: 10), "WHISPER (10)")
            // One header component for both families; open and closed differ.
            MainActor.assumeIsolated {
                let open = renderPixelSnapshot(BrutalistPopoverView.ModelGroupHeader(group: .parakeet, count: 4, isOpen: true), width: 404, height: 28)
                let closed = renderPixelSnapshot(BrutalistPopoverView.ModelGroupHeader(group: .parakeet, count: 4, isOpen: false), width: 404, height: 28)
                let whisper = renderPixelSnapshot(BrutalistPopoverView.ModelGroupHeader(group: .whisper, count: 10, isOpen: false), width: 404, height: 28)
                expect(open != nil && closed != nil && whisper != nil, "headers render")
                expect(open?.fingerprint != closed?.fingerprint, "the chevron flips")
                let selected = renderPixelSnapshot(ModelChoiceMark(isSelected: true), width: 18, height: 18)
                let unselected = renderPixelSnapshot(ModelChoiceMark(isSelected: false), width: 18, height: 18)
                expect(selected?.fingerprint != unselected?.fingerprint, "the model in use is marked")
            }
        }
    }

    // MARK: - YA-34 download errors

    private static func firstrunDownloadErrorTests() {
        test("firstrun.downloadErrorsArePlain") {
            expectEqual(DownloadErrorCopy.plain(URLError(.notConnectedToInternet)), DownloadErrorCopy.offline)
            expectEqual(DownloadErrorCopy.plain(URLError(.timedOut)), DownloadErrorCopy.timedOut)
            expectEqual(DownloadErrorCopy.plain(URLError(.networkConnectionLost)), DownloadErrorCopy.timedOut)
            expect(DownloadErrorCopy.plain(URLError(.cannotFindHost)).contains("Hugging Face"), "host failures name the server")
            expectEqual(
                DownloadErrorCopy.plain(NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)),
                DownloadErrorCopy.offline
            )
            expectEqual(
                DownloadErrorCopy.plain(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)),
                DownloadErrorCopy.diskFull
            )
            expectEqual(DownloadErrorCopy.plain(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))), DownloadErrorCopy.diskFull)
            expectEqual(
                DownloadErrorCopy.plain(WhisperError.serverFailed("Integrity mismatch for a.bin: expected 1, got 2.")),
                DownloadErrorCopy.integrity
            )
            expectEqual(
                DownloadErrorCopy.plain(WhisperError.serverFailed("Hugging Face rate limit encountered while listing Parakeet files.")),
                DownloadErrorCopy.serverBusy
            )
            expectEqual(DownloadErrorCopy.plain(WhisperError.serverFailed("Something odd.")), DownloadErrorCopy.generic)
            for error: Error in [URLError(.badServerResponse), URLError(.notConnectedToInternet), NSError(domain: "x", code: 1)] {
                let plain = DownloadErrorCopy.plain(error)
                expect(!plain.contains("NSURLError") && !plain.contains("Error Domain") && !plain.contains("-1009"), "raw error leaked: \(plain)")
            }
            expectEqual(
                DownloadErrorCopy.status(optionName: "Parakeet TDT v3", plain: DownloadErrorCopy.offline),
                "Couldn't download Parakeet TDT v3. No internet connection. Connect and try again."
            )
        }
    }

    // MARK: - YA-72 / YA-73

    private static func firstrunHotkeyAndRuntimeTests() {
        test("firstrun.hotkeyFailureCopy") {
            expect(HotkeyStatusCopy.listeningStatus(hotkeyAvailable: true).contains("⌥ space"), "working shortcut is named")
            expect(!HotkeyStatusCopy.listeningStatus(hotkeyAvailable: false).contains("⌥ space"), "dead shortcut is not offered")
            expect(!HotkeyStatusCopy.tooltip(hotkeyAvailable: false).contains("⌥ space to dictate"), "tooltip does not promise a dead shortcut")
            expect(HotkeyStatusCopy.unavailableDetail.contains("Another app"), "plain explanation")
        }

        test("firstrun.hotkeyStateStaysSet") {
            let state = YappYappState()
            state.hotkeyUnavailable = true
            state.statusText = "Setup saved."
            expect(state.hotkeyUnavailable, "the failure flag outlives later status text")
        }
    }

    // MARK: - YA-27 / YA-28

    private static func firstrunWindowAndMenuTests() {
        test("firstrun.controlWindowLaunchPolicy") {
            expect(ControlWindowLaunchPolicy.opensOnLaunch(setupComplete: false, launchedAsLoginItem: true), "incomplete setup always opens")
            expect(ControlWindowLaunchPolicy.opensOnLaunch(setupComplete: false, launchedAsLoginItem: false), "incomplete setup always opens")
            expect(ControlWindowLaunchPolicy.opensOnLaunch(setupComplete: true, launchedAsLoginItem: false), "a manual launch opens")
            expect(!ControlWindowLaunchPolicy.opensOnLaunch(setupComplete: true, launchedAsLoginItem: true), "a login launch stays in the menu bar")

            let openApp = UInt32(kAEOpenApplication)
            let loginItem = UInt32(keyAELaunchedAsLogInItem)
            expect(ControlWindowLaunchPolicy.isLoginItemLaunch(eventID: openApp, propData: loginItem), "login item event")
            expect(!ControlWindowLaunchPolicy.isLoginItemLaunch(eventID: openApp, propData: nil), "plain open")
            expect(!ControlWindowLaunchPolicy.isLoginItemLaunch(eventID: nil, propData: nil), "no event")
        }

        test("firstrun.mainMenuHasStandardShortcuts") {
            let target = NSObject()
            let menu = MainMenuBuilder.make(
                target: target,
                openSettings: #selector(NSObject.description),
                quit: #selector(NSObject.debugDescription)
            )
            expectEqual(menu.items.map(\.title), ["YappYapp", "Edit", "Window"])

            func item(_ menuTitle: String, _ title: String) -> NSMenuItem? {
                menu.items.first { $0.title == menuTitle }?.submenu?.items.first { $0.title == title }
            }

            let expected: [(String, String, String, String)] = [
                ("Edit", "Undo", "z", "undo:"),
                ("Edit", "Redo", "z", "redo:"),
                ("Edit", "Cut", "x", "cut:"),
                ("Edit", "Copy", "c", "copy:"),
                ("Edit", "Paste", "v", "paste:"),
                ("Edit", "Select All", "a", "selectAll:"),
                ("Window", "Close", "w", "performClose:"),
                ("Window", "Minimize", "m", "performMiniaturize:"),
                ("YappYapp", "Quit YappYapp", "q", "debugDescription"),
                ("YappYapp", "Setup…", ",", "description"),
                ("YappYapp", "About YappYapp", "", "orderFrontStandardAboutPanel:"),
            ]
            for (menuTitle, title, key, action) in expected {
                guard let found = item(menuTitle, title) else {
                    expect(false, "missing menu item \(menuTitle) > \(title)")
                    continue
                }
                expectEqual(found.keyEquivalent, key, "\(title) key")
                expectEqual(found.action.map(NSStringFromSelector), action, "\(title) action")
            }
            expectEqual(item("Edit", "Redo")?.keyEquivalentModifierMask, [.command, .shift])
            expect(item("Edit", "Paste")?.target == nil, "Paste goes to the first responder")
            expect(item("YappYapp", "Quit YappYapp")?.target === target, "Quit goes to the app delegate")
        }
    }

    // MARK: - YA-38 feedback

    private static func firstrunFeedbackTests() {
        test("firstrun.stickyErrorsSurviveRoutineSuccess") {
            let saveError = TabFeedback.error("Setup wasn't saved.", topic: "save")
            let loginError = TabFeedback.error("Could not change the login item.", topic: "login-item")
            let saved = TabFeedback.success("Setup saved.", topic: "save")

            expectEqual(TabFeedbackPolicy.merge(existing: loginError, incoming: saved), loginError)
            expectEqual(TabFeedbackPolicy.merge(existing: saveError, incoming: saved), saved)
            let newer = TabFeedback.error("Another failure.", topic: "x")
            expectEqual(TabFeedbackPolicy.merge(existing: loginError, incoming: newer), newer)
            expectEqual(TabFeedbackPolicy.merge(existing: nil, incoming: saved), saved)
            expectEqual(TabFeedbackPolicy.merge(existing: saved, incoming: TabFeedback.info("Note", topic: "y")).text, "Note")
            expectEqual(saveError.autoDismissAfter, nil)
            expectEqual(saved.autoDismissAfter, 4.0)
        }

        test("firstrun.feedbackStaysOnItsTab") {
            var map: [BrutalTab: TabFeedback] = [:]
            let failure = TabFeedback.error("Could not download Parakeet TDT v3.", topic: "download.parakeet-v3")
            map = TabFeedbackPolicy.post(failure, to: .models, in: map)
            map = TabFeedbackPolicy.post(.success("Setup saved.", topic: "save"), to: .settings, in: map)
            expectEqual(map[.models], failure)
            expectEqual(map[.settings]?.text, "Setup saved.")
            expectEqual(map[.home], nil)

            let expiredError = TabFeedbackPolicy.expire(failure.id, on: .models, in: map)
            expectEqual(expiredError[.models], failure, "errors never time out")
            let staleTimer = TabFeedbackPolicy.expire(UUID(), on: .settings, in: map)
            expectEqual(staleTimer[.settings]?.text, "Setup saved.", "an old timer never clears a newer message")
            let expired = TabFeedbackPolicy.expire(map[.settings]!.id, on: .settings, in: map)
            expectEqual(expired[.settings], nil)
            expectEqual(TabFeedbackPolicy.dismiss(on: .models, in: map)[.models], nil)
        }

        test("firstrun.stateFeedbackAndStatusLine") {
            let state = YappYappState()
            state.postFeedback(.error("Could not change the login item.", topic: "login-item"), on: .settings)
            state.postFeedback(.success("Setup saved.", topic: "save"), on: .settings)
            expectEqual(state.tabFeedback[.settings]?.text, "Could not change the login item.")
            state.dismissFeedback(on: .settings)
            expectEqual(state.tabFeedback[.settings], nil)

            expect(!StatusLinePolicy.shouldReplace(currentPhase: .error("x"), withRoutineSuccess: true), "a routine success keeps the error")
            expect(StatusLinePolicy.shouldReplace(currentPhase: .error("x"), withRoutineSuccess: false), "a new error replaces it")
            expect(StatusLinePolicy.shouldReplace(currentPhase: .idle, withRoutineSuccess: true), "idle accepts a success")
        }
    }

    // MARK: - Render smoke

    private static func firstrunRenderTests() {
        test("firstrun.surfacesRender") {
            let state = YappYappState()
            state.isModelReady = false
            state.isWhisperReady = true
            state.hotkeyUnavailable = true
            state.phase = .error(MissingModelNotice(modelID: "parakeet-v3", modelName: "Parakeet TDT v3", downloadsAllowed: true, downloadProgress: nil).message)
            state.modelDownloadErrors["parakeet-v2"] = DownloadErrorCopy.offline
            state.modelDownloads["parakeet-110m"] = 0.4
            state.tabFeedback[.home] = .error("Setup wasn't saved.", topic: "save")

            let popover = BrutalistPopoverView(
                state: state,
                onToggleRecording: {}, onSelectModel: { _ in }, onDownloadModel: { _ in },
                onCancelDownload: { _ in }, onSaveConfig: { _ in }, onSaveGlossary: { _ in },
                onRequestAccessibility: {}, onResetAndRegrantAccessibility: {},
                onRequestMicrophone: {}, onOpenMicrophoneSettings: {},
                onSetLaunchAtLogin: { _ in }, onChooseStarter: { _ in },
                onEquipAccessory: { _ in }, onSaveRecap: {}, onCopyText: { _ in },
                onRevealSupport: {}, onQuit: {}
            )
            expectEqual(popover.headerChip.label, "NEEDS ATTENTION")
            expect(renderImage(popover, width: 440, height: 596) != nil, "popover renders")
            expect(renderImage(popover.homeTab, width: 440, height: 596) != nil, "home renders")
            expect(renderImage(popover.modelsTab, width: 440, height: 596) != nil, "models renders")
            expect(renderImage(popover.settingsTab, width: 440, height: 900) != nil, "settings renders")
            expect(renderImage(BrutalistHUDView(state: state), width: 320, height: 56) != nil, "HUD renders")

            state.phase = .idle
            expectEqual(popover.headerChip.label, "NOT READY", "idle without a model is not READY")
        }
    }
}
#endif
