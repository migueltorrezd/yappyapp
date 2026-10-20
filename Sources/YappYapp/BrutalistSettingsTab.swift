import SwiftUI

extension BrutalistPopoverView {
    // MARK: - Settings

    var settingsTab: some View {
        BrutalScroll {
            VStack(spacing: BrutalControl.sectionSpacing) {
                // SETUP-ORDER: sections by how often people change them and
                // what they need first, driven by SetupSection so the
                // self-test pins the order.
                ForEach(SetupSection.allCases) { section in
                    setupSection(section)
                }

                setupFooter
            }
            .padding(.bottom, Brutal.drop)
            .padding(.trailing, Brutal.drop)
        }
        .scrollIndicators(.never)
    }

    @ViewBuilder
    private func setupSection(_ section: SetupSection) -> some View {
        switch section {
        case .dictation: dictationSection
        case .microphone: microphoneSection
        case .pasting: pastingSection
        case .appProfiles:
            BrutalSettingsCard(section.title) {
                AppProfilesSettingsSection(
                    profiles: $configDraft.appProfiles,
                    lockedKeys: state.managedConfigKeys,
                    modelChoices: ModelCatalog.options.filter(\.isInstalled),
                    cleanupModelInstalled: LLMCleaner.isModelInstalled(),
                    candidateProvider: { ProfileAppCandidates.current(existing: configDraft.appProfiles) }
                )
            }
        case .indicatorAndSound: indicatorAndSoundSection
        case .speed: speedSection
        case .app: appSection
        case .help: SupportReportSection(state: state, onCopy: onCopyText, onRevealSupport: onRevealSupport)
        }
    }

    // MARK: - DICTATION

    private var dictationSection: some View {
        BrutalSettingsCard(SetupSection.dictation.title) {
            BrutalGroupBreak(L10n.tr("KEYS"), first: true)
            ShortcutSettingsSection(
                settings: $configDraft.shortcuts,
                cancelEnabled: $configDraft.escCancelsRecording,
                isAccessibilityTrusted: state.isAccessibilityTrusted
            )

            BrutalGroupBreak(L10n.tr("LANGUAGE AND TEXT"))

            VStack(alignment: .leading, spacing: BrutalControl.innerSpacing) {
                BrutalRowLabel(L10n.tr("DICTATION LANGUAGE"))
                BrutalSegmented(
                    choices: LanguageCatalog.options.map { BrutalChoice(value: $0.code, title: $0.brutalLabel) },
                    selection: configDraft.language,
                    hint: L10n.tr("Used from your next dictation")
                ) { configDraft.language = $0 }
                // YA-24: one caption for what the selected model ignores,
                // instead of a Parakeet/Whisper note under every row.
                if let note = engineNotes.languageAndTranslate {
                    BrutalCaption(note)
                }
            }
            .managedLock(state.managedConfigKeys.contains(.language), placement: .below)

            // YA-10: mode picker plus model status.
            CleanupSettingsControl(
                mode: $configDraft.cleanup,
                readiness: state.cleanupReadiness,
                onDownload: onDownloadCleanupModel,
                onCancel: onCancelCleanupDownload
            )

            // NUMBERS: works with cleanup off too; an admin can lock it.
            NumberSettingsControl(style: $configDraft.numbers)
                .managedLock(state.managedConfigKeys.contains(.numberStyle), placement: .below)

            BrutalSwitchRow(L10n.tr("DROP \"UM\" AND \"UH\""), isOn: $configDraft.removeFillerWords, caption: L10n.tr("Works without the cleanup model. Cleanup modes do this anyway."))
            BrutalSwitchRow(L10n.tr("SPOKEN COMMANDS"), isOn: $configDraft.spokenCommands, caption: SpokenCommandCopy.settingsNote)
            // LEARN-FROM-FIXES: on by default; an admin can lock it.
            BrutalSwitchRow(LearnFromFixesCopy.settingTitle, isOn: $configDraft.learnFromFixes, caption: LearnFromFixesCopy.settingCaption)
                .managedLock(state.managedConfigKeys.contains(.learnFromFixes))
            // TRANSLATION (round 2): a target language and which model does it.
            TranslationSettingsControl(
                target: $configDraft.translateTarget,
                plan: configDraft.translationPlan,
                readiness: TranslationReadiness.evaluate(
                    plan: configDraft.translationPlan,
                    snapshot: state.translationModels,
                    downloadsAllowed: configDraft.allowModelDownloads
                ),
                onDownload: { configDraft.translationPlan.modelID.map(onDownloadTranslationModel) },
                onCancel: { configDraft.translationPlan.modelID.map(onCancelTranslationDownload) }
            )
        }
    }

    // MARK: - MICROPHONE

    private var microphoneSection: some View {
        BrutalSettingsCard(SetupSection.microphone.title) {
            micPicker

            // The check tests the mic picked right above it.
            MicCheckSettingsSection(state: state, deviceUID: configDraft.inputDeviceUID, quietVoiceBoost: $configDraft.quietVoiceBoost)

            BrutalGroupBreak()

            BrutalSwitchRow(L10n.tr("QUIET VOICE BOOST"), isOn: $configDraft.quietVoiceBoost, caption: engineNotes.quietVoiceBoost)

            VStack(alignment: .leading, spacing: BrutalControl.innerSpacing) {
                HStack(spacing: 10) {
                    BrutalRowLabel(L10n.tr("STOP AUTOMATICALLY AFTER"))
                    Spacer(minLength: 8)
                    Text(durationLabel)
                        .brutalText(.value)
                        .foregroundStyle(Brutal.ink)
                }

                BrutalSlider(
                    value: $configDraft.maxRecordingSeconds,
                    range: 30...900,
                    step: 30,
                    accessibilityLabel: L10n.tr("Auto-stop duration"),
                    hint: L10n.tr("Sets the maximum length of one recording"),
                    valueText: durationLabel
                )
            }
        }
    }

    // The same floating dropdown as every other "pick one of many" control.
    private var micPicker: some View {
        BrutalDropdown(
            title: microphoneLabel,
            accessibilityLabel: L10n.tr("Microphone"),
            hint: L10n.tr("Expands the microphone list"),
            leadingSymbol: "mic.fill"
        ) {
            [micOption(L10n.tr("MAC DEFAULT MIC"), uid: nil)]
                + state.inputDevices.map { micOption($0.name, uid: $0.uid) }
        }
        .help(L10n.tr("Mic used for your next dictation"))
    }

    private func micOption(_ title: String, uid: String?) -> BrutalMenuItem {
        BrutalMenuItem(
            id: uid ?? "mac-default",
            title: title,
            selected: configDraft.inputDeviceUID == uid,
            accessibilityLabel: title,
            hint: L10n.tr("Uses this mic for your next dictation")
        ) {
            configDraft.inputDeviceUID = uid
        }
    }

    // MARK: - PASTING

    private var pastingSection: some View {
        BrutalSettingsCard(SetupSection.pasting.title) {
            // YA-17: the real master switch. Off means copy only, everywhere.
            // The permission buttons belong to this row, so they sit tight
            // under it.
            VStack(alignment: .leading, spacing: BrutalControl.innerSpacing) {
                BrutalSwitchRow(
                    L10n.tr("AUTO-PASTE AT THE CURSOR"),
                    isOn: $configDraft.autoPaste,
                    caption: L10n.tr("Your text pastes where you're typing. Off, it's only copied for ⌘V.")
                )
                .managedLock(state.managedConfigKeys.contains(.autoPaste))

                if !state.isAccessibilityTrusted {
                    Button(L10n.tr("ALLOW AUTO-PASTE"), action: onRequestAccessibility)
                        .buttonStyle(BrutalTextButtonStyle(fill: Brutal.blue, text: Brutal.paper))
                        .brutalInteractive(
                            label: L10n.tr("Allow auto-paste"),
                            hint: L10n.tr("Opens the macOS Accessibility permission flow"),
                            value: L10n.tr("Disabled"),
                            hitExpansion: 5
                        )
                }

                // STALE-TCC-DETECT: secondary recovery, only when the detector
                // suspects a stale or duplicate TCC entry.
                if !state.isAccessibilityTrusted, state.staleAccessibility != .clean {
                    BrutalActionButton(
                        title: PasteOutcomePresenter.staleResetButtonTitle,
                        accessibilityLabel: PasteOutcomePresenter.staleResetButtonTitle,
                        hint: L10n.tr("Resets the stale permission entry and opens the macOS Accessibility flow"),
                        fillsWidth: true,
                        action: onResetAndRegrantAccessibility
                    )
                }
            }

            BrutalSwitchRow(
                L10n.tr("PASTE WHEN NO TEXT FIELD IS FOUND"),
                isOn: $configDraft.pasteWhenFocusIsUnclear,
                caption: L10n.tr("Some apps hide their text fields. This pastes anyway instead of only copying.")
            )

            BrutalGroupBreak()
            // Esc-cancel lives in DICTATION > CANCEL only (one control).
            BrutalSwitchRow(
                L10n.tr("SHOW TEXT IN NOTIFICATIONS"),
                isOn: $configDraft.showTextInNotifications,
                caption: L10n.tr("Notifications include your text. They can show on the lock screen and stay in Notification Center.")
            )
        }
    }

    // MARK: - INDICATOR AND SOUND

    private var indicatorAndSoundSection: some View {
        BrutalSettingsCard(SetupSection.indicatorAndSound.title) {
            VStack(alignment: .leading, spacing: BrutalControl.innerSpacing) {
                BrutalRowLabel(L10n.tr("INDICATOR POSITION"))
                BrutalSegmented(
                    choices: SetupChoices.indicatorPositions.map { position in
                        BrutalChoice(
                            value: position.value,
                            title: position.title,
                            accessibilityLabel: L10n.tr("Indicator %@", position.title.lowercased())
                        )
                    },
                    selection: configDraft.hudPosition,
                    hint: L10n.tr("Where the indicator shows while you dictate")
                ) { configDraft.hudPosition = $0 }
            }

            // LIVE-PREVIEW: words so far in the indicator, never pasted.
            BrutalSwitchRow(
                L10n.tr("SHOW WORDS WHILE I TALK"),
                isOn: $configDraft.livePreview,
                caption: LivePreviewPolicy.settingsNote(config: configDraft)
            )

            BrutalGroupBreak()
            BrutalSwitchRow(L10n.tr("PLAY SOUNDS"), isOn: $configDraft.playSounds)
        }
    }

    // MARK: - SPEED

    private var speedSection: some View {
        BrutalSettingsCard(SetupSection.speed.title) {
            BrutalSwitchRow(
                L10n.tr("KEEP THE MODEL LOADED"),
                isOn: $configDraft.keepModelWarm,
                caption: L10n.tr("Dictations finish sooner, but YappYapp uses more memory.")
            )

            VStack(alignment: .leading, spacing: BrutalControl.innerSpacing) {
                BrutalSwitchRow(
                    L10n.tr("INSTANT START"),
                    isOn: $configDraft.superFastMode,
                    caption: L10n.tr("Dictation starts the moment you press, so your first word is never cut off.")
                )
                // SUPER-FAST-MODE: the ring is RecordingController.warmRingCapacity (1.5 s).
                BrutalCaption(L10n.tr("The mic stays on, so the orange dot never goes away. Only the last 1.5 seconds stay in memory."), tone: .warning)
            }
        }
    }

    // MARK: - APP

    private var appSection: some View {
        BrutalSettingsCard(SetupSection.app.title) {
            BrutalGroupBreak(L10n.tr("LOOK"), first: true)
            // L10N: the interface language, apart from dictation.
            appLanguageRow

            textSizeRow

            BrutalSwitchRow(
                L10n.tr("PET AND QUESTS"),
                isOn: $configDraft.petEnabled,
                caption: L10n.tr("A pet that grows as you dictate, with quests and streaks.")
            )
            .managedLock(state.managedConfigKeys.contains(.petEnabled))

            // The only rows that reach the internet sit together.
            BrutalGroupBreak(L10n.tr("STARTUP AND INTERNET"))

            VStack(alignment: .leading, spacing: BrutalControl.innerSpacing) {
                BrutalSwitchRow(L10n.tr("START AT LOGIN"), isOn: Binding(
                    get: { state.launchAtLoginEnabled },
                    set: { onSetLaunchAtLogin($0) }
                ))
                if state.launchAtLoginNeedsApproval {
                    LoginItemApprovalRow(onOpenLoginItems: LaunchAtLogin.openLoginItemsSettings)
                }
            }

            BrutalSwitchRow(
                L10n.tr("ALLOW MODEL DOWNLOADS"),
                isOn: $configDraft.allowModelDownloads,
                caption: L10n.tr("Lets YappYapp get voice and cleanup models from Hugging Face.")
            )
            .managedLock(state.managedConfigKeys.contains(.allowModelDownloads))

            VStack(alignment: .leading, spacing: BrutalControl.innerSpacing) {
                BrutalSwitchRow(L10n.tr("CHECK FOR UPDATES DAILY"), isOn: $configDraft.automaticUpdateChecks)
                    .help(L10n.tr("Once a day, asks GitHub for the latest YappYapp version. Sends only version numbers."))
                    .managedLock(state.managedConfigKeys.contains(.automaticUpdateChecks))
                HStack(alignment: .center, spacing: 10) {
                    BrutalCaption(L10n.tr("Sends only version numbers to GitHub."))
                    BrutalActionButton(
                        title: L10n.tr("CHECK NOW"),
                        accessibilityLabel: L10n.tr("Check for updates now"),
                        hint: L10n.tr("Checks the YappYapp release feed on GitHub"),
                        action: onCheckForUpdates
                    )
                }
            }

            // YA-73: a developer setting; DMG installs ship the engine.
            if WhisperRuntimeCopy.showsBinaryPathField(isPackagedApp: WhisperRuntimeCopy.isPackagedApp) {
                BrutalGroupBreak(L10n.tr("ADVANCED"))
                BrutalField(
                    label: L10n.tr("whisper-cli path"),
                    placeholder: "/opt/homebrew/bin/whisper-cli",
                    text: $configDraft.whisperBinaryPath
                )
            }
        }
    }

    // MARK: - Footer

    private var setupFooter: some View {
        VStack(alignment: .leading, spacing: BrutalControl.innerSpacing) {
            HStack(spacing: 10) {
                BrutalActionButton(
                    title: L10n.tr("QUIT YAPPYAPP"),
                    accessibilityLabel: L10n.tr("Quit YappYapp"),
                    hint: L10n.tr("Quits and clears your history"),
                    tone: .danger,
                    action: onQuit
                )
                BrutalCaption(L10n.tr("Quitting clears history."))
            }

            BrutalCaption(L10n.tr("Setup saves as you go."))
        }
    }

    private var microphoneLabel: String {
        guard let uid = configDraft.inputDeviceUID else { return L10n.tr("MAC DEFAULT MIC") }
        // The recorder falls back to the Mac default when the picked mic is gone.
        return state.inputDevices.first(where: { $0.uid == uid })?.name ?? L10n.tr("MIC DISCONNECTED · USING DEFAULT")
    }

    private var durationLabel: String {
        let seconds = Int(configDraft.maxRecordingSeconds)
        if seconds < 60 {
            return L10n.tr("%@S", "\(seconds)")
        }
        let minutes = seconds / 60
        let remainder = seconds % 60
        return remainder == 0 ? L10n.tr("%@MIN", "\(minutes)") : L10n.tr("%@MIN %@S", "\(minutes)", "\(remainder)")
    }
}

/// SETUP-ORDER: the SETUP sections, top to bottom. The raw value is the
/// English header key. Ordered by how often people change them: how to
/// dictate, the mic, where text goes, per-app tweaks, then the rarer rows.
enum SetupSection: String, CaseIterable, Identifiable {
    case dictation = "DICTATION"
    case microphone = "MICROPHONE"
    case pasting = "PASTING"
    case appProfiles = "APP PROFILES"
    case indicatorAndSound = "INDICATOR AND SOUND"
    case speed = "SPEED"
    case app = "APP"
    case help = "HELP"

    var id: String { rawValue }

    var title: String { L10n.tr(rawValue) }
}

/// Option lists for Setup choices that have no enum of their own.
enum SetupChoices {
    /// INDICATOR POSITION, stored as `hudPosition`.
    static var indicatorPositions: [(value: String, title: String)] {
        [
            ("bottom", L10n.tr("BOTTOM")),
            ("top", L10n.tr("TOP")),
            ("left", L10n.tr("LEFT")),
            ("right", L10n.tr("RIGHT")),
            ("off", L10n.tr("OFF"))
        ]
    }
}
