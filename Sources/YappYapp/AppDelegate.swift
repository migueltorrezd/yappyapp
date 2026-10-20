import AppKit
import Combine
import ServiceManagement
import Sparkle
import SwiftUI
@preconcurrency import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let state = YappYappState()

    // UPDATES: Sparkle updater. Active only in packaged builds — the feed URL
    // and public key live in the packaged Info.plist, so dev `swift build`
    // binaries (no plist) skip the updater entirely and never touch the
    // network. Auto-check obeys config.automaticUpdateChecks (settings toggle,
    // on by default, disclosed in the privacy docs).
    private lazy var updaterController: SPUStandardUpdaterController? = {
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return nil }
        return SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }()

    private func applyUpdaterSettings() {
        updaterController?.updater.automaticallyChecksForUpdates = state.config.automaticUpdateChecks
    }

    func checkForUpdatesNow() {
        guard let updaterController else {
            state.postFeedback(.info(L10n.tr("Update checks only work in the app installed from the DMG."), topic: "updates"), on: .settings)
            return
        }
        updaterController.checkForUpdates(nil)
    }

    private let configStore = ConfigStore()
    private let recorder = RecordingController()
    private let transcriber = WhisperTranscriber()
    private let clipboard = ClipboardInjector()
    private let soundPlayer = SoundPlayer()
    private let whisperServer = WhisperServerController()
    private let parakeet = ParakeetTranscriber()
    // YA-05: the last recording that failed to transcribe, kept for a retry.
    private let failedDictations = FailedDictationStore()
    // COMMANDS: the last recording, in memory only, for retry-last; and the
    // undo of the last insertion.
    private let lastRecording = LastRecordingMemory()
    private let insertionUndo = InsertionUndoExecutor()
    private let petStatsStore = PetStatsStore()
    private var debugAccessories: [String: String] = [:]

    private lazy var recordingSessions = RecordingSessionCoordinator(
        state: state,
        recorder: recorder
    )

    private lazy var permissionCoordinator = PermissionCoordinator(
        state: state,
        recorder: recorder,
        clipboard: clipboard,
        shouldPersistGuidedSetup: { [weak self] in self?.isLaunchSmoke == false },
        persistConfig: { [weak self] config in
            guard let self else { return }
            try self.configStore.save(config)
        },
        logNonFatal: { [weak self] message in self?.logNonFatal(message) }
    )

    private lazy var pasteTargets = PasteTargetCoordinator(clipboard: clipboard)

    // ONBOARDING: the first-run steps in the control window.
    private lazy var onboarding: OnboardingCoordinator = {
        let coordinator = OnboardingCoordinator(state: state)
        coordinator.hooks = OnboardingCoordinator.Hooks(
            saveConfig: { [weak self] config in self?.saveConfig(config) },
            selectSpeechModel: { [weak self] id in self?.selectModel(id: id) },
            retrySpeechDownload: { [weak self] id in self?.downloadModel(id: id) },
            startCleanupDownload: { [weak self] in self?.startCleanupModelDownload() },
            selectTranslationModel: { [weak self] id in self?.selectTranslationModel(id) },
            startTranslationDownload: { [weak self] id in self?.translation.startDownload(id) },
            installedModels: { [weak self] in self?.installedModels() ?? InstalledModels() },
            whisperAvailable: { [weak self] in
                guard let self else { return false }
                return HelperBinaryPolicy.validate(self.state.config.whisperBinaryPath).allowedPath != nil
            },
            qwen3ASRAvailable: { [weak self] in
                guard let self else { return false }
                return Qwen3ASRRuntime.isAvailable(configuredLlamaBinary: self.state.config.llamaBinaryPath)
            },
            llamaRuntimeAvailable: { [weak self] in
                guard let self else { return false }
                return LLMCleaner.isRuntimeAvailable(configured: self.state.config.llamaBinaryPath)
            },
            refreshPermissions: { [weak self] in
                guard let self else { return }
                self.updateAccessibilityTrust(self.clipboard.accessibilityTrusted(promptIfNeeded: false))
                self.refreshMicrophoneState()
            },
            requestMicrophone: { [weak self] in self?.requestMicrophoneAccess() },
            openMicrophoneSettings: { [weak self] in self?.openMicrophonePrivacySettings() },
            requestAccessibility: { [weak self] in self?.requestAccessibilityAccess() },
            resetAccessibility: { [weak self] in self?.resetAndRegrantAccessibility() },
            toggleRecording: { [weak self] in self?.toggleRecording() },
            saveGlossary: { [weak self] entries in self?.saveGlossary(entries) },
            saveSnippets: { [weak self] snippets in self?.saveSnippets(snippets) },
            showWindow: { [weak self] in self?.windowCoordinator.showControlWindow() },
            finished: { [weak self] in self?.finishOnboarding() }
        )
        return coordinator
    }()

    private lazy var windowCoordinator = AppWindowCoordinator(
        state: state,
        rootView: { [weak self] in self?.makeRootView() ?? AnyView(EmptyView()) },
        onToggleRecording: { [weak self] in self?.toggleRecording() },
        onWillPresentControls: { [weak self] in self?.refreshReadiness() },
        onUndoCancel: { [weak self] in self?.undoCancel() },
        onRetry: { [weak self] in self?.retryFailedDictation() }
    )

    // PIPELINE: delivery, notifications, cancel-undo and temp-file tracking.
    private let deliveryNotifier = DeliveryNotifier()
    private lazy var delivery: DictationDeliveryCoordinator = {
        let coordinator = DictationDeliveryCoordinator(
            state: state,
            sessions: recordingSessions,
            backend: clipboard,
            notifier: deliveryNotifier
        )
        coordinator.controlsVisible = { [weak self] in self?.windowCoordinator.controlsVisible ?? false }
        coordinator.currentTarget = { [weak self] in self?.captureExternalPasteTarget(allowFallback: false) }
        coordinator.fallbackTarget = { [weak self] in self?.fallbackExternalPasteTarget() }
        coordinator.secureInputHolder = { SecureInputOwner.currentOwnerName() }
        coordinator.onPresented = { AccessibilityAnnouncer.shared.announcePasteOutcome($0) }
        coordinator.onDelivered = { [weak self] outcome, text in self?.watchForFixes(outcome: outcome, text: text) }
        return coordinator
    }()
    // LEARN-FROM-FIXES: follows the last paste for a few seconds.
    private lazy var autoLearn: AutoLearnWatcher = {
        let watcher = AutoLearnWatcher()
        watcher.onSettled = { [weak self] inserted, edited in self?.learnFromFix(inserted: inserted, edited: edited) }
        return watcher
    }()
    /// Learn notices a notification's UNDO can still reach, newest last.
    private var learnedNotices: [LearnedWordNotice] = []
    private var cancelUndo = CancelUndoBuffer()
    private let inFlightAudio = InFlightAudioFiles()

    // LIVEFILE: HUD live preview (Parakeet, memory only) and file transcription.
    private lazy var livePreview: LivePreviewController = {
        let parakeet = self.parakeet
        let decode: LivePreviewController.Decode = { samples, variant in
            (try? await parakeet.transcribePreview(samples: samples, variant: variant)) ?? nil
        }
        return LivePreviewController(
            decode: decode,
            publish: { [weak self] text in self?.state.livePreviewText = text }
        )
    }()
    // FILES is separate from MIC: results stay on the FILES tab and never
    // reach the clipboard until the user presses COPY there.
    private lazy var fileTranscription = FileTranscriptionCoordinator(
        state: state,
        makeEngine: { [unowned self] in self.makeFileTranscriptionEngine() }
    )

    private lazy var downloadManager: ModelDownloadManager = {
        let manager = ModelDownloadManager()

        manager.onProgress = { [weak self] id, progress in
            self?.state.modelDownloads[id] = progress
        }

        manager.onCompletion = { [weak self] id, error in
            guard let self else { return }
            // FIX(cancelGuard): capture whether this id was still an active
            // download BEFORE clearing it. A cancel that lands after the
            // download already succeeded removes the entry; mirroring the
            // Parakeet path's removeValue != nil guard stops a late success
            // from switching the active model to one the user canceled.
            let wasActive = self.state.modelDownloads.removeValue(forKey: id) != nil

            if let error {
                // YA-34: keep the failure on the model's row, in plain words.
                let optionName = ModelCatalog.option(for: id)?.name ?? L10n.tr("the model")
                self.recordDownloadFailure(id: id, optionName: optionName, error: error)
                self.postNotification(
                    ModelDownloadPresenter.managerFailedNotification(
                        errorDescription: DownloadErrorCopy.plain(error)
                    )
                )
            } else if wasActive, let option = ModelCatalog.option(for: id) {
                self.finishModelDownload(option: option)
            }
        }

        return manager
    }()

    private var glossary = Glossary(entries: [])
    // SNIPPETS: loaded with the glossary, applied after it (Snippets.swift).
    private var snippets = SnippetLibrary(snippets: [])
    private var statusItem: NSStatusItem?
    private var hotKeyManager: HotKeyManager?
    // SHORTCUTS: owns every global shortcut (dictate, paste last, retry last,
    // cancel) and the recording mode. Esc-to-cancel is armed through it too.
    private var shortcutCoordinator: ShortcutCoordinator?
    private let pasteLast = PasteLastController()
    private var cancellables = Set<AnyCancellable>()
    private var readinessTimer: Timer?
    /// Advances once per dictation outcome so the cheeky status pools rotate
    /// deterministically instead of repeating the same line. In-app counter,
    /// not a workflow script, so a plain increment is fine.
    private var statusFlavorIndex = 0
    private var isLaunchSmoke: Bool {
        CommandLine.arguments.contains("--launch-smoke")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // YA-27: read how we were launched before anything else runs.
        let launchEvent = NSAppleEventManager.shared().currentAppleEvent
        let launchedAsLoginItem = ControlWindowLaunchPolicy.isLoginItemLaunch(
            eventID: launchEvent?.eventID,
            propData: launchEvent?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue
        )
        // YA-28: standard Edit and Window shortcuts in every text field.
        NSApp.mainMenu = MainMenuBuilder.make(
            target: self,
            openSettings: #selector(menuOpenSettings),
            quit: #selector(menuQuit)
        )
        setupState()
        // YA-13: clear voice and transcript files a crash or relaunch left behind.
        TempFileSweeper.sweep()
        if canPostNotifications {
            // The delivery notifier presents banners and handles COPY.
            UNUserNotificationCenter.current().delegate = deliveryNotifier
        }
        deliveryNotifier.onCopy = { [weak self] text, sensitive in
            self?.clipboard.copy(text, purpose: sensitive ? .sensitiveCopy : .userCopy)
        }
        deliveryNotifier.onUndoLearned = { [weak self] id in
            guard let self, let notice = self.learnedNotices.first(where: { $0.id == id }) else { return }
            self.undoLearnedWord(notice)
        }
        recorder.onIrrecoverableInterruption = { [weak self] reason in
            guard let self, self.state.phase == .recording else { return }
            self.state.statusText = reason.message
            self.finishRecording()
        }
        setupStatusItem()
        windowCoordinator.start()
        if !isLaunchSmoke {
            setupHotKey()
        }
        pasteTargets.start()
        observePhaseForStatusIcon()
        // SUPPORT: a first-run launch offers the "Say something" mic check.
        MicCheckController.shared.armGuidedStep(isFirstRun: !isLaunchSmoke && !state.config.hasCompletedGuidedSetup)
        // MIC-LIVE-VERIFY: seed the microphone step before the first paint so a
        // brand-new user lands on the correct guided step.
        refreshMicrophoneState()
        refreshReadiness()
        // ONBOARDING: a Mac that has not finished setup gets the steps.
        if !isLaunchSmoke, !state.config.hasCompletedGuidedSetup {
            onboarding.start()
        }
        startReadinessPolling()
        if !isLaunchSmoke {
            synchronizeWhisperServer()
            // YA-50: an installed Parakeet model loads at launch, so the first
            // dictation does not wait for it.
            applyParakeetMemoryPolicy(atLaunch: true)
            // YA-10: stamp a cleanup model installed before stamps existed.
            prepareCleanupModelAtLaunch()
            // LLM-CLEANUP-WARM, TRANSLATION-WARM: load the cleanup and
            // translation models now, so the first dictation is as quick as
            // the tenth.
            observeMemoryPressure()
            translation.onModelsChanged = { [weak self] in self?.synchronizeTranslationServer() }
            synchronizeLlamaServers()
            translation.prepareAtLaunch()
            // QWEN3-ASR: stamp model files placed by hand or left unstamped.
            qwen3Downloads.verifyInstalledAtLaunch { [weak self] in
                self?.refreshReadiness()
                self?.synchronizeSpeechServer()
            }
        }

        if isLaunchSmoke {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                try? Data("ok\n".utf8).write(to: AppPaths.launchSmokeURL, options: .atomic)
                print("launchSmoke=ok")
                NSApp.terminate(nil)
            }
        } else {
            // YA-27: open by itself only while setup is incomplete or on a
            // manual launch. A login launch stays quietly in the menu bar.
            let setupComplete = state.config.hasCompletedGuidedSetup
                && state.isModelReady
                && state.isWhisperReady
                && state.isMicrophoneAuthorized
            if ControlWindowLaunchPolicy.opensOnLaunch(
                setupComplete: setupComplete,
                launchedAsLoginItem: launchedAsLoginItem
            ) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    MainActor.assumeIsolated {
                        self?.windowCoordinator.showControlWindow()
                    }
                }
            }
        }
    }

    /// YA-13: quitting (or a Sparkle relaunch) cancels the in-flight dictation
    /// and deletes its audio instead of stranding it in the temp directory.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if state.phase == .recording {
            recordingSessions.cancelAutoStop()
            recordingSessions.stopLevelMonitoring()
            unregisterEscapeToCancel()
            recorder.cleanup(recorder.stop())
        }
        recorder.cleanup(cancelUndo.discard(now: Date(), onlyIfExpired: false))
        inFlightAudio.deleteAll()
        lastRecording.clear()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKeyManager?.unregisterAll()
        fileTranscription.shutdown()
        whisperServer.stop()
        cleanupServer.stop()
        translationServer.stop()
        speechServer.stop()
        failedDictations.discard()
        lastRecording.clear()
        recordingSessions.shutdown()
        readinessTimer?.invalidate()
        windowCoordinator.stop()
        permissionCoordinator.stop()
        onboarding.stop()
        pasteTargets.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        refreshReadiness()
        windowCoordinator.showControlWindow()
        return true
    }

    private func setupState() {
        refreshPresentedPetStats()

        do {
            try configStore.prepareApplicationSupport()
            state.config = try configStore.load()
            applyAppLanguage(state.config.appLanguage)
            publishConfigStoreState()
            configureParakeetDownloads(allowed: state.config.allowModelDownloads)
            glossary = try Glossary.load(from: AppPaths.glossaryURL)
            state.glossaryTermCount = glossary.count
            reloadSnippets()
        } catch {
            presentNonDictationError(error.localizedDescription)
        }
    }

    // MANAGED-PREFS + CONFIG-RECOVERY: mirror the store's locks and hand the
    // one-time repair notice to the UI.
    private func publishConfigStoreState() {
        if state.managedConfigKeys != configStore.lockedKeys {
            state.managedConfigKeys = configStore.lockedKeys
        }
        if let notice = configStore.takeRecoveryNotice() {
            state.configRecoveryNotice = notice
        }
    }

    private func refreshPresentedPetStats() {
        var presented = PetDebugAccess.presented(petStatsStore.stats)
        if PetDebugAccess.isEnabled {
            presented.accessoriesByPet.merge(debugAccessories) { _, debugValue in debugValue }
        }
        state.petStats = presented
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "waveform.circle.fill",
            accessibilityDescription: "YappYapp"
        )
        item.button?.toolTip = ShortcutCopy.tooltip(state.config.shortcuts)
        item.button?.action = #selector(statusItemClicked(_:))
        item.button?.target = self
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showStatusMenu()
        } else {
            windowCoordinator.togglePopover(anchor: statusItem?.button, sender: sender)
        }
    }

    private func showStatusMenu() {
        let menu = NSMenu()

        let recordItem = NSMenuItem(
            title: state.phase == .recording ? L10n.tr("Stop Dictation") : L10n.tr("Start Dictation"),
            action: #selector(menuToggleRecording),
            keyEquivalent: ""
        )
        recordItem.target = self
        // SHORTCUTS: show the active shortcut next to the menu item.
        recordItem.title = ShortcutCopy.menuTitle(recordItem.title, settings: state.config.shortcuts)
        ShortcutKeyNames.decorate(recordItem, with: state.config.shortcuts.chord(for: .toggleDictation))
        menu.addItem(recordItem)

        let pasteLastItem = NSMenuItem(title: L10n.tr("Paste Last Dictation"), action: #selector(menuPasteLast), keyEquivalent: "")
        pasteLastItem.target = self
        ShortcutKeyNames.decorate(pasteLastItem, with: state.config.shortcuts.chord(for: .pasteLast))
        menu.addItem(pasteLastItem)

        // YA-05 + COMMANDS: a failed dictation's audio, or the last
        // recording kept in memory, waits here for a retry.
        if canRetryFailedDictation || lastRecording.hasRecording {
            let retryItem = NSMenuItem(
                title: RetryLastPresenter.menuTitle,
                action: #selector(menuRetryFailedDictation),
                keyEquivalent: ""
            )
            retryItem.target = self
            ShortcutKeyNames.decorate(retryItem, with: state.config.shortcuts.chord(for: .retryLast))
            menu.addItem(retryItem)
        }

        // COMMANDS: take the last dictation back out of the app.
        if clipboard.lastInsertion != nil {
            let undoLastItem = NSMenuItem(
                title: InsertionUndoPresenter.menuTitle,
                action: #selector(menuUndoLastInsertion),
                keyEquivalent: ""
            )
            undoLastItem.target = self
            ShortcutKeyNames.decorate(undoLastItem, with: state.config.shortcuts.chord(for: .undoLast))
            menu.addItem(undoLastItem)
        }

        // YA-19: a canceled dictation can still be transcribed for a few seconds.
        if state.phase == .canceled {
            let undoItem = NSMenuItem(title: L10n.tr("Keep Canceled Dictation"), action: #selector(menuUndoCancel), keyEquivalent: "")
            undoItem.target = self
            menu.addItem(undoItem)
        }

        // LIVEFILE: transcribe a file; the text shows up in FILES, never pasted.
        let fileItem = NSMenuItem(title: L10n.tr("Transcribe Audio File…"), action: #selector(menuTranscribeFile), keyEquivalent: "")
        fileItem.target = self
        fileItem.isEnabled = !fileTranscription.isRunning
        menu.addItem(fileItem)

        let openItem = NSMenuItem(title: L10n.tr("Open YappYapp"), action: #selector(menuOpenPopover), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        let languageMenu = NSMenu()
        for choice in LanguageCatalog.options {
            let item = NSMenuItem(title: choice.menuLabel, action: #selector(menuSetLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = choice.code
            item.state = state.config.language == choice.code ? .on : .off
            languageMenu.addItem(item)
        }
        // YA-24: Parakeet ignores this pick, so the menu says who it is for.
        let languageItem = NSMenuItem(title: EngineSettingsNotes.menuLanguageTitle(for: state.config), action: nil, keyEquivalent: "")
        menu.addItem(languageItem)
        menu.setSubmenu(languageMenu, for: languageItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: L10n.tr("Quit YappYapp"), action: #selector(menuQuit), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func menuToggleRecording() {
        toggleRecording()
    }

    @objc private func menuRetryFailedDictation() {
        retryLastDictation()
    }

    @objc private func menuUndoLastInsertion() {
        undoLastInsertion()
    }

    @objc private func menuUndoCancel() {
        undoCancel()
    }

    @objc private func menuPasteLast() {
        pasteLastDictation()
    }

    @objc private func menuTranscribeFile() {
        FileTranscriptionPicker.choose { [weak self] url in
            self?.startFileTranscription(url)
            self?.windowCoordinator.showControlWindow()
        }
    }

    @objc private func menuOpenPopover() {
        windowCoordinator.showControlWindow()
    }

    @objc private func menuSetLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        var config = state.config
        config.language = code
        saveConfig(config)
        state.statusText = EngineSettingsNotes.menuLanguageStatus(label: sender.title, config: config)
    }

    @objc private func menuOpenSettings() {
        requestTab(.settings)
        windowCoordinator.showControlWindow()
    }

    @objc private func menuQuit() {
        NSApp.terminate(nil)
    }

    private func makeRootView() -> AnyView {
        AnyView(BrutalistPopoverView(
            state: state,
            onToggleRecording: { [weak self] in self?.toggleRecording() },
            onSelectModel: { [weak self] id in self?.selectModel(id: id) },
            onDownloadModel: { [weak self] id in self?.downloadModel(id: id) },
            onCancelDownload: { [weak self] id in self?.cancelModelDownload(id: id) },
            onSaveConfig: { [weak self] config in self?.saveConfig(config) },
            onSaveGlossary: { [weak self] entries in self?.saveGlossary(entries) },
            onRequestAccessibility: { [weak self] in self?.requestAccessibilityAccess() },
            onResetAndRegrantAccessibility: { [weak self] in self?.resetAndRegrantAccessibility() },
            onRequestMicrophone: { [weak self] in self?.requestMicrophoneAccess() },
            onOpenMicrophoneSettings: { [weak self] in self?.openMicrophonePrivacySettings() },
            onSetLaunchAtLogin: { [weak self] enabled in self?.setLaunchAtLogin(enabled) },
            onChooseStarter: { [weak self] kind in self?.chooseStarter(kind) },
            onEquipAccessory: { [weak self] accessory in self?.equipAccessory(accessory) },
            onSaveRecap: { [weak self] in self?.saveRecapCard() },
            onCopyText: { [weak self] text in self?.copyText(text) },
            onRevealSupport: { NSWorkspace.shared.activateFileViewerSelecting([AppPaths.supportDirectory]) },
            onQuit: { NSApp.terminate(nil) },
            onCheckForUpdates: { [weak self] in self?.checkForUpdatesNow() },
            onDownloadCleanupModel: { [weak self] in self?.startCleanupModelDownload() },
            onCancelCleanupDownload: { [weak self] in self?.cancelCleanupModelDownload() },
            onSelectTranslationModel: { [weak self] id in self?.selectTranslationModel(id) },
            onDownloadTranslationModel: { [weak self] id in self?.translation.startDownload(id) },
            onCancelTranslationDownload: { [weak self] id in self?.translation.cancelDownload(id) },
            onDeleteTranslationModel: { [weak self] id in self?.translation.delete(id) },
            onScanMac: { [weak self] in self?.scanMac() },
            onApplyRecommendation: { [weak self] choice in self?.applyRecommendation(choice) },
            onSaveSnippets: { [weak self] snippets in self?.saveSnippets(snippets) },
            onRetryFailed: { [weak self] in self?.retryFailedDictation() },
            onDeleteModel: { [weak self] id in self?.deleteModel(id: id) },
            onUndoLearnedWord: { [weak self] notice in self?.undoLearnedWord(notice) }
        ).environment(\.onboardingActions, onboarding.actions)
        .environment(\.fileTranscriptionActions, FileTranscriptionActions(
            start: { [weak self] url in self?.startFileTranscription(url) },
            choose: { [weak self] in
                FileTranscriptionPicker.choose { url in self?.startFileTranscription(url) }
            },
            cancel: { [weak self] in self?.fileTranscription.cancel() },
            dismiss: { [weak self] in self?.fileTranscription.dismiss() }
        )))
    }

    private func setupHotKey() {
        let manager = HotKeyManager()
        hotKeyManager = manager
        // SHORTCUTS: every global shortcut goes through the coordinator, which
        // turns presses and releases into intents for the active recording mode.
        let coordinator = ShortcutCoordinator(
            registrar: manager,
            modifierMonitor: NSEventModifierMonitor(),
            handlers: ShortcutCoordinator.Handlers(
                isRecording: { [weak self] in self?.state.phase == .recording },
                onDictation: { [weak self] intent in self?.handleDictationIntent(intent) },
                onPasteLast: { [weak self] in self?.pasteLastDictation() },
                onRetryLast: { [weak self] in self?.retryLastDictation() },
                onCancel: { [weak self] in self?.cancelRecording() },
                onUndoLast: { [weak self] in self?.undoLastInsertion() }
            )
        )
        shortcutCoordinator = coordinator
        ShortcutRecorderGate.shared.onBegin = { [weak self] in self?.shortcutCoordinator?.suspend() }
        ShortcutRecorderGate.shared.onEnd = { [weak self] in self?.shortcutCoordinator?.resume() }
        applyShortcuts(state.config.shortcuts)
    }

    /// FIX(hotkeyRegVisible): a shortcut that could not be registered (dead
    /// dispatcher, or the combo owned by another app) must not look like a
    /// working one. Surface it on the status channel and log it non-fatally.
    private func applyShortcuts(_ settings: ShortcutSettings) {
        guard let shortcutCoordinator else { return }
        let failed = shortcutCoordinator.apply(settings)
        // YA-72: the failure stays visible (MIC row, chips, tooltip), not
        // just one status line that the next message replaces.
        state.hotkeyUnavailable = HotkeyAvailability.isUnavailable(settings: settings, failed: failed)
        statusItem?.button?.toolTip = state.hotkeyUnavailable
            ? HotkeyStatusCopy.tooltip(hotkeyAvailable: false)
            : ShortcutCopy.tooltip(settings)
        if let message = ShortcutCopy.registrationFailure(settings, failed: failed) {
            state.statusText = message
            let names = failed.map(\.rawValue).joined(separator: ",")
            logNonFatal("hotkey: registration failed for \(names); shortcut unavailable")
        }
    }

    private func handleDictationIntent(_ intent: DictationIntent) {
        guard !pasteLast.isPasting else {
            state.statusText = PasteLastDecision.busyPasting.statusText ?? ""
            return
        }
        switch intent {
        case .start:
            guard state.phase != .recording else { return }
            toggleRecording()
        case .stop:
            guard state.phase == .recording else { return }
            toggleRecording()
        case .cancel:
            cancelRecording()
        }
    }

    /// SHORTCUTS: re-delivers the most recent in-memory transcript at the
    /// cursor through the normal paste path. Nothing is read from disk.
    private func pasteLastDictation() {
        pasteLast.run(
            history: state.transcriptHistory,
            phase: state.phase,
            otherPasteInFlight: recordingSessions.isPasteInFlight,
            deliver: { text in
                self.updateAccessibilityTrust(self.clipboard.accessibilityTrusted(promptIfNeeded: false))
                let target = self.captureExternalPasteTarget(allowFallback: false)
                    ?? self.fallbackExternalPasteTarget()
                // PIPELINE: the honest delivery path presents the outcome (HUD,
                // status, VoiceOver, notification, return to idle) itself.
                self.delivery.deliver(text: text, to: target)
                return PasteStatusSnapshot(phase: self.state.phase, statusText: self.state.statusText)
            },
            report: { decision, snapshot in
                if snapshot == nil, let text = decision.statusText {
                    self.state.statusText = text
                }
            }
        )
    }

    /// COMMANDS (retry-last): transcribes the last recording again with the
    /// current engine and settings, and delivers it through the normal path.
    /// A failed dictation runs from its kept file (YA-05); a delivered one
    /// from the in-memory copy, written to a temp WAV for this one run.
    func retryLastDictation() {
        let plan = RetryLastPlanner.plan(
            phase: state.phase,
            isProcessing: state.isProcessing,
            pasteInFlight: recordingSessions.isPasteInFlight || pasteLast.isPasting,
            memory: lastRecording.recording,
            hasFailedDictation: canRetryFailedDictation
        )
        switch plan {
        case .retryFailed:
            retryFailedDictation()
        case .retranscribe:
            guard let recording = lastRecording.recording,
                  let url = try? lastRecording.materialize() else {
                state.statusText = RetryLastPresenter.couldNotPrepare
                return
            }
            transcribeRecording(
                audioURL: url,
                retry: RetryableDictation(audioURL: url, signalProfile: recording.signalProfile),
                session: recordingSessions.currentSession,
                sessionTarget: nil,
                retranscription: true
            )
        default:
            state.statusText = RetryLastPresenter.statusText(for: plan) ?? ""
        }
    }

    /// COMMANDS: removes the last dictation from the app it went into, or
    /// says why it cannot.
    func undoLastInsertion() {
        guard state.phase != .recording, !recordingSessions.isPasteInFlight, !pasteLast.isPasting else {
            state.statusText = InsertionUndoPresenter.refusalText(.busy)
            return
        }
        let outcome = insertionUndo.undo(
            clipboard.lastInsertion,
            target: captureExternalPasteTarget()?.application,
            accessibilityTrusted: clipboard.accessibilityTrusted(promptIfNeeded: false)
        )
        switch outcome {
        case .removed, .sentUndoKey:
            clipboard.forgetLastInsertion()
        case .refused:
            break
        }
        state.statusText = InsertionUndoPresenter.statusText(for: outcome)
    }

    /// COMMANDS: the dictation was only "scratch that". Nothing to deliver;
    /// the undo already said what happened.
    private func finishCommandOnlyDictation(session: Int, undid: Bool) {
        guard recordingSessions.isCurrent(session) else { return }
        state.isProcessing = false
        state.phase = .idle
        if !undid {
            state.statusText = SpokenCommandCopy.scratchedStatus
        }
    }

    private func registerEscapeToCancel() {
        // YA-19: Esc-cancel is optional, so Esc is not taken from every app.
        guard state.config.escCancelsRecording else { return }
        shortcutCoordinator?.armCancel()
    }

    private func unregisterEscapeToCancel() {
        shortcutCoordinator?.disarmCancel()
    }

    private func observePhaseForStatusIcon() {
        state.$phase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase in
                self?.updateStatusIcon(for: phase)
                self?.updateHUDMouseBehavior(for: phase)
                AccessibilityAnnouncer.shared.announcePhase(phase)
            }
            .store(in: &cancellables)
    }

    private func updateHUDMouseBehavior(for phase: CapturePhase) {
        windowCoordinator.updateHUDMouseBehavior(for: phase)
    }

    private func updateStatusIcon(for phase: CapturePhase) {
        guard let button = statusItem?.button else { return }

        switch phase {
        case .recording:
            button.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: L10n.tr("Listening"))
            button.contentTintColor = .systemRed
        case .transcribing:
            button.image = NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: L10n.tr("Transcribing"))
            button.contentTintColor = .systemTeal
        default:
            button.image = NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: "YappYapp")
            button.contentTintColor = nil
        }
    }

    private func captureExternalPasteTarget(allowFallback: Bool = true) -> PasteTarget? {
        pasteTargets.captureCurrent(allowFallback: allowFallback)
    }

    private func fallbackExternalPasteTarget() -> PasteTarget? {
        pasteTargets.fallback()
    }

    private func selectModel(id: String) {
        guard let option = ModelCatalog.option(for: id) else { return }
        // MANAGED-PREFS: a profile that forces the model owns this choice.
        guard !state.managedConfigKeys.contains(.selectedModel) else {
            state.statusText = ManagedPreferencesCopy.modelLockedStatus
            return
        }

        // A model that is not on disk cannot become the active one. Clicking
        // it starts the download instead; the current model keeps serving
        // dictations until the new one is actually ready.
        guard option.isInstalled else {
            downloadModel(id: id)
            return
        }

        activateModel(option)
    }

    private func activateModel(_ option: ModelOption) {
        do {
            let plan = ModelActivationPlanner.plan(currentConfig: try configStore.load(), option: option)
            try configStore.save(plan.config)
            if plan.shouldPreloadParakeet {
                preloadParakeet(option: option)
            } else if let statusText = plan.statusText {
                state.statusText = statusText
            }
            refreshReadiness()
            synchronizeWhisperServer()
            synchronizeSpeechServer()
        } catch {
            presentNonDictationError(error.localizedDescription)
        }
    }

    private func saveConfig(_ config: AppConfig) {
        let hudPositionChanged = config.hudPosition != state.config.hudPosition
        let appLanguageChanged = config.appLanguage != state.config.appLanguage
        let shortcutsChanged = config.shortcuts != state.config.shortcuts

        // Selecting a freshly unlocked pet starts its egg hatching.
        if config.pet != state.config.pet, !PetDebugAccess.isEnabled {
            petStatsStore.markEggStart(pet: config.pet)
            refreshPresentedPetStats()
        }

        do {
            try configStore.save(config)
            configureParakeetDownloads(allowed: config.allowModelDownloads)
            refreshReadiness()
            synchronizeWhisperServer()
            synchronizeLlamaServers()
            // YA-38: a routine save confirms on the tab in use and never
            // overwrites an error on the MIC status line.
            state.postFeedback(.success(L10n.tr("Setup saved."), topic: "save"), on: state.activeTab)
            ensureCleanupModelIfEnabled(config)
        } catch {
            presentNonDictationError(error.localizedDescription)
            state.postFeedback(.error(L10n.tr("Setup wasn't saved. %@", error.localizedDescription), topic: "save"), on: state.activeTab)
        }

        if hudPositionChanged {
            windowCoordinator.rebuildHUDWindows()
        }

        if shortcutsChanged {
            applyShortcuts(config.shortcuts)
        }

        if appLanguageChanged {
            applyAppLanguage(config.appLanguage)
        }
    }

    // L10N (YA-42): switch the interface language and rebuild the main menu,
    // which AppKit does not redraw on its own. The status menu is rebuilt on
    // every click, and SwiftUI views read the language when they render.
    private func applyAppLanguage(_ setting: String) {
        L10n.apply(setting)
        NSApp.mainMenu = MainMenuBuilder.make(
            target: self,
            openSettings: #selector(menuOpenSettings),
            quit: #selector(menuQuit)
        )
        statusItem?.button?.toolTip = state.hotkeyUnavailable
            ? HotkeyStatusCopy.tooltip(hotkeyAvailable: false)
            : ShortcutCopy.tooltip(state.config.shortcuts)
        state.statusText = L10n.retranslate(state.statusText)
    }

    private func saveGlossary(_ entries: [GlossaryEntry]) {
        let grew = entries.count > state.glossaryEntries.count
        let deletedOne = WordsDeletion.isSingleDeletion(old: state.glossaryEntries, new: entries)
        // LEARN-FROM-FIXES: a learned word the user deletes is never learned again.
        let blocked = AutoLearn.deletedLearnedWords(old: state.glossaryEntries, new: entries)
        if !blocked.isEmpty {
            try? NeverLearnList.save(NeverLearnList.adding(blocked, to: NeverLearnList.load()))
        }

        do {
            try Glossary.save(entries, to: AppPaths.glossaryURL)
            refreshReadiness()
            synchronizeWhisperServer()
            state.postFeedback(.success(
                deletedOne ? L10n.tr("Word deleted.") : L10n.tr("Words saved. They work from your next dictation."),
                topic: "glossary"
            ), on: .words)
        } catch {
            presentNonDictationError(error.localizedDescription)
            state.postFeedback(.error(L10n.tr("Words weren't saved. %@", error.localizedDescription), topic: "glossary"), on: .words)
            return
        }

        if grew {
            let events = petStatsStore.markGlossaryTaught(gamified: state.config.petEnabled)
            refreshPresentedPetStats()
            if !events.isEmpty {
                announcePetEvents(events)
            }
        }
    }

    // MARK: - Learn from fixes

    /// After a confirmed or best-effort paste, follow the pasted text for a
    /// few seconds (AutoLearnWatcher). Anything else stops the watch.
    private func watchForFixes(outcome: PasteOutcome, text: String) {
        guard state.config.learnFromFixes, outcome == .pasted || outcome == .pastedBestEffort else {
            autoLearn.cancel()
            return
        }
        autoLearn.begin(record: clipboard.lastInsertion, pastedText: text)
    }

    /// The watch settled: learn what the rules accept, say so once per word.
    private func learnFromFix(inserted: String, edited: String) {
        guard state.config.learnFromFixes else { return }
        let proposals = AutoLearn.proposals(
            inserted: inserted,
            edited: edited,
            entries: glossary.entries,
            neverLearn: Set(NeverLearnList.load()),
            lexicon: SpellCheckerLexicon.forDictationLanguage(state.config.language)
        )
        guard !proposals.isEmpty else { return }
        var entries = glossary.entries
        for proposal in proposals {
            entries = AutoLearn.applying(proposal, to: entries)
        }
        do {
            try Glossary.save(entries, to: AppPaths.glossaryURL)
        } catch {
            logNonFatal("Learn from fixes: the word list could not be saved: \(error.localizedDescription)")
            return
        }
        refreshReadiness(surfaceErrors: false)
        synchronizeWhisperServer()

        for proposal in proposals {
            let notice = LearnedWordNotice(proposal: proposal)
            learnedNotices = Array((learnedNotices + [notice]).suffix(10))
            state.learnedWordNotice = notice
            if !windowCoordinator.controlsVisible {
                deliveryNotifier.postLearned(
                    noticeID: notice.id,
                    title: LearnFromFixesCopy.notificationTitle,
                    body: LearnFromFixesCopy.notificationBody(word: notice.word, showText: state.config.showTextInNotifications)
                )
            }
        }
    }

    /// UNDO on the MIC tab or in the banner: the learned word goes, and is
    /// never learned again.
    private func undoLearnedWord(_ notice: LearnedWordNotice) {
        let undone = AutoLearn.undoing(notice.proposal, from: glossary.entries)
        do {
            try Glossary.save(undone.entries, to: AppPaths.glossaryURL)
            try NeverLearnList.save(NeverLearnList.adding([undone.blockKey], to: NeverLearnList.load()))
        } catch {
            state.postFeedback(.error(L10n.tr("Words weren't saved. %@", error.localizedDescription), topic: "glossary"), on: .home)
            return
        }
        learnedNotices.removeAll { $0.id == notice.id }
        if state.learnedWordNotice?.id == notice.id {
            state.learnedWordNotice = nil
        }
        refreshReadiness(surfaceErrors: false)
        synchronizeWhisperServer()
        state.postFeedback(.success(LearnFromFixesCopy.undone, topic: "glossary"), on: .home)
    }

    // SNIPPETS: snippets.json, kept beside the glossary.
    private func reloadSnippets() {
        snippets = SnippetPersistence.reload(into: state)
    }

    private func saveSnippets(_ entries: [Snippet]) {
        let deletedOne = WordsDeletion.isSingleDeletion(old: state.snippets, new: entries)
        if let saved = SnippetPersistence.save(
            entries,
            state: state,
            successMessage: deletedOne ? L10n.tr("Snippet deleted.") : nil
        ) {
            snippets = saved
        }
    }

    private func announcePetEvents(_ events: [PetEvent]) {
        let announcement = PetGamification.announcement(
            for: events,
            enabled: state.config.petEnabled,
            activePet: state.config.pet,
            playSounds: state.config.playSounds
        )
        // YA-29: pet news goes to its own line and never overwrites the
        // paste outcome in statusText.
        if let message = announcement.messages.last {
            state.petEventNote = message
        }

        if announcement.playJingle {
            soundPlayer.playJingle(forPet: state.config.pet)
        }
    }

    private func chooseStarter(_ kind: PetKind) {
        petStatsStore.chooseStarter(kind)
        refreshPresentedPetStats()

        var config = state.config
        config.pet = kind.rawValue
        saveConfig(config)

        state.statusText = L10n.tr("You chose %@. Dictate %@ words to hatch the egg.", kind.label, "\(PetStats.hatchTarget)")
        if state.config.playSounds {
            soundPlayer.playJingle(forPet: kind.rawValue)
        }
    }

    private func equipAccessory(_ accessory: PetAccessory) {
        let pet = state.activePet
        if PetDebugAccess.isEnabled {
            debugAccessories[pet.rawValue] = accessory.rawValue
            refreshPresentedPetStats()
            return
        }
        petStatsStore.setAccessory(accessory, for: pet)
        refreshPresentedPetStats()
    }

    private func saveRecapCard() {
        // YA-70: Pictures/YappYapp with a fresh name, honest failure copy.
        let result = MainActor.assumeIsolated {
            RecapCardRenderer.save(stats: state.petStats, kind: PetKind(rawValue: state.config.pet) ?? .none)
        }
        state.postFeedback(
            {
                if case .saved = result {
                    return .success(result.statusText, topic: "recap")
                }
                return .error(result.statusText, topic: "recap")
            }(),
            on: .pet
        )
        if case .saved(let url) = result {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private var parakeetPreloadTask: Task<Void, Never>?
    private var parakeetDownloadTasks: [String: Task<Void, Never>] = [:]

    /// Activating a Parakeet model loads it into memory right away so the
    /// first dictation is instant. The files are already on disk here.
    private func preloadParakeet(option: ModelOption) {
        guard let variant = option.parakeetVariant else { return }

        parakeetPreloadTask?.cancel()
        parakeetPreloadTask = Task { [weak self] in
            guard let self else { return }

            let alreadyLoaded = await self.parakeet.isLoaded(variant: variant)

            await MainActor.run {
                self.state.statusText = alreadyLoaded
                    ? L10n.tr("Using %@. It runs on this Mac.", option.name)
                    : L10n.tr("Loading %@…", option.name)
            }
            guard !alreadyLoaded else { return }

            do {
                try await self.parakeet.preload(variant: variant)
                await MainActor.run {
                    self.state.statusText = L10n.tr("Using %@. It runs on this Mac.", option.name)
                }
            } catch {
                await MainActor.run {
                    self.state.statusText = L10n.tr("Couldn't load %@. %@", option.name, error.localizedDescription)
                }
            }
        }
    }

    private func synchronizeWhisperServer() {
        // Parakeet keeps its models warm in-process; the whisper-server is
        // only worth its RAM when a Whisper model is selected.
        guard ModelCatalog.engine(for: state.config.modelPath) == .whisper else {
            whisperServer.stop()
            return
        }

        // YA-50: a Whisper model is selected, so Parakeet gives its memory back.
        applyParakeetMemoryPolicy(atLaunch: false)
        whisperServer.synchronize(config: TranscriptionLanguage.transcriptionConfig(from: state.config), glossary: glossary)
    }

    /// YA-50: release Parakeet when Whisper is selected; at launch, load the
    /// selected Parakeet model when it is installed and kept warm.
    private func applyParakeetMemoryPolicy(atLaunch: Bool) {
        let selectedOption = ModelCatalog.option(for: ModelCatalog.selectedID(for: state.config.modelPath))
        let action = ParakeetMemoryPolicy.action(
            engine: ModelCatalog.engine(for: state.config.modelPath),
            parakeetVariant: selectedOption?.parakeetVariant,
            selectedInstalled: selectedOption?.isInstalled ?? false,
            keepModelWarm: state.config.keepModelWarm,
            atLaunch: atLaunch
        )

        switch action {
        case .none:
            return
        case .release:
            parakeetPreloadTask?.cancel()
            parakeetPreloadTask = nil
            Task { [parakeet] in await parakeet.unload() }
        case .preload(let variant):
            parakeetPreloadTask?.cancel()
            parakeetPreloadTask = Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.parakeet.preload(variant: variant)
                } catch {
                    // Quiet at launch: the first dictation loads it again and
                    // reports any real problem then.
                    self.logNonFatal("Parakeet preload at launch failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func downloadModel(id: String) {
        guard let option = ModelCatalog.option(for: id), !option.isInstalled else { return }
        guard state.modelDownloads[id] == nil else { return }
        guard state.config.allowModelDownloads else {
            state.statusText = ModelDownloadPresenter.downloadsOffStatus(
                lockedByAdmin: state.managedConfigKeys.contains(.allowModelDownloads)
            )
            return
        }

        // QWEN3-ASR: like the translation models, never fetched without the
        // bundled runtime that can run it.
        if option.engine == .qwen3asr, !Qwen3ASRRuntime.isAvailable(configuredLlamaBinary: state.config.llamaBinaryPath) {
            state.statusText = Qwen3ASRError.runtimeMissing.localizedDescription
            state.postFeedback(.error(Qwen3ASRError.runtimeMissing.localizedDescription, topic: "download.\(id)"), on: .models)
            return
        }

        state.modelDownloads[id] = 0
        state.modelDownloadErrors[id] = nil
        state.statusText = ModelDownloadPresenter.startedStatus(
            optionName: option.name,
            selectedModelName: state.selectedModelName,
            selectedModelInstalled: state.isModelReady
        )

        if option.engine == .parakeet {
            downloadParakeet(option: option)
        } else if option.engine == .qwen3asr {
            qwen3Downloads.start(option)
        } else {
            downloadManager.download(option: option)
        }
    }

    // MARK: - QWEN3-ASR

    private let speechServer = LlamaServerController.speech
    private let qwen3Transcriber = Qwen3ASRTranscriber()

    /// Two pinned files per model, verified one by one; progress and outcome
    /// land on the model's row like any other speech model download.
    private lazy var qwen3Downloads = Qwen3ASRDownloadCoordinator(callbacks: .init(
        progress: { [weak self] id, fraction in
            guard let self, self.state.modelDownloads[id] != nil else { return }
            self.state.modelDownloads[id] = fraction
        },
        finished: { [weak self] option in
            guard let self, self.state.modelDownloads.removeValue(forKey: option.id) != nil else { return }
            self.finishModelDownload(option: option)
        },
        failed: { [weak self] option, error in
            guard let self, self.state.modelDownloads.removeValue(forKey: option.id) != nil else { return }
            // A checksum failure reads as "didn't verify", not as a raw error.
            let plain = TranslationModelStore.plainError(error)
            self.state.modelDownloadErrors[option.id] = plain
            self.state.statusText = DownloadErrorCopy.status(optionName: option.name, plain: plain)
            self.logNonFatal("download \(option.id) failed: \(error.localizedDescription)")
        },
        canceled: { [weak self] option in
            guard let self else { return }
            self.state.modelDownloads.removeValue(forKey: option.id)
            self.state.statusText = ModelDownloadPresenter.canceledStatus
        }
    ))

    /// Keeps the selected Qwen3-ASR model loaded in a warm llama-server while
    /// it is the speech model, verified, kept warm and memory is not
    /// critical. Any other engine stops it.
    private func synchronizeSpeechServer() {
        guard !isLaunchSmoke else { return }
        let config = state.config
        if ModelCatalog.engine(for: config.modelPath) == .qwen3asr {
            // Qwen3-ASR took over, so Parakeet gives its memory back.
            applyParakeetMemoryPolicy(atLaunch: false)
        }
        speechServer.synchronize(Qwen3ASRServerPolicy.launch(
            config: config,
            runtimeBinary: LLMCleaner.binaryPath(configured: config.llamaBinaryPath),
            modelVerified: { Qwen3ASRModelStore.isVerified($0) },
            memoryPressureCritical: memoryPressureCritical,
            launchable: { HelperBinaryPolicy.launchablePath($0) }
        ))
    }

    /// DELETE on a downloaded Qwen3-ASR row. The model in use is never
    /// deleted from under a dictation: pick another one first.
    private func deleteModel(id: String) {
        guard let option = ModelCatalog.option(for: id), let variant = option.qwen3Variant else { return }
        guard state.selectedModelID != id else {
            state.postFeedback(.error(L10n.tr("%@ is in use. Pick another model first.", option.name), topic: "delete.\(id)"), on: .models)
            return
        }
        qwen3Downloads.cancel(option)
        Qwen3ASRModelStore.delete(variant)
        state.modelDownloadErrors[id] = nil
        refreshReadiness()
        state.postFeedback(.success(L10n.tr("%@ deleted.", option.name), topic: "delete.\(id)"), on: .models)
    }

    private func downloadParakeet(option: ModelOption) {
        guard let variant = option.parakeetVariant else { return }
        let downloadsAllowed = state.config.allowModelDownloads

        // The verified downloader's progress callback is @Sendable; an AsyncStream
        // carries the snapshots back to the main actor without smuggling
        // self across the concurrency boundary.
        let (progressStream, progressContinuation) = AsyncStream.makeStream(of: ParakeetDownloadProgress.self)

        Task { @MainActor [weak self] in
            var lastShown = 0.0
            for await update in progressStream {
                // A finished or canceled download must not resurrect
                // its own progress bar from a late callback. (-1 is not
                // nil, so the spinner state still passes this guard.)
                guard let self, self.state.modelDownloads[option.id] != nil else { continue }

                // Stream listing/download progress smoothly, never going backward.
                lastShown = max(lastShown, update.fraction)
                self.state.modelDownloads[option.id] = lastShown
            }
        }

        let task = Task { [weak self] in
            defer { progressContinuation.finish() }
            do {
                try await downloadParakeetModel(
                    variant: variant,
                    downloadsAllowed: downloadsAllowed
                ) { update in
                    progressContinuation.yield(update)
                }

                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.parakeetDownloadTasks.removeValue(forKey: option.id)
                    guard self.state.modelDownloads.removeValue(forKey: option.id) != nil else { return }
                    self.finishModelDownload(option: option)
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.parakeetDownloadTasks.removeValue(forKey: option.id)
                    guard self.state.modelDownloads.removeValue(forKey: option.id) != nil else { return }

                    if error is CancellationError || (error as? URLError)?.code == .cancelled {
                        self.state.statusText = ModelDownloadPresenter.canceledStatus
                    } else {
                        self.recordDownloadFailure(id: option.id, optionName: option.name, error: error)
                        self.postNotification(
                            ModelDownloadPresenter.parakeetFailedNotification(
                                optionName: option.name,
                                errorDescription: DownloadErrorCopy.plain(error)
                            )
                        )
                    }
                }
            }
        }

        parakeetDownloadTasks[option.id] = task
    }

    /// YA-34: a failed download leaves a plain-language trace on its Models
    /// row (FAILED, RETRY), on the Models tab and on the MIC status line.
    /// The raw error goes to the log only.
    private func recordDownloadFailure(id: String, optionName: String, error: Error) {
        let plain = DownloadErrorCopy.plain(error)
        state.modelDownloadErrors[id] = plain
        state.statusText = DownloadErrorCopy.status(optionName: optionName, plain: plain)
        // The row says it (FAILED, RETRY and the reason), and Whisper's group
        // opens for a failed row, so no second banner above the list.
        logNonFatal("download \(id) failed: \(error.localizedDescription)")
    }

    /// Runs when any model download finishes: notify, then switch to the
    /// model the user asked for.
    private func finishModelDownload(option: ModelOption) {
        state.modelDownloadErrors[option.id] = nil
        state.postFeedback(.success(L10n.tr("%@ is ready.", option.name), topic: "download.\(option.id)"), on: .models)
        refreshReadiness()
        postNotification(ModelDownloadPresenter.readyNotification(optionName: option.name))
        if state.config.playSounds {
            soundPlayer.playStop()
        }
        selectModel(id: option.id)
        // ONBOARDING: cleanup and translation start once speech is here.
        onboarding.speechModelInstalled(option.id)
    }

    /// FINISH (or the last step): the wizard is done for good. Anything
    /// still open shows on the MIC tab as a plain list.
    private func finishOnboarding() {
        var config = state.config
        config.hasCompletedGuidedSetup = true
        do {
            try configStore.save(config)
            state.config = config
        } catch {
            logNonFatal("Could not persist onboarding completion: \(error.localizedDescription)")
        }
        MicCheckController.shared.finishGuidedStep()
        // The "Setup saved." notes from the steps are old news on MIC.
        if state.tabFeedback[.home]?.isError == false {
            state.tabFeedback[.home] = nil
        }
        requestTab(.home)
        refreshReadiness()
    }

    private func installedModels() -> InstalledModels {
        InstalledModels(
            speechIDs: Set(ModelCatalog.options.filter(\.isInstalled).map(\.id)),
            cleanupModel: LLMCleaner.isModelInstalled(),
            translation: state.translationModels.installed
        )
    }

    private func cancelModelDownload(id: String) {
        downloadManager.cancel(id: id)
        if let option = ModelCatalog.option(for: id), option.engine == .qwen3asr {
            qwen3Downloads.cancel(option)
        }
        parakeetDownloadTasks[id]?.cancel()
        parakeetDownloadTasks.removeValue(forKey: id)
        state.modelDownloads.removeValue(forKey: id)
        state.statusText = ModelDownloadPresenter.canceledStatus
    }

    /// UNUserNotificationCenter aborts in unbundled processes (swift run,
    /// self-tests), so every touch point checks for a real bundle first.
    private var canPostNotifications: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    private func postNotification(title: String, body: String) {
        guard canPostNotifications else { return }

        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    private func postNotification(_ copy: AppNotificationCopy) {
        postNotification(title: copy.title, body: copy.body)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        var errorDescription: String?
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            errorDescription = error.localizedDescription
        }

        // LOGIN-ITEM-APPROVAL (YA-60): report what macOS actually did.
        let outcome = LaunchAtLoginPresenter.outcome(
            requestedEnabled: enabled,
            status: LaunchAtLogin.currentStatus,
            errorDescription: errorDescription
        )
        // YA-38: login-item feedback stays on the SETUP tab.
        if let feedback = LaunchAtLoginPresenter.feedback(for: outcome, requestedEnabled: enabled, errorDescription: errorDescription) {
            state.postFeedback(feedback, on: .settings)
        }
        state.launchAtLoginEnabled = outcome.isEnabled
        state.launchAtLoginNeedsApproval = outcome.needsApproval
    }

    private func requestAccessibilityAccess() {
        permissionCoordinator.requestAccessibilityAccess()
    }

    // STALE-TCC-DETECT: single funnel for every accessibility trust read. It
    // records the session "was trusted" flag and recomputes the stale verdict
    // both popovers observe, so a silent revert or a grant that does not stick
    // surfaces the recovery affordance.
    private func updateAccessibilityTrust(_ trusted: Bool) {
        let wasTrusted = state.isAccessibilityTrusted
        permissionCoordinator.updateAccessibilityTrust(trusted)
        // SHORTCUTS: restart the one-key monitor once Accessibility arrives.
        if trusted, !wasTrusted, state.config.shortcuts.modifierHold != nil {
            applyShortcuts(state.config.shortcuts)
        }
    }

    // STALE-TCC-DETECT: explicit, never automatic. Clears the stale entry, then
    // re-prompts and opens the pane so the user grants once more against the
    // current signature. Targets only this bundle id and only Accessibility.
    private func resetAndRegrantAccessibility() {
        permissionCoordinator.resetAndRegrantAccessibility()
    }

    // MIC-LIVE-VERIFY: fire the system prompt, then poll the live status until
    // authorized (or until the user fixes Settings on the denied path).
    private func requestMicrophoneAccess() {
        permissionCoordinator.requestMicrophoneAccess()
    }

    // MIC-LIVE-VERIFY: read the live status (no prompt) and mirror it into the
    // observable state the guided step reads.
    private func refreshMicrophoneState() {
        permissionCoordinator.refreshMicrophoneState()
    }

    private func openMicrophonePrivacySettings() {
        permissionCoordinator.openMicrophonePrivacySettings()
    }

    // GUIDED-FIRST-RUN: flip the flag once every REQUIRED step for the current
    // config is satisfied, so offline (downloads off) and copy-only (auto-paste
    // off) users are not nagged forever waiting on a step they do not need.
    private func markGuidedSetupCompleteIfReady() {
        permissionCoordinator.markGuidedSetupCompleteIfReady()
    }

    /// COPY in HISTORY, FILES and the support report. HUD-RETURNS-TO-IDLE:
    /// the indicator shows COPIED for the usual hold, then shrinks back.
    private func copyText(_ text: String) {
        guard !text.isEmpty else { return }
        clipboard.copy(text)
        let status = PasteOutcomePresenter.copiedStatus()
        recordingSessions.presentTransient(status.phase, statusText: status.statusText)
        AccessibilityAnnouncer.shared.announcePasteOutcome(status)
    }

    /// HUD-RETURNS-TO-IDLE: a failure outside a dictation (loading or saving
    /// setup, words or a model choice) shows on the indicator and returns to
    /// idle like any other error.
    private func presentNonDictationError(_ message: String) {
        recordingSessions.presentTransient(.error(message), statusText: message)
    }

    private func toggleRecording() {
        // FIX(pasteReentry): a previous dictation may still be injecting text
        // (the Cmd+V verify spins the run loop, which can re-enter this method).
        // Drop the toggle with a visible reason so a new session cannot race the
        // paste and clobber the outcome mid-injection.
        guard !recordingSessions.isPasteInFlight else {
            state.statusText = L10n.tr("Still pasting the last dictation. One moment.")
            return
        }

        switch state.phase {
        case .recording:
            finishRecording()
        default:
            // Including .transcribing: the previous dictation keeps
            // transcribing in the background while a new one records.
            startRecording()
        }
    }

    private func startRecording() {
        let prerequisite = recordingPrerequisite()
        if prerequisite != .ready {
            presentRecordingBlocked(prerequisite)
            return
        }

        // YA-19: a new dictation ends the previous cancel's UNDO window.
        recorder.cleanup(cancelUndo.discard(now: Date(), onlyIfExpired: false))
        // COMMANDS: retry-last only ever holds the newest recording.
        lastRecording.clear()
        state.hudNote = nil
        state.petEventNote = nil
        // LEARN-FROM-FIXES: a new dictation ends the watch on the last paste.
        state.learnedWordNotice = nil
        autoLearn.settleNow()

        // PROFILES: the app in front now drives the badge and the live
        // preview while recording. The app in front when the recording
        // stops decides the profile and where the text goes; the start app
        // is only the fallback when no external app can be found then.
        let startTarget = captureExternalPasteTarget()
        let session = recordingSessions.begin(target: startTarget)
        RecentProfileApps.shared.note(bundleID: startTarget?.bundleIdentifier, name: startTarget?.application?.localizedName)
        state.dictationBadge = AppProfileResolver.resolve(
            base: state.config,
            bundleID: startTarget?.bundleIdentifier,
            lockedKeys: state.managedConfigKeys
        ).badge
        // FIX startRace: authorize this generation on the main thread BEFORE the
        // async start() runs. If a finish/cancel lands while start() is suspended
        // on the mic-permission await, recorder.stop() invalidates it and the
        // in-flight start tears its own session down (no orphaned hot mic).
        recorder.beginSession(session)
        state.phase = .recording
        state.statusText = state.hotkeyUnavailable
            ? HotkeyStatusCopy.listeningStatus(hotkeyAvailable: false, escCancels: state.config.escCancelsRecording)
            : ShortcutCopy.listeningStatus(state.config.shortcuts, cancelEnabled: state.config.escCancelsRecording)
        state.lastTranscript = ""
        state.isProcessing = false

        let preferredDeviceUID = state.config.inputDeviceUID
        let meterFloor: Float = state.config.quietVoiceBoost ? -55 : -42
        let startBundleID = startTarget?.bundleIdentifier

        Task {
            do {
                try await recorder.start(session: session, preferredDeviceUID: preferredDeviceUID, meterFloor: meterFloor)
                await MainActor.run {
                    // A finish/cancel may have superseded this start while it was
                    // suspended; the recorder already tore itself down, so don't
                    // arm esc / level monitoring / auto-stop for a dead session.
                    guard self.recordingSessions.isCurrent(session), self.state.phase == .recording else { return }
                    if self.state.config.playSounds {
                        self.soundPlayer.playStart()
                        // YA-53: keep the start chime out of the WAV.
                        self.recorder.excludeStartChime(duration: SoundPlayer.startChimeDuration)
                    }
                    // FIX(escBeforeStart): register bare-Escape cancel only after
                    // the mic actually started, not before start could fail.
                    self.registerEscapeToCancel()
                    self.startLivePreviewIfEnabled(bundleID: startBundleID)
                    self.recordingSessions.startLevelMonitoring()
                    // FIX(autoStopSession): schedule on main, inside the guard, so
                    // autoStopTask is only mutated on the main actor.
                    self.scheduleAutoStop()
                }
            } catch {
                await MainActor.run {
                    guard self.recordingSessions.isCurrent(session) else { return }
                    self.unregisterEscapeToCancel()
                    self.state.phase = .error(error.localizedDescription)
                    self.state.statusText = error.localizedDescription
                    self.scheduleReturnToIdle(after: PasteOutcomePresenter.holdSeconds(for: self.state.phase))
                }
            }
        }
    }

    private func recordingPrerequisite() -> RecordingPrerequisite {
        let config = state.config
        let selectedID = ModelCatalog.selectedID(for: config.modelPath)
        let option = ModelCatalog.option(for: selectedID)
        return RecordingPrerequisite.evaluate(
            config: config,
            selectedOption: option,
            selectedModelInstalled: option?.isInstalled ?? false,
            downloadProgress: option.flatMap { state.modelDownloads[$0.id] },
            whisperReadiness: transcriber.readiness(for: config),
            isPackagedApp: WhisperRuntimeCopy.isPackagedApp,
            qwen3RuntimeAvailable: Qwen3ASRRuntime.isAvailable(configuredLlamaBinary: config.llamaBinaryPath)
        )
    }

    // YA-01: a press that cannot record must be impossible to miss. The HUD
    // shows the reason, and the popover opens on MIC where the setup card
    // carries the DOWNLOAD action (or the live progress).
    private func presentRecordingBlocked(_ prerequisite: RecordingPrerequisite) {
        guard let message = prerequisite.message else { return }
        state.phase = .error(message)
        state.statusText = message
        scheduleReturnToIdle(after: 5.0)
        requestTab(.home)
        if let button = statusItem?.button {
            windowCoordinator.showPopover(anchor: button)
        } else {
            windowCoordinator.showControlWindow()
        }
    }

    /// Asks every open surface to switch tab. Cleared shortly after so a
    /// later reopen keeps whatever tab the user picked.
    private func requestTab(_ tab: BrutalTab) {
        state.requestedTab = tab
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            MainActor.assumeIsolated {
                guard self?.state.requestedTab == tab else { return }
                self?.state.requestedTab = nil
            }
        }
    }

    private func cancelRecording() {
        guard state.phase == .recording else { return }
        stopLivePreview()

        recordingSessions.cancelAutoStop()
        recordingSessions.stopLevelMonitoring()
        unregisterEscapeToCancel()

        let audioURL = recorder.stop()
        if state.config.playSounds {
            soundPlayer.playStop()
            recorder.suppressWarmPreRoll(for: SoundPlayer.stopChimeDuration)
        }

        // The stop-time app, kept as KEEP's fallback target.
        let startTarget = recordingSessions.takePendingPasteTarget()
        let target = DictationTargetPolicy.sessionTarget(stopTarget: captureExternalPasteTarget(), startTarget: startTarget)
        guard let audioURL else {
            state.phase = .idle
            state.statusText = L10n.tr("Canceled. Nothing was pasted.")
            return
        }

        // YA-19: keep the audio for a few seconds so UNDO can still use it.
        let now = Date()
        recorder.cleanup(cancelUndo.hold(
            audioURL: audioURL,
            session: recordingSessions.currentSession,
            target: target,
            at: now
        ))
        state.phase = .canceled
        state.statusText = L10n.tr("Canceled. Press KEEP on the indicator within 5 seconds to bring it back.")
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(CancelUndoBuffer.window))
            guard let self, self.cancelUndo.pending?.audioURL == audioURL else { return }
            let expired = self.cancelUndo.discard(now: now.addingTimeInterval(CancelUndoBuffer.window), onlyIfExpired: true)
            self.recorder.cleanup(expired)
            if self.state.phase == .canceled {
                self.state.phase = .idle
                self.state.statusText = L10n.tr("Canceled. Nothing was pasted.")
            }
        }
    }

    /// YA-19: transcribe the dictation that was just canceled.
    private func undoCancel() {
        guard state.phase == .canceled,
              let pending = cancelUndo.takeForUndo(now: Date()),
              recordingSessions.isCurrent(pending.session) else { return }
        // KEEP follows the user: the app in front when KEEP is pressed, else
        // the app that was in front when the recording was canceled.
        let target = captureExternalPasteTarget(allowFallback: false) ?? pending.target
        processRecordedAudio(pending.audioURL, session: pending.session, sessionTarget: target)
    }

    private func startReadinessPolling() {
        readinessTimer?.invalidate()
        scheduleReadinessPoll()
    }

    /// The setup screen needs quick permission feedback, but a configured app
    /// should be effectively dormant between dictations. Model downloads and
    /// explicit settings changes already push their own updates, and opening
    /// the control window performs a full refresh, so a one-minute safety poll
    /// is enough after setup.
    nonisolated static func readinessPollInterval(hasCompletedGuidedSetup: Bool) -> TimeInterval {
        hasCompletedGuidedSetup ? 60.0 : 2.0
    }

    private func scheduleReadinessPoll() {
        // ONBOARDING: keep the quick poll until the steps are closed, even
        // when every permission is already granted.
        let interval = Self.readinessPollInterval(
            hasCompletedGuidedSetup: state.config.hasCompletedGuidedSetup && state.onboarding == nil
        )
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }

                let trusted = self.clipboard.accessibilityTrusted(promptIfNeeded: false)
                if trusted != self.state.isAccessibilityTrusted {
                    self.updateAccessibilityTrust(trusted)
                    if trusted {
                        self.state.statusText = L10n.tr("Auto-paste is on. Text pastes at your cursor.")
                    }
                }

                // MIC-LIVE-VERIFY: poll microphone here too so the guided step flips
                // live even when the dedicated repair loop is not running.
                self.refreshMicrophoneState()

                // FIX(readinessOverride): do NOT force Parakeet ready here. The old
                // unconditional isWhisperReady/isModelReady = true defeated
                // refreshReadiness()'s honest offline check (downloads off + nothing
                // cached must read not-ready) and would silently persist
                // hasCompletedGuidedSetup for a user who has nothing installed. The
                // presenter is the single source of truth for readiness.
                let selectedOption = ModelCatalog.option(
                    for: ModelCatalog.selectedID(for: self.state.config.modelPath)
                )
                let readiness = ModelReadinessPresenter.snapshot(
                    config: self.state.config,
                    whisperReadiness: self.transcriber.readiness(for: self.state.config),
                    selectedModelInstalled: selectedOption?.isInstalled ?? false
                )
                if readiness.isWhisperReady != self.state.isWhisperReady {
                    self.state.isWhisperReady = readiness.isWhisperReady
                }
                if readiness.isModelReady != self.state.isModelReady {
                    self.state.isModelReady = readiness.isModelReady
                }

                // GUIDED-FIRST-RUN: once every required step is satisfied, persist
                // completion so the wizard does not reappear on later launches.
                self.markGuidedSetupCompleteIfReady()
                self.scheduleReadinessPoll()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        readinessTimer = timer
    }

    private func scheduleAutoStop() {
        // FIX(autoStopSession): pin the generation so a stale auto-stop can never
        // finish a LATER session. Phase alone is not enough — the next dictation
        // is also .recording, so a fired-late timer would stop the wrong one.
        let session = recordingSessions.currentSession
        let maxSeconds = max(10, state.config.maxRecordingSeconds)
        recordingSessions.scheduleAutoStop(after: Int(maxSeconds), for: session) { [weak self] in
            self?.finishRecording(autoStopped: true)
        }
    }

    private func finishRecording(autoStopped: Bool = false) {
        stopLivePreview()
        recordingSessions.cancelAutoStop()
        recordingSessions.stopLevelMonitoring()
        unregisterEscapeToCancel()
        let audioURL = recorder.stop()
        if state.config.playSounds {
            soundPlayer.playStop()
            // YA-53: keep the stop chime out of the next warm pre-roll.
            recorder.suppressWarmPreRoll(for: SoundPlayer.stopChimeDuration)
        }

        guard let audioURL else {
            state.phase = .idle
            statusFlavorIndex += 1
            state.statusText = StatusFlavor.line(from: StatusFlavor.nothingRecorded, index: statusFlavorIndex)
            scheduleReturnToIdle(after: 1.2)
            return
        }

        let session = recordingSessions.currentSession
        // PROFILES / YA-18: the dictation belongs to the app in front when it
        // STOPS (auto-stop included). That app picks the profile and receives
        // the text; the start app is only a fallback.
        let startTarget = recordingSessions.takePendingPasteTarget()
        let sessionTarget = DictationTargetPolicy.sessionTarget(
            stopTarget: captureExternalPasteTarget(),
            startTarget: startTarget
        )
        if autoStopped {
            // YA-54: say why it stopped.
            state.hudNote = L10n.tr("TIME LIMIT")
        }
        transcribeRecording(audioURL: audioURL, retry: nil, session: session, sessionTarget: sessionTarget)
        if autoStopped, state.phase == .transcribing {
            state.statusText = HUDPresenter.autoStopStatus(limit: HUDPresenter.limitSeconds(for: state.config))
        }
    }

    // MARK: - LIVEFILE

    /// LIVE-PREVIEW: opt-in, Parakeet only. Samples stay in memory; the text
    /// goes to the HUD and nowhere else.
    private func startLivePreviewIfEnabled(bundleID: String?) {
        // PROFILES: preview with the model and language this dictation will
        // really use, so a profile's Whisper model turns the preview off and
        // its Parakeet variant is the one preloaded.
        let config = AppProfileResolver.resolve(
            base: state.config,
            bundleID: bundleID,
            lockedKeys: state.managedConfigKeys
        ).config
        guard LivePreviewPolicy.isEligible(config: config) else { return }
        let option = ModelCatalog.option(for: ModelCatalog.selectedID(for: config.modelPath))
        let variant = option?.parakeetVariant ?? "v3"
        let buffer = livePreview.start(context: variant)
        recorder.liveSampleTap = { samples in buffer.append(samples) }
        // The final transcription needs the model anyway, so load it now and
        // the preview can begin. Verified local cache only; never downloads.
        if option?.isInstalled == true {
            Task { [parakeet] in try? await parakeet.preload(variant: variant) }
        }
    }

    private func stopLivePreview() {
        recorder.liveSampleTap = nil
        livePreview.stop()
    }

    private func startFileTranscription(_ url: URL) {
        // Busy: the card already shows the running job.
        fileTranscription.start(url: url)
        requestTab(FileTranscriptionPresenter.destinationTab)
    }

    /// FILE-TRANSCRIPTION: each part goes through the same transcribe path as
    /// a dictation (engine, glossary, filler removal, output guard), then the
    /// optional local cleanup. Settings are snapshotted when the job starts.
    private func makeFileTranscriptionEngine() -> FileTranscriptionEngine {
        let userConfig = TranscriptionLanguage.transcriptionConfig(from: state.config)
        // Keep Parakeet loaded between parts; the user's choice applies after
        // the last one.
        var partConfig = userConfig
        partConfig.keepModelWarm = true
        let glossary = self.glossary
        return FileTranscriptionEngine(
            transcribePart: { [unowned self] url, nearSilence in
                // Read before `&&`: its autoclosure is not main-actor isolated
                // (Swift 6.3 reports sending `self` into it as a data race).
                let serverReady = self.whisperServer.isReady
                return try await self.transcribe(
                    audioURL: url,
                    useWarmServer: userConfig.keepModelWarm && serverReady,
                    config: partConfig,
                    glossary: glossary,
                    nearSilence: nearSilence,
                    announcesLoading: false
                )
            },
            cleanup: { text in
                await FileTranscriptionCleanup.apply(text, config: userConfig, glossary: glossary)
            },
            finish: { [unowned self] in
                guard !userConfig.keepModelWarm,
                      ModelCatalog.engine(for: userConfig.modelPath) == .parakeet,
                      self.state.phase != .recording,
                      self.state.phase != .transcribing else { return }
                await self.parakeet.unload()
            }
        )
    }

    /// YA-05: true while a failed dictation's audio is kept for a retry.
    var canRetryFailedDictation: Bool {
        failedDictations.hasPending
    }

    /// YA-05: runs the kept audio of the last failed dictation through the
    /// engine again. Safe to call from any UI; it does nothing while a
    /// dictation is recording or transcribing, or when nothing is kept.
    func retryFailedDictation() {
        guard state.phase != .recording, state.phase != .transcribing, !state.isProcessing else { return }
        guard let dictation = failedDictations.take() else { return }
        // The retry gets its own session so its result is delivered like a
        // fresh dictation into whatever app is in front now.
        transcribeRecording(
            audioURL: dictation.audioURL,
            retry: dictation,
            session: recordingSessions.currentSession,
            sessionTarget: nil
        )
    }

    /// YA-19: UNDO hands the kept canceled audio to the normal pipeline.
    private func processRecordedAudio(_ audioURL: URL, session: Int, sessionTarget: PasteTarget?) {
        transcribeRecording(audioURL: audioURL, retry: nil, session: session, sessionTarget: sessionTarget)
    }

    private func transcribeRecording(
        audioURL: URL,
        retry: RetryableDictation?,
        session: Int,
        sessionTarget: PasteTarget?,
        retranscription: Bool = false
    ) {
        // Inspect the recorded WAV itself instead of rejecting by live meter
        // level. Some valid microphones arrive very quiet and need the
        // normalizer below before the model can hear them. A retry reuses the
        // level measured before its first normalization.
        // YA-23: the warm pre-roll never counts as speech.
        let signalProfile = retry?.signalProfile ?? AudioNormalizer.signalProfile(
            url: audioURL,
            skippingLeadingSamples: recorder.lastStoppedPreRollFrames
        )
        guard retry != nil || signalProfile?.hasMeaningfulSignal == true else {
            recorder.cleanup(audioURL)
            state.phase = .error(L10n.tr("Heard nothing."))
            state.statusText = L10n.tr("The mic heard only silence. Pick your mic in Setup and run MIC CHECK there.")
            scheduleReturnToIdle(after: PasteOutcomePresenter.holdSeconds(for: state.phase))
            return
        }

        state.phase = .transcribing
        statusFlavorIndex += 1
        state.statusText = StatusFlavor.line(from: StatusFlavor.transcribing, index: statusFlavorIndex)
        state.isProcessing = true

        // Snapshot every transcription input on the main thread. AppConfig is a
        // value type (copy = isolated) and Glossary is immutable once built, so
        // the background Task reads these without racing the main thread
        // reassigning state.config / glossary (refreshReadiness, saveConfig,
        // saveGlossary, the readiness timer).
        // YA-25: English-only models get "en" here, without touching the saved
        // language.
        // PROFILES: the profile of the app in front when the recording
        // stopped overrides Setup for this dictation only; managed locks
        // still win. A retry has no stop app and runs with Setup.
        let profileResolution = AppProfileResolver.resolve(
            base: state.config,
            bundleID: sessionTarget?.bundleIdentifier,
            lockedKeys: state.managedConfigKeys
        )
        if recordingSessions.isCurrent(session) {
            state.dictationBadge = profileResolution.badge
        }
        let config = profileResolution.config
        let autoPasteOverride = profileResolution.autoPasteOverride
        let glossary = self.glossary
        let snippets = self.snippets
        let useWarmServer = config.keepModelWarm && whisperServer.isReady && profileResolution.canUseWarmServer
        inFlightAudio.insert(audioURL)

        // COMMANDS: keep this recording in memory for retry-last, before the
        // normalizer rewrites it and before cleanup deletes it.
        if retry == nil, recordingSessions.isCurrent(session) {
            lastRecording.remember(contentsOf: audioURL, signalProfile: signalProfile)
        }
        let spokenCommandsEnabled = config.spokenCommands

        // YA-48: the pre-normalization level decides whether a stock Whisper
        // phrase can be a silence hallucination.
        let nearSilence = WhisperOutputGuard.isNearSilence(signalProfile)

        Task {
            // YA-13: quit cleanup stops tracking this file once the Task ends.
            defer { self.inFlightAudio.remove(audioURL) }
            // YA-05: the recording stays on disk until a transcript is
            // delivered; a failure keeps it for a retry instead.
            do {
                let startedAt = Date()
                // Bring quiet or whispered recordings up to the loudness the
                // model expects before transcribing.
                AudioNormalizer.normalize(url: audioURL)
                var transcript = try await self.transcribe(
                    audioURL: audioURL,
                    useWarmServer: useWarmServer,
                    config: config,
                    glossary: glossary,
                    nearSilence: nearSilence
                )

                // LLM-CLEANUP (YA-10): optional local pass in the chosen mode.
                // Best-effort by design: LLMCleaner returns the raw transcript
                // with a reason on any failure (no runtime or model, timeout,
                // a rewrite that is not a cleanup), so this never loses a
                // dictation. The HUD says CLEANING meanwhile, and a hard
                // timeout caps the wait. Runs off-main; we're already in a
                // background Task here.
                let cleanupMode = config.cleanup
                // NUMBERS: the style, and the language its pass reads (the
                // dictation language, or the transcript's on AUTO).
                let numberPlan = NumberPlan.resolve(
                    style: config.numbers,
                    dictationLanguage: config.language,
                    transcript: transcript
                )
                var cleanupFallback: CleanupFallback?
                if cleanupMode.usesModel, LLMCleaner.isWorthCleaning(transcript) {
                    let shownNote = await MainActor.run { () -> (shown: Bool, previous: String?) in
                        guard self.recordingSessions.isCurrent(session) else { return (false, nil) }
                        let previous = self.state.hudNote
                        self.state.hudNote = cleanupMode.hudNote
                        self.state.statusText = L10n.tr("Cleaning up on this Mac…")
                        return (true, previous)
                    }
                    // Blocking call (waitUntilExit, capped by hardTimeout), run
                    // on GCD so it never parks a Swift-concurrency pool thread.
                    // GLOSSARY×LLM: the glossary canonicals ride along as
                    // protected spellings, and because a 1.5B model honors
                    // them only ~sometimes, the deterministic glossary pass is
                    // re-applied AFTER the rewrite — the glossary always has
                    // the last word on names and casing.
                    let input = transcript
                    let protectedTerms = LLMCleaner.protectedTerms(from: glossary)
                    let result = await withCheckedContinuation { continuation in
                        DispatchQueue.global(qos: .userInitiated).async {
                            continuation.resume(returning: LLMCleaner.cleanup(
                                text: input,
                                mode: cleanupMode,
                                protectedTerms: protectedTerms,
                                numbers: numberPlan,
                                llamaBinaryPath: config.llamaBinaryPath
                            ))
                        }
                    }
                    if case .fellBack(let fallback) = result.outcome {
                        cleanupFallback = fallback
                    }
                    transcript = result.outcome == .cleaned ? glossary.applyingCorrections(to: result.text) : input
                    let restoredNote = cleanupFallback?.hudNote ?? shownNote.previous
                    await MainActor.run {
                        guard shownNote.shown, self.recordingSessions.isCurrent(session) else { return }
                        self.state.hudNote = restoredNote
                    }
                }
                let finalCleanupFallback = cleanupFallback

                let elapsed = Date().timeIntervalSince(startedAt)
                let elapsedLabel = String(format: "%.1fs", elapsed)
                // COMMANDS: spoken edit commands run after cleanup and the
                // glossary, so nothing rewrites the line breaks.
                let commands = SpokenCommands.process(transcript, enabled: spokenCommandsEnabled)
                // NUMBERS: after cleanup, the glossary and the commands (so it
                // reads the final words, and gives the same result with
                // cleanup on or off) and BEFORE snippets, so a stored text is
                // never rewritten. Snippet phrases and glossary words are
                // protected, so a phrase saved as "twenty one pilots" still
                // matches as said.
                let numbered = NumberForms.apply(
                    commands.text,
                    plan: numberPlan,
                    protectedPhrases: LLMCleaner.protectedTerms(from: glossary),
                    protectedRanges: numberPlan.isActive ? snippets.phraseRanges(in: commands.text, glossary: glossary) : []
                )
                // SNIPPETS: spoken phrases expand last, after the commands, so
                // the stored text is pasted exactly as saved (a snippet that
                // holds "new line" is never turned into a line break).
                // Immutable snapshot for the MainActor closure (Swift 6 capture rules).
                let expanded = snippets.expanding(numbered, glossary: glossary)
                // TRANSLATION (round 2): last, so cleanup, commands and
                // snippets work on the words as spoken. A missing model or a
                // failure sends the untranslated text and says so.
                let translated = await self.translation.translate(
                    expanded, config: config, glossary: glossary,
                    isCurrent: { self.recordingSessions.isCurrent(session) }
                )
                let finalTranscript = translated.text
                let translationFallback = translated.fallback

                await MainActor.run {
                    if retry != nil, self.recordingSessions.isCurrent(session) {
                        self.lastRecording.markRecovered()
                    }
                    // COMMANDS: "scratch that" opening the dictation takes the
                    // previous one back out first.
                    if commands.undoPrevious {
                        self.undoLastInsertion()
                    }
                    guard commands.hasContent else {
                        self.finishCommandOnlyDictation(session: session, undid: commands.undoPrevious)
                        return
                    }
                    self.state.lastTranscript = finalTranscript
                    self.state.recordTranscript(finalTranscript)

                    let wordCount = finalTranscript.split(whereSeparator: \.isWhitespace).count
                    // petxp-gated-activepet: credit XP to the gated active pet
                    // (locked pets resolve to .none) so a locked selection never
                    // accrues per-pet XP. record() rechecks isUnlocked too.
                    // COMMANDS: a retry-last of a delivered dictation earns no
                    // second round of XP.
                    if !retranscription {
                        _ = self.petStatsStore.record(
                            words: wordCount,
                            pet: self.state.activePet.rawValue,
                            gamified: self.state.config.petEnabled
                        )
                    }
                    self.refreshPresentedPetStats()
                    self.state.lastSuccessAt = Date()

                    let petEvents = self.petStatsStore.lastEvents

                    // Reaction intensity: tiny dictations get a shrug, long
                    // monologues a double jump, milestones a storm. Silent
                    // while the pet and quests are off (YA-31).
                    self.state.celebrationIntensity = PetGamification.celebrationIntensity(
                        enabled: self.state.config.petEnabled,
                        hasEvents: !petEvents.isEmpty,
                        wordCount: wordCount
                    )

                    self.updateAccessibilityTrust(self.clipboard.accessibilityTrusted(promptIfNeeded: false))

                    // PIPELINE (YA-02, YA-03, YA-18): the delivery coordinator
                    // pastes into the app in front now (or the stop target when
                    // YappYapp is in front), queues behind an in-flight paste,
                    // and copies plus notifies when a newer dictation took
                    // over. Nothing is dropped.
                    self.delivery.completeDictation(
                        transcript: finalTranscript,
                        session: session,
                        sessionTarget: sessionTarget,
                        elapsedLabel: elapsedLabel,
                        hasPetNews: !petEvents.isEmpty,
                        autoPasteOverride: autoPasteOverride
                    )

                    if !petEvents.isEmpty {
                        self.announcePetEvents(petEvents)
                    }

                    // YA-10: say plainly when the raw transcript went out.
                    if let finalCleanupFallback {
                        self.state.postFeedback(.info(finalCleanupFallback.message, topic: "cleanup"), on: .home)
                    }
                    if let translationFallback {
                        self.state.postFeedback(.info(translationFallback.message, topic: "translation"), on: .home)
                    }

                    self.refreshReadiness(surfaceErrors: false)
                }

                // YA-05: the transcript is delivered, so the audio can go.
                await MainActor.run {
                    if let retry {
                        self.failedDictations.finished(retry)
                    } else {
                        self.recorder.cleanup(audioURL)
                    }
                    self.state.retryAvailable = self.failedDictations.hasPending
                }
            } catch {
                await MainActor.run {
                    // YA-05: keep what the user said unless there was nothing
                    // to transcribe, and say where to retry it.
                    var audioKept = false
                    if DictationFailurePresenter.keepsAudio(for: error) {
                        audioKept = self.failedDictations.keep(audioURL: audioURL, signalProfile: signalProfile)
                    }
                    // COMMANDS: retry-last now goes through the kept file, and
                    // the HUD and MIC tab offer RETRY.
                    if audioKept, self.recordingSessions.isCurrent(session) {
                        self.lastRecording.markFailed()
                    }
                    self.state.retryAvailable = self.failedDictations.hasPending
                    if !audioKept {
                        if let retry {
                            self.failedDictations.finished(retry)
                        } else {
                            self.recorder.cleanup(audioURL)
                        }
                    }

                    // Missing feature 3: a failure is announced even when a
                    // newer dictation owns the HUD.
                    let message = DictationFailurePresenter.message(for: error, audioKept: audioKept)
                    self.delivery.failDictation(
                        session: session,
                        message: message,
                        holdSeconds: audioKept ? 6.0 : nil,
                        audioKept: audioKept
                    )
                    guard self.recordingSessions.isCurrent(session) else { return }
                    self.refreshReadiness()
                }
            }
        }
    }

    private func transcribe(
        audioURL: URL,
        useWarmServer: Bool,
        config: AppConfig,
        glossary: Glossary,
        nearSilence: Bool,
        announcesLoading: Bool = true
    ) async throws -> String {
        // Watchdog: a hung transcription must never wedge the phase machine,
        // or the shortcut turns into a silent no-op. YA-01: nothing downloads
        // here any more; a cold Parakeet load only gets a modest extra margin.
        // YA-05: every budget scales with the length of the recording.
        let isParakeet = ModelCatalog.engine(for: config.modelPath) == .parakeet
        let variant = ModelCatalog.option(for: ModelCatalog.selectedID(for: config.modelPath))?.parakeetVariant ?? "v3"
        let parakeetLoaded = isParakeet ? await parakeet.isLoaded(variant: variant) : false
        let audioSeconds = TranscriptionTimeouts.audioDuration(of: audioURL) ?? 0
        let timeoutSeconds = TranscriptionWatchdog.timeoutSeconds(
            isParakeet: isParakeet,
            isLoaded: parakeetLoaded,
            audioSeconds: audioSeconds,
            beamSearch: config.quietVoiceBoost,
            isQwen3ASR: ModelCatalog.engine(for: config.modelPath) == .qwen3asr
        )

        // FIX(watchdogRace): a structured withThrowingTaskGroup implicitly AWAITS
        // its children when the closure returns, so a hung Parakeet download that
        // ignores cancellation would block the group from ever returning — the
        // timeout child could throw but the group would still wait on the hung
        // one, and the watchdog never actually unblocked the phase machine.
        // Race a continuation instead: whichever of {transcription, timeout}
        // finishes first resumes it exactly once; the loser is abandoned.
        return try await withCheckedThrowingContinuation { continuation in
            let gate = FirstResult()

            let work = Task { [self] in
                do {
                    let result = try await performTranscription(
                        audioURL: audioURL,
                        useWarmServer: useWarmServer,
                        config: config,
                        glossary: glossary,
                        audioSeconds: audioSeconds,
                        nearSilence: nearSilence,
                        announcesLoading: announcesLoading
                    )
                    gate.resolveOnce { continuation.resume(returning: result) }
                } catch {
                    gate.resolveOnce { continuation.resume(throwing: error) }
                }
            }

            Task {
                try? await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                gate.resolveOnce {
                    continuation.resume(throwing: WhisperError.timedOut)
                }
                // Best-effort cancel. A hung Parakeet download may ignore this;
                // that `work` task is INTENTIONALLY abandoned. The continuation
                // has already resumed, so the caller reaches a coherent
                // timed-out error state while the orphan finishes (or fails) on
                // its own without wedging the app.
                work.cancel()
            }
        }
    }

    private func performTranscription(
        audioURL: URL,
        useWarmServer: Bool,
        config: AppConfig,
        glossary: Glossary,
        audioSeconds: TimeInterval,
        nearSilence: Bool,
        announcesLoading: Bool
    ) async throws -> String {
        var result: String

        if ModelCatalog.engine(for: config.modelPath) == .parakeet {
            let selectedID = ModelCatalog.selectedID(for: config.modelPath)
            let option = ModelCatalog.option(for: selectedID)
            let variant = option?.parakeetVariant ?? "v3"
            let optionName = option?.name ?? "Parakeet"
            let isCached = option?.isInstalled ?? false

            if await !parakeet.isLoaded(variant: variant) {
                // YA-01: FluidAudio is forced offline, so an uncached model can
                // never load here, whatever the downloads setting says.
                if !isCached {
                    throw WhisperError.modelUnavailable(
                        MissingModelNotice(
                            modelID: selectedID,
                            modelName: optionName,
                            downloadsAllowed: config.allowModelDownloads,
                            downloadProgress: nil
                        ).message
                    )
                }

                // FILES: a file job never writes the MIC status line.
                if announcesLoading {
                    await MainActor.run {
                        self.state.statusText = L10n.tr("Loading %@…", optionName)
                    }
                }
            }

            let raw = try await parakeet.transcribe(audioURL: audioURL, variant: variant)
            result = glossary.applyingCorrections(to: raw)

            if !config.keepModelWarm {
                await parakeet.unload()
            }
        } else if let variant = Qwen3ASRVariant.from(modelPath: config.modelPath) {
            // QWEN3-ASR: the warm server when it holds this model, else the
            // one-shot helper. The language hint and glossary context travel
            // in the request; the language itself is detected on AUTO.
            guard Qwen3ASRModelStore.isVerified(variant) else {
                let option = ModelCatalog.option(for: ModelCatalog.selectedID(for: config.modelPath))
                throw WhisperError.modelUnavailable(
                    MissingModelNotice(
                        modelID: option?.id ?? "qwen3asr-0.6b",
                        modelName: option?.name ?? "Qwen3-ASR",
                        downloadsAllowed: config.allowModelDownloads,
                        downloadProgress: nil
                    ).message
                )
            }
            result = try await qwen3Transcriber.transcribe(
                audioURL: audioURL,
                variant: variant,
                config: config,
                glossary: glossary,
                audioSeconds: audioSeconds
            )

            // YA-48: the same guard as Whisper. The glossary context is the
            // only prompt Qwen3-ASR could read back.
            let verdict = WhisperOutputGuard.verdict(
                output: result,
                prompt: Qwen3ASRPrompt.context(glossary: glossary),
                promptParts: WhisperOutputGuard.promptParts(config: config, glossary: glossary),
                nearSilence: nearSilence
            )
            guard verdict == .keep else {
                throw WhisperError.noSpeech
            }
        } else {
            var transcript: String?
            let prompt = WhisperServerController.promptText(config: config, glossary: glossary)

            if useWarmServer {
                do {
                    let raw = try await whisperServer.transcribe(
                        audioURL: audioURL,
                        prompt: prompt,
                        timeout: TranscriptionTimeouts.serverRequestTimeout(
                            audioSeconds: audioSeconds,
                            beamSearch: config.quietVoiceBoost
                        )
                    )
                    transcript = glossary.applyingCorrections(to: raw)
                } catch {
                    // YA-05: only a server that could not take the request
                    // hands it to the cold CLI. A timeout means the server is
                    // still busy with this audio: replace it so the next
                    // dictation does not queue behind it, and keep the audio.
                    guard WhisperServerFailure.shouldFallBackToCLI(error) else {
                        if WhisperServerFailure.isTimeout(error) {
                            await MainActor.run { self.whisperServer.recycle() }
                            throw WhisperError.timedOut
                        }
                        throw error
                    }
                }
            }

            result = if let transcript {
                transcript
            } else {
                try await transcriber.transcribe(
                    audioURL: audioURL,
                    config: config,
                    glossary: glossary,
                    timeout: TranscriptionTimeouts.cliTimeout(
                        audioSeconds: audioSeconds,
                        beamSearch: config.quietVoiceBoost
                    )
                )
            }

            // YA-48: drop a silence hallucination or an echo of the prompt.
            let verdict = WhisperOutputGuard.verdict(
                output: result,
                prompt: prompt,
                promptParts: WhisperOutputGuard.promptParts(config: config, glossary: glossary),
                nearSilence: nearSilence
            )
            guard verdict == .keep else {
                throw WhisperError.noSpeech
            }
        }

        if config.removeFillerWords {
            result = FillerWords.removing(from: result)
        }

        return result
    }

    /// The always-on bar collapses by phase, not by hiding windows: after the
    /// outcome has been visible for a moment, return the phase to idle.
    private func scheduleReturnToIdle(after delay: TimeInterval) {
        recordingSessions.scheduleReturnToIdle(after: delay)
    }

    private func refreshReadiness(surfaceErrors: Bool = true) {
        do {
            state.config = try configStore.load()
            publishConfigStoreState()
            configureParakeetDownloads(allowed: state.config.allowModelDownloads)
            glossary = try Glossary.load(
                from: AppPaths.glossaryURL,
                lexicon: SpellCheckerLexicon.forDictationLanguage(state.config.language)
            )
            state.glossaryTermCount = glossary.count
            state.glossaryEntries = glossary.entries
            reloadSnippets()
            state.modelOptions = ModelCatalog.options
        } catch {
            if surfaceErrors {
                presentNonDictationError(error.localizedDescription)
            } else {
                logNonFatal("Readiness refresh after dictation failed: \(error.localizedDescription)")
            }
        }

        let selectedOption = ModelCatalog.option(for: ModelCatalog.selectedID(for: state.config.modelPath))
        let readiness = ModelReadinessPresenter.snapshot(
            config: state.config,
            whisperReadiness: transcriber.readiness(for: state.config),
            selectedModelInstalled: selectedOption?.isInstalled ?? false,
            qwen3RuntimeAvailable: Qwen3ASRRuntime.isAvailable(configuredLlamaBinary: state.config.llamaBinaryPath)
        )
        state.selectedModelID = readiness.selectedModelID
        state.selectedModelName = readiness.selectedModelName
        state.isWhisperReady = readiness.isWhisperReady
        state.isModelReady = readiness.isModelReady
        updateAccessibilityTrust(clipboard.accessibilityTrusted(promptIfNeeded: false))
        // MIC-LIVE-VERIFY: keep the guided microphone step in sync on every
        // readiness refresh (launch, reopen, dictation finish).
        refreshMicrophoneState()
        state.inputDevices = AudioInputDevices.all()
        let loginItem = LaunchAtLoginPresenter.refreshed(status: LaunchAtLogin.currentStatus)
        state.launchAtLoginEnabled = loginItem.isEnabled
        state.launchAtLoginNeedsApproval = loginItem.needsApproval
        applyWarmMicMode()
        applyUpdaterSettings()
        refreshCleanupReadiness()
        translation.refresh()
    }

    // SUPER-FAST-MODE: apply the warm-mic setting on every readiness refresh
    // (launch, popover open, settings save, dictation finish). Cheap when
    // nothing changed. YA-04: setWarmMode only records the wanted state; the
    // recorder's own serial queue builds or tears down the session (~100-300ms)
    // off main, and defers any change that lands mid-recording to stop().
    private func applyWarmMicMode() {
        recorder.setWarmMode(enabled: state.config.superFastMode, preferredDeviceUID: state.config.inputDeviceUID)
    }

    // LLM-CLEANUP (YA-10): a cleanup mode needs the llama.cpp runtime and the
    // pinned model. The model is never fetched without the runtime, the
    // download shows progress and can be canceled, and "Cleanup model ready"
    // only appears once both are checked. Dictation is never blocked: until
    // then the raw transcript goes out and the MIC tab says why.
    private let cleanupDownloader = CleanupModelDownloader()
    // TRANSLATION (round 2): translation model downloads and the translate step.
    private lazy var translation = TranslationCoordinator(state: state)
    private var cleanupDownloadPhase: CleanupDownloadPhase = .idle
    private var cleanupVerifyInFlight = false

    private func refreshCleanupReadiness(_ config: AppConfig? = nil) {
        let config = config ?? state.config
        // Polled with readiness: skip the file checks while Verbatim, and
        // publish only real changes so SwiftUI does not redraw for nothing.
        let readiness = config.cleanup.usesModel
            ? CleanupReadiness.evaluate(
                mode: config.cleanup,
                runtimeAvailable: LLMCleaner.isRuntimeAvailable(configured: config.llamaBinaryPath),
                modelVerified: CleanupModelStore.isVerified(),
                downloadsAllowed: config.allowModelDownloads,
                download: cleanupDownloadPhase
            )
            : .off
        if readiness != state.cleanupReadiness {
            state.cleanupReadiness = readiness
            // A model that just verified, or a runtime that went away.
            synchronizeCleanupServer()
        }
    }

    // MARK: - LLM-CLEANUP-WARM

    private let cleanupServer = LlamaServerController.cleanup
    private let translationServer = LlamaServerController.translation
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var memoryPressureCritical = false

    /// Every warm llama-server: after a save, at launch and on a memory
    /// pressure change.
    private func synchronizeLlamaServers() {
        synchronizeCleanupServer()
        synchronizeTranslationServer()
        synchronizeSpeechServer()
    }

    /// TRANSLATION-WARM: keeps the chosen translation model loaded while a
    /// target is set, its model is verified, "keep the model warm" is on and
    /// memory is not critical. Choosing the other model replaces the server.
    private func synchronizeTranslationServer() {
        guard !isLaunchSmoke else { return }
        let config = state.config
        let verified = state.translationModels.verified
        translationServer.synchronize(TranslationServerPolicy.launch(
            config: config,
            runtimeBinary: LLMCleaner.binaryPath(configured: config.llamaBinaryPath),
            modelVerified: { verified.contains($0) },
            modelPath: { TranslationModelStore.modelURL(for: $0).path },
            memoryPressureCritical: memoryPressureCritical,
            launchable: { HelperBinaryPolicy.launchablePath($0) }
        ))
    }

    /// Keeps the cleanup model loaded in a warm llama-server while cleanup
    /// can run, "keep the model warm" is on and memory is not critical.
    /// Polled readiness and every save land here; it is a no-op when nothing
    /// changed.
    private func synchronizeCleanupServer() {
        guard !isLaunchSmoke else { return }
        let config = state.config
        cleanupServer.synchronize(CleanupServerPolicy.launch(
            config: config,
            runtimeBinary: LLMCleaner.binaryPath(configured: config.llamaBinaryPath),
            modelVerified: CleanupModelStore.isVerified(),
            modelPath: LLMCleaner.modelURL.path,
            memoryPressureCritical: memoryPressureCritical,
            launchable: { HelperBinaryPolicy.launchablePath($0) }
        ))
    }

    /// Critical memory pressure gives the cleanup, translation and speech models'
    /// memory back; the one-shot helper covers dictations until pressure is
    /// normal again.
    private func observeMemoryPressure() {
        guard memoryPressureSource == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let event = self.memoryPressureSource?.data else { return }
                let critical = event.contains(.critical)
                guard critical != self.memoryPressureCritical, critical || event.contains(.normal) else { return }
                self.memoryPressureCritical = critical
                self.synchronizeLlamaServers()
            }
        }
        source.resume()
        memoryPressureSource = source
    }

    private func prepareCleanupModelAtLaunch() {
        refreshCleanupReadiness()
        if case .needsModel = state.cleanupReadiness, LLMCleaner.isModelInstalled() {
            verifyInstalledCleanupModel(thenDownload: false)
        }
    }

    private func ensureCleanupModelIfEnabled(_ config: AppConfig) {
        refreshCleanupReadiness(config)
        switch state.cleanupReadiness {
        case .needsRuntime:
            state.postFeedback(.error(state.cleanupReadiness.detail, topic: "cleanup"), on: .settings)
        case .needsModel(let downloadsAllowed):
            if LLMCleaner.isModelInstalled() {
                verifyInstalledCleanupModel(thenDownload: downloadsAllowed)
            } else if downloadsAllowed {
                startCleanupModelDownload()
            } else {
                state.postFeedback(.error(state.cleanupReadiness.detail, topic: "cleanup"), on: .settings)
            }
        default:
            break
        }
    }

    private func verifyInstalledCleanupModel(thenDownload: Bool) {
        guard !cleanupVerifyInFlight else { return }
        cleanupVerifyInFlight = true
        cleanupDownloadPhase = .verifying
        refreshCleanupReadiness()
        DispatchQueue.global(qos: .utility).async {
            let verified = (try? CleanupModelStore.verifyExisting()) ?? false
            Task { @MainActor in
                self.cleanupVerifyInFlight = false
                self.cleanupDownloadPhase = .idle
                self.refreshCleanupReadiness()
                if verified {
                    if self.state.cleanupReadiness == .ready {
                        self.state.postFeedback(.success(L10n.tr("Cleanup model ready."), topic: "cleanup"), on: .settings)
                    }
                } else if thenDownload {
                    self.startCleanupModelDownload()
                }
            }
        }
    }

    func startCleanupModelDownload() {
        let config = state.config
        guard config.cleanup.usesModel, config.allowModelDownloads, !cleanupVerifyInFlight,
              LLMCleaner.isRuntimeAvailable(configured: config.llamaBinaryPath) else {
            refreshCleanupReadiness()
            return
        }
        let started = cleanupDownloader.start(
            progress: { [weak self] fraction in
                guard let self else { return }
                self.cleanupDownloadPhase = .downloading(fraction: fraction)
                self.refreshCleanupReadiness()
            },
            completion: { [weak self] result in
                self?.finishCleanupModelDownload(result)
            }
        )
        guard started else { return }
        cleanupDownloadPhase = .downloading(fraction: nil)
        refreshCleanupReadiness()
        state.postFeedback(.info(state.cleanupReadiness.detail, topic: "cleanup"), on: .settings)
    }

    func cancelCleanupModelDownload() {
        cleanupDownloader.cancel()
    }

    private func finishCleanupModelDownload(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            if (error as? CleanupModelError) == .canceled {
                cleanupDownloadPhase = .idle
                state.postFeedback(.info(L10n.tr("Cleanup download canceled. You get your words as spoken."), topic: "cleanup"), on: .settings)
            } else {
                let message = L10n.tr("Cleanup model download failed. %@", DownloadErrorCopy.plain(error))
                cleanupDownloadPhase = .failed(message)
                state.postFeedback(.error(message, topic: "cleanup"), on: .settings)
            }
            refreshCleanupReadiness()
        case .success(let staged):
            cleanupDownloadPhase = .verifying
            refreshCleanupReadiness()
            DispatchQueue.global(qos: .utility).async {
                var failure: Error?
                do {
                    try CleanupModelStore.install(downloadedFile: staged)
                } catch {
                    failure = error
                }
                let installError = failure
                Task { @MainActor in
                    if let installError {
                        let message = L10n.tr("Cleanup model not installed. %@", DownloadErrorCopy.plain(installError))
                        self.cleanupDownloadPhase = .failed(message)
                        self.state.postFeedback(.error(message, topic: "cleanup"), on: .settings)
                    } else {
                        self.cleanupDownloadPhase = .idle
                    }
                    self.refreshCleanupReadiness()
                    if self.state.cleanupReadiness == .ready {
                        self.state.postFeedback(.success(L10n.tr("Cleanup model ready."), topic: "cleanup"), on: .settings)
                    }
                }
            }
        }
    }

    // MARK: - TRANSLATION and SCAN MY MAC (round 2)

    /// MODELS: the translation model the user picks. A model that is not on
    /// disk starts downloading, like a speech model row.
    private func selectTranslationModel(_ id: TranslationModelID) {
        var config = state.config
        config.translationModelID = id
        if config != state.config {
            saveConfig(config)
        }
        if !TranslationModelStore.isVerified(id) {
            translation.startDownload(id)
        }
    }

    /// SCAN MY MAC: read the hardware off main, then recommend.
    private func scanMac() {
        let installed = installedModels()
        // The dictation language steers the speech pick, as in onboarding.
        let languages: Set<String> = [state.config.language]
        let whisperAvailable = HelperBinaryPolicy.validate(state.config.whisperBinaryPath).allowedPath != nil
        let qwen3ASRAvailable = Qwen3ASRRuntime.isAvailable(configuredLlamaBinary: state.config.llamaBinaryPath)
        DispatchQueue.global(qos: .userInitiated).async {
            let profile = HardwareScanner.read()
            let scan = HardwareScan(profile: profile, recommendations: ModelAdvisor.recommend(
                for: profile, installed: installed, languages: languages, whisperAvailable: whisperAvailable,
                qwen3ASRAvailable: qwen3ASRAvailable
            ))
            Task { @MainActor in
                self.state.hardwareScan = scan
            }
        }
    }

    /// USE THIS on a recommendation: select it, downloading when needed.
    private func applyRecommendation(_ choice: RecommendedChoice) {
        switch choice {
        case .speech(let id):
            selectModel(id: id)
        case .cleanup(let mode):
            var config = state.config
            config.cleanup = mode
            saveConfig(config)
        case .translation(let id):
            selectTranslationModel(id)
        case .none:
            break
        }
    }

    private func logNonFatal(_ message: String) {
        FileHandle.standardError.write(Data("YappYapp non-fatal: \(message)\n".utf8))
    }
}

extension AppDelegate: @preconcurrency UNUserNotificationCenterDelegate {
    /// Download-complete banners must show even while the popover has focus,
    /// which macOS otherwise suppresses for the foreground app.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

/// FIX(watchdogRace): serializes the first-wins resolution of a transcription
/// against its timeout. Guarantees the shared continuation is resumed exactly
/// once no matter which racer finishes first (double-resume would crash), and
/// lets the loser be abandoned instead of awaited.
private final class FirstResult {
    private let lock = NSLock()
    private var resolved = false

    func resolveOnce(_ body: () -> Void) {
        lock.lock()
        let isFirst = !resolved
        resolved = true
        lock.unlock()
        if isFirst { body() }
    }
}
