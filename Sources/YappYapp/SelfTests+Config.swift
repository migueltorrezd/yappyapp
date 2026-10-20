#if DEBUG
import Foundation
import ServiceManagement

// Self-tests owned by the "config" work track. Keep this track's new
// assertions here so parallel tracks never edit the same test lines.
extension SelfTests {
    static func configTrackTests() {
        configRecoveryDecodeTests()
        configRecoveryCrossTrackFieldTests()
        configRecoveryStoreTests()
        managedPreferencesTests()
        launchAtLoginTests()
        helperBinaryPolicyTests()
    }

    // MARK: - Sandbox

    /// Points AppPaths at a fresh folder under the self-test base (the
    /// YAPPYAPP_APP_SUPPORT_BASE dir when set), never the real Library.
    private static func withConfigSandbox(_ body: (URL) throws -> Void) throws {
        let root = ProcessInfo.processInfo.environment["YAPPYAPP_APP_SUPPORT_BASE"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        let base = root.appendingPathComponent("config-track-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let previous = AppPaths.applicationSupportBaseOverride
        AppPaths.applicationSupportBaseOverride = base
        defer {
            AppPaths.applicationSupportBaseOverride = previous
            try? FileManager.default.removeItem(at: base)
        }
        try body(base)
    }

    private static func configJSON(_ fields: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    }

    private static var coreFields: [String: Any] {
        [
            "whisperBinaryPath": "/opt/homebrew/bin/whisper-cli",
            "modelPath": "parakeet://parakeet-tdt-0.6b-v3",
            "language": "fr",
            "additionalPrompt": "",
            "maxRecordingSeconds": 300,
            "restoreClipboardAfterPaste": true,
            "pasteWhenFocusIsUnclear": true
        ]
    }

    // MARK: - Every field survives the recovery decoder

    /// config.json is always read through ConfigRecovery, so a field the
    /// decoder does not map would silently reset on every launch. Added after
    /// the wave 1 merge, when four tracks added config fields.
    private static func configRecoveryCrossTrackFieldTests() {
        test("configRecovery.everyEncodedKeyIsMapped") {
            let data = try JSONEncoder().encode(AppConfig.defaultConfig)
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let unmapped = Set(object.keys).subtracting(ConfigRecovery.fieldTypes.keys)
            expect(unmapped.isEmpty, "keys missing from ConfigRecovery.fieldTypes: \(unmapped.sorted())")
        }

        test("configRecovery.nonDefaultValuesRoundTrip") {
            var config = AppConfig.defaultConfig
            config.petEnabled = false
            config.textSize = "larger"
            config.autoPaste = false
            config.escCancelsRecording = false
            config.showTextInNotifications = true
            var shortcuts = ShortcutSettings.default
            shortcuts.mode = .hold
            shortcuts.modifierHold = .rightOption
            config.shortcuts = shortcuts
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let outcome = ConfigRecovery.decode(
                data: try encoder.encode(config),
                installDefaults: AppConfig.defaultConfig,
                lastSaved: { nil }
            )
            expect(!outcome.isDamaged, "a file the app wrote is intact")
            expectEqual(outcome.config, config)
        }

        test("configRecovery.olderFileAutoPasteFollowsLegacyToggle") {
            var fields = coreFields
            fields["pasteWhenFocusIsUnclear"] = false
            let outcome = ConfigRecovery.decode(
                data: try configJSON(fields),
                installDefaults: AppConfig.defaultConfig,
                lastSaved: { nil }
            )
            expectEqual(outcome.config.autoPaste, false, "the old toggle said copy only")
            expectEqual(outcome.config.escCancelsRecording, true)
            expectEqual(outcome.config.petEnabled, true)
            expectEqual(outcome.config.shortcuts, ShortcutSettings.default)
        }

        test("configRecovery.wrongTypedShortcutsCostOnlyShortcuts") {
            var fields = coreFields
            fields["shortcuts"] = "option space"
            fields["textSize"] = "large"
            let outcome = ConfigRecovery.decode(
                data: try configJSON(fields),
                installDefaults: AppConfig.defaultConfig,
                lastSaved: { nil }
            )
            expectEqual(outcome.config.shortcuts, ShortcutSettings.default)
            expectEqual(outcome.config.textSize, "large")
        }
    }

    // MARK: - YA-26 decode

    private static func configRecoveryDecodeTests() {
        let defaults = AppConfig.defaultConfig

        test("configRecovery.olderIntactFileIsNotDamage") {
            let outcome = ConfigRecovery.decode(
                data: try configJSON(coreFields),
                installDefaults: defaults,
                lastSaved: { nil }
            )
            expect(!outcome.isDamaged, "a file from before newer keys existed is intact")
            expectEqual(outcome.config.language, "fr")
            expectEqual(outcome.config.allowModelDownloads, true, "older intact file keeps the old downloads default")
            expectEqual(outcome.config.hasCompletedGuidedSetup, false)
            expect(!outcome.downloadsFailedClosed, "nothing failed closed")
        }

        test("configRecovery.unknownKeysAreIgnored") {
            var fields = coreFields
            fields["appearance"] = "dark"
            let outcome = ConfigRecovery.decode(
                data: try configJSON(fields),
                installDefaults: defaults,
                lastSaved: { nil }
            )
            expect(!outcome.isDamaged, "a removed key is not damage")
        }

        test("configRecovery.wrongTypedKeyCostsOnlyThatKey") {
            var fields = coreFields
            fields["playSounds"] = "loud"
            fields["allowModelDownloads"] = false
            fields["hasCompletedGuidedSetup"] = true
            let outcome = ConfigRecovery.decode(
                data: try configJSON(fields),
                installDefaults: defaults,
                lastSaved: { nil }
            )
            expect(outcome.isDamaged, "a wrong-typed value marks the file damaged")
            expectEqual(outcome.invalidKeys, ["playSounds"])
            expectEqual(outcome.config.playSounds, defaults.playSounds, "bad key falls back to default")
            expectEqual(outcome.config.language, "fr", "good keys survive")
            expectEqual(outcome.config.allowModelDownloads, false, "managed-off downloads stay off")
            expectEqual(outcome.config.hasCompletedGuidedSetup, true, "setup stays done")
        }

        test("configRecovery.wrongTypedDownloadsFailsClosed") {
            var fields = coreFields
            fields["allowModelDownloads"] = "nope"
            let outcome = ConfigRecovery.decode(
                data: try configJSON(fields),
                installDefaults: defaults,
                lastSaved: { nil }
            )
            expectEqual(outcome.config.allowModelDownloads, false, "unreadable downloads flag means off")
            expect(outcome.downloadsFailedClosed, "reported as failed closed")
        }

        test("configRecovery.numberIsNotABool") {
            var fields = coreFields
            fields["allowModelDownloads"] = 1
            let outcome = ConfigRecovery.decode(
                data: try configJSON(fields),
                installDefaults: defaults,
                lastSaved: { nil }
            )
            expectEqual(outcome.invalidKeys, ["allowModelDownloads"])
            expectEqual(outcome.config.allowModelDownloads, false)
        }

        test("configRecovery.truncatedFileSalvagesAndFailsClosed") {
            let text = #"{"language" : "es", "hasCompletedGuidedSetup" : true, "pet" : "fox", "allowModelDo"#
            let outcome = ConfigRecovery.decode(
                data: Data(text.utf8),
                installDefaults: defaults,
                lastSaved: { nil }
            )
            expect(outcome.isDamaged && outcome.wasUnreadable, "truncated JSON is damage")
            expectEqual(outcome.config.language, "es", "salvaged scalar")
            expectEqual(outcome.config.pet, "fox", "salvaged scalar")
            expectEqual(outcome.config.hasCompletedGuidedSetup, true, "salvaged setup flag keeps onboarding away")
            expectEqual(outcome.config.allowModelDownloads, false, "lost downloads flag fails closed")
            expect(outcome.downloadsFailedClosed, "reported")
        }

        test("configRecovery.truncatedFileKeepsSalvagedDownloadsOff") {
            let text = #"{"allowModelDownloads" : false, "language" : "en""#
            let outcome = ConfigRecovery.decode(
                data: Data(text.utf8),
                installDefaults: defaults,
                lastSaved: { nil }
            )
            expectEqual(outcome.config.allowModelDownloads, false)
            expect(!outcome.downloadsFailedClosed, "a salvaged value is not a fail-closed guess")
        }

        test("configRecovery.salvagedDownloadsOnIsHonored") {
            let text = #"{"allowModelDownloads" : true, "language" : "en""#
            let outcome = ConfigRecovery.decode(
                data: Data(text.utf8),
                installDefaults: defaults,
                lastSaved: { nil }
            )
            expectEqual(outcome.config.allowModelDownloads, true, "an explicit readable true is the user's choice")
        }

        test("configRecovery.restoresFromLastSave") {
            var saved = defaults
            saved.allowModelDownloads = false
            saved.hasCompletedGuidedSetup = true
            saved.language = "de"
            saved.playSounds = false
            let outcome = ConfigRecovery.decode(
                data: Data("{garbage".utf8),
                installDefaults: defaults,
                lastSaved: { saved }
            )
            expect(outcome.restoredFromLastSave, "uses the last saved copy")
            expectEqual(outcome.config.allowModelDownloads, false)
            expectEqual(outcome.config.hasCompletedGuidedSetup, true)
            expectEqual(outcome.config.language, "de")
            expectEqual(outcome.config.playSounds, false)
            expect(!outcome.downloadsFailedClosed, "a saved value is not a guess")
        }

        test("configRecovery.lastSaveNotConsultedWhenIntact") {
            var asked = false
            _ = ConfigRecovery.decode(
                data: try configJSON(coreFields),
                installDefaults: defaults,
                lastSaved: { asked = true; return nil }
            )
            expect(!asked, "an intact file never reads the backup copy")
        }

        test("configRecovery.priorUseKeepsSetupDone") {
            let outcome = ConfigRecovery.decode(
                data: Data("{".utf8),
                installDefaults: defaults,
                lastSaved: { nil },
                hasPriorUse: { true }
            )
            expectEqual(outcome.config.hasCompletedGuidedSetup, true, "a Mac that dictated before skips onboarding")

            let fresh = ConfigRecovery.decode(
                data: Data("{".utf8),
                installDefaults: defaults,
                lastSaved: { nil },
                hasPriorUse: { false }
            )
            expectEqual(fresh.config.hasCompletedGuidedSetup, false, "no evidence, no assumption")
        }

        test("configRecovery.hasPriorUseReadsStats") {
            try withConfigSandbox { base in
                let dir = base.appendingPathComponent("support", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                expect(!ConfigRecovery.hasPriorUse(in: dir), "no stats file")
                try Data(#"{"totalDictations": 0}"#.utf8).write(to: dir.appendingPathComponent("stats.json"))
                expect(!ConfigRecovery.hasPriorUse(in: dir), "zero dictations is not use")
                try Data(#"{"totalDictations": 4}"#.utf8).write(to: dir.appendingPathComponent("stats.json"))
                expect(ConfigRecovery.hasPriorUse(in: dir), "dictated before")
            }
        }

        test("configRecovery.jsonDecoderNeverThrowsOnBadValue") {
            var fields = coreFields
            fields["maxRecordingSeconds"] = "long"
            fields["quietVoiceBoost"] = "yes"
            let config = try JSONDecoder().decode(AppConfig.self, from: try configJSON(fields))
            expectEqual(config.maxRecordingSeconds, AppConfig.defaultConfig.maxRecordingSeconds)
            expectEqual(config.quietVoiceBoost, true)
            expectEqual(config.language, "fr")

            fields["allowModelDownloads"] = "on"
            let closed = try JSONDecoder().decode(AppConfig.self, from: try configJSON(fields))
            expectEqual(closed.allowModelDownloads, false, "Codable path fails closed too")

            fields.removeValue(forKey: "allowModelDownloads")
            let legacy = try JSONDecoder().decode(AppConfig.self, from: try configJSON(fields))
            expectEqual(legacy.allowModelDownloads, true, "absent key keeps the legacy default")
        }

        test("configRecovery.noticeCopy") {
            let notice = ConfigRecoveryNotice(
                backupFileName: "config.json.corrupt-2",
                restoredFromLastSave: false,
                downloadsTurnedOff: true
            )
            expectEqual(notice.title, "SETTINGS FILE REPAIRED")
            expect(notice.message.contains("config.json.corrupt-2"), "names the kept copy")
            expect(notice.message.contains("Model downloads stay off"), "says downloads are off")
            expect(!notice.message.contains("\u{2014}"), "no em dash in copy")

            let restored = ConfigRecoveryNotice(backupFileName: nil, restoredFromLastSave: true, downloadsTurnedOff: false)
            expect(restored.message.contains("last saved settings are back"), "restored copy")
            expect(!restored.message.contains("downloads"), "no downloads line when nothing changed")
        }
    }

    // MARK: - YA-26 store

    private static func configRecoveryStoreTests() {
        test("configRecovery.storeRepairsKeepsBackupAndNotifiesOnce") {
            try withConfigSandbox { _ in
                let store = ConfigStore(managedPreferences: StaticManagedPreferences())
                try store.prepareApplicationSupport()
                var config = try store.load()
                config.allowModelDownloads = false
                config.hasCompletedGuidedSetup = true
                config.language = "fr"
                try store.save(config)
                expect(FileManager.default.fileExists(atPath: AppPaths.lastSavedConfigURL.path), "last-good copy written")
                expect(store.takeRecoveryNotice() == nil, "no notice without damage")

                let damaged = Data(#"{"language": "fr", "whisperBinaryPath": "/x"#.utf8)
                try damaged.write(to: AppPaths.configURL)

                let fresh = ConfigStore(managedPreferences: StaticManagedPreferences())
                let repaired = try fresh.load()
                expectEqual(repaired.allowModelDownloads, false, "downloads stay off after repair")
                expectEqual(repaired.hasCompletedGuidedSetup, true, "onboarding does not re-run")
                expectEqual(repaired.language, "fr")
                expect(fresh.didRestoreDefaultsFromCorruptConfig, "legacy flag still set")

                let backupURL = AppPaths.supportDirectory.appendingPathComponent("config.json.corrupt-1")
                expectEqual(try Data(contentsOf: backupURL), damaged, "damaged bytes kept for diagnosis")

                let notice = fresh.takeRecoveryNotice()
                expect(notice != nil, "one notice after repair")
                expectEqual(notice?.backupFileName, "config.json.corrupt-1")
                expectEqual(notice?.restoredFromLastSave, true)
                expect(fresh.takeRecoveryNotice() == nil, "notice is handed out once")

                let reread = try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: AppPaths.configURL))
                expectEqual(reread.allowModelDownloads, false, "repaired file on disk")
                _ = try fresh.load()
                expect(fresh.takeRecoveryNotice() == nil, "a clean reload raises no new notice")
            }
        }

        test("configRecovery.storeWithoutLastSaveFailsClosed") {
            try withConfigSandbox { _ in
                let store = ConfigStore(managedPreferences: StaticManagedPreferences())
                try store.prepareApplicationSupport()
                try? FileManager.default.removeItem(at: AppPaths.lastSavedConfigURL)
                try Data("{\"lang".utf8).write(to: AppPaths.configURL)

                let repaired = try store.load()
                expectEqual(repaired.allowModelDownloads, false, "no trustworthy value means off")
                let notice = store.takeRecoveryNotice()
                expectEqual(notice?.downloadsTurnedOff, true)
                expectEqual(notice?.restoredFromLastSave, false)
            }
        }

        test("configRecovery.storeKeepsManagedValuesThroughCorruption") {
            try withConfigSandbox { _ in
                let managed = StaticManagedPreferences([
                    .allowModelDownloads: .bool(false),
                    .language: .string("nl")
                ])
                let store = ConfigStore(managedPreferences: managed)
                try store.prepareApplicationSupport()
                try? FileManager.default.removeItem(at: AppPaths.lastSavedConfigURL)
                try Data(#"{"allowModelDownloads": true, "language": "en", "#.utf8).write(to: AppPaths.configURL)

                let config = try store.load()
                expectEqual(config.allowModelDownloads, false, "managed off wins over a damaged file")
                expectEqual(config.language, "nl")
                expect(store.lockedKeys.contains(.allowModelDownloads), "still locked")
            }
        }

        test("configRecovery.existingInstallSeedsLastGoodCopy") {
            try withConfigSandbox { _ in
                let store = ConfigStore(managedPreferences: StaticManagedPreferences())
                try store.prepareApplicationSupport()
                try? FileManager.default.removeItem(at: AppPaths.lastSavedConfigURL)
                _ = try store.load()
                expect(FileManager.default.fileExists(atPath: AppPaths.lastSavedConfigURL.path),
                       "an upgrade from an older build gets a last-good copy on first intact load")
            }
        }
    }

    // MARK: - Managed preferences

    private static func managedPreferencesTests() {
        test("managedPrefs.valueCoercion") {
            expectEqual(ManagedValue.bool(true).boolValue, true)
            expectEqual(ManagedValue.number(0).boolValue, false)
            expectEqual(ManagedValue.number(2).boolValue, nil)
            expectEqual(ManagedValue.string(" Yes ").boolValue, true)
            expectEqual(ManagedValue.string("false").boolValue, false)
            expectEqual(ManagedValue.string("maybe").boolValue, nil)
            expectEqual(ManagedValue.string("  ").stringValue, nil)
            expectEqual(ManagedValue.bool(true).stringValue, nil)
        }

        test("managedPrefs.readValidatesValues") {
            let reader = StaticManagedPreferences([
                .allowModelDownloads: .bool(false),
                .automaticUpdateChecks: .string("no"),
                .selectedModel: .string("large-v3-turbo"),
                .language: .string("FR"),
                .petEnabled: .bool(false),
                .autoPaste: .bool(true),
                .learnFromFixes: .bool(false),
                .numberStyle: .string("digits")
            ])
            let overrides = ManagedOverrides.read(from: reader)
            expectEqual(overrides.numberStyle, .digits)
            expectEqual(overrides.learnFromFixes, false)
            expectEqual(overrides.apply(to: AppConfig.defaultConfig).learnFromFixes, false)
            expectEqual(overrides.restoringUserValues(in: overrides.apply(to: AppConfig.defaultConfig), from: AppConfig.defaultConfig).learnFromFixes, true)
            expectEqual(overrides.allowModelDownloads, false)
            expectEqual(overrides.automaticUpdateChecks, false)
            expectEqual(overrides.modelPath, ModelCatalog.option(for: "large-v3-turbo")?.defaultPath)
            expectEqual(overrides.language, "fr")
            expectEqual(overrides.lockedKeys, Set(ManagedConfigKey.allCases))

            let bad = ManagedOverrides.read(from: StaticManagedPreferences([
                .language: .string("klingon"),
                .selectedModel: .string("relative/model.bin"),
                .allowModelDownloads: .string("sometimes")
            ]))
            expect(bad.lockedKeys.isEmpty, "unusable values are ignored, nothing locks")
            expectEqual(ManagedOverrides.read(from: StaticManagedPreferences()), ManagedOverrides.none)
        }

        test("managedPrefs.modelSelectionForms") {
            expectEqual(ManagedOverrides.modelPath(forManagedSelection: "/Library/YappYapp/ggml-base.bin"),
                        "/Library/YappYapp/ggml-base.bin")
            expectEqual(ManagedOverrides.modelPath(forManagedSelection: "/a/../etc/model"), nil)
            expectEqual(ManagedOverrides.modelPath(forManagedSelection: "parakeet://nope"), nil)
            if let parakeet = ModelCatalog.option(for: "parakeet-v3")?.defaultPath {
                expectEqual(ManagedOverrides.modelPath(forManagedSelection: parakeet), parakeet)
            }
        }

        test("managedPrefs.petOnlyLocksWhenOff") {
            let on = ManagedOverrides.read(from: StaticManagedPreferences([.petEnabled: .bool(true)]))
            expect(!on.lockedKeys.contains(.petEnabled), "forcing the pet on leaves the choice to the user")
            var config = AppConfig.defaultConfig
            config.pet = "fox"
            expectEqual(on.apply(to: config).pet, "fox")

            let off = ManagedOverrides.read(from: StaticManagedPreferences([.petEnabled: .bool(false)]))
            expectEqual(off.apply(to: config).pet, PetKind.none.rawValue)
            // Integration with YA-31: a profile that turns the pet off also
            // turns the Pet and quests switch off, and saving keeps the user's own.
            expectEqual(off.apply(to: config).petEnabled, false)
            expectEqual(off.restoringUserValues(in: off.apply(to: config), from: config).petEnabled, true)
        }

        test("managedPrefs.applyAndRestore") {
            let overrides = ManagedOverrides.read(from: StaticManagedPreferences([
                .allowModelDownloads: .bool(false),
                .automaticUpdateChecks: .bool(false),
                .autoPaste: .bool(false),
                .language: .string("es")
            ]))
            var user = AppConfig.defaultConfig
            user.allowModelDownloads = true
            user.automaticUpdateChecks = true
            user.autoPaste = true
            user.language = "en"
            user.playSounds = true

            var effective = overrides.apply(to: user)
            expectEqual(effective.allowModelDownloads, false)
            expectEqual(effective.automaticUpdateChecks, false)
            expectEqual(effective.autoPaste, false)
            expectEqual(effective.language, "es")

            effective.playSounds = false
            let toWrite = overrides.restoringUserValues(in: effective, from: user)
            expectEqual(toWrite.allowModelDownloads, true, "forced value never overwrites the user's choice")
            expectEqual(toWrite.language, "en")
            expectEqual(toWrite.autoPaste, true)
            expectEqual(toWrite.playSounds, false, "unlocked edits still save")
        }

        test("managedPrefs.storeOverridesAndPreservesUserFile") {
            try withConfigSandbox { _ in
                let plain = ConfigStore(managedPreferences: StaticManagedPreferences())
                try plain.prepareApplicationSupport()
                var config = try plain.load()
                config.allowModelDownloads = true
                config.language = "en"
                try plain.save(config)

                let managed = ConfigStore(managedPreferences: StaticManagedPreferences([
                    .allowModelDownloads: .bool(false),
                    .language: .string("fr")
                ]))
                var effective = try managed.load()
                expectEqual(effective.allowModelDownloads, false, "profile wins over config.json")
                expectEqual(effective.language, "fr")
                expectEqual(managed.lockedKeys, [.allowModelDownloads, .language])

                effective.playSounds = false
                try managed.save(effective)
                let onDisk = try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: AppPaths.configURL))
                expectEqual(onDisk.allowModelDownloads, true, "user value kept on disk")
                expectEqual(onDisk.language, "en")
                expectEqual(onDisk.playSounds, false, "unlocked edit saved")

                let unmanaged = ConfigStore(managedPreferences: StaticManagedPreferences())
                let after = try unmanaged.load()
                expectEqual(after.allowModelDownloads, true, "removing the profile restores the user's choice")
                expect(unmanaged.lockedKeys.isEmpty, "nothing locked without a profile")
            }
        }

        test("managedPrefs.systemReaderIsInertWhenUnbundled") {
            let reader = SystemManagedPreferences(applicationID: nil)
            expect(reader.forcedValue(forKey: ManagedConfigKey.allowModelDownloads.rawValue) == nil,
                   "no app ID, no reads")
            if Bundle.main.bundleURL.pathExtension != "app" {
                expectEqual(SystemManagedPreferences.current.applicationID, nil,
                            "self-test never reads the host's managed domain")
            }
        }

        test("managedPrefs.cfValueConversion") {
            expectEqual(SystemManagedPreferences.managedValue(from: kCFBooleanFalse), .bool(false))
            expectEqual(SystemManagedPreferences.managedValue(from: NSNumber(value: 3)), .number(3))
            expectEqual(SystemManagedPreferences.managedValue(from: "fr" as CFString), .string("fr"))
            expectEqual(SystemManagedPreferences.managedValue(from: [1, 2] as CFArray), nil)
        }

        test("managedPrefs.copyHasNoEmDash") {
            for text in [ManagedPreferencesCopy.lockedTag, ManagedPreferencesCopy.lockedHelp,
                         ManagedPreferencesCopy.modelLockedStatus, ManagedPreferencesCopy.petLockedTitle] {
                expect(!text.contains("\u{2014}"), "no em dash: \(text)")
            }
        }
    }

    // MARK: - YA-60

    private static func launchAtLoginTests() {
        test("launchAtLogin.statusMapping") {
            expectEqual(LoginItemStatus(SMAppService.Status.enabled), .enabled)
            expectEqual(LoginItemStatus(SMAppService.Status.requiresApproval), .requiresApproval)
            expectEqual(LoginItemStatus(SMAppService.Status.notRegistered), .notRegistered)
            expectEqual(LoginItemStatus(SMAppService.Status.notFound), .notFound)
        }

        test("launchAtLogin.requiresApprovalIsNotSuccess") {
            let outcome = LaunchAtLoginPresenter.outcome(
                requestedEnabled: true,
                status: .requiresApproval,
                errorDescription: nil
            )
            expect(outcome.needsApproval, "flags approval")
            expect(!outcome.isEnabled, "not reported as enabled")
            expectEqual(outcome.statusText, LaunchAtLoginPresenter.needsApprovalStatus)
            expect(outcome.statusText?.contains("will start automatically") == false, "no false success")

            let withError = LaunchAtLoginPresenter.outcome(
                requestedEnabled: true,
                status: .requiresApproval,
                errorDescription: "Operation not permitted"
            )
            expectEqual(withError.statusText, LaunchAtLoginPresenter.needsApprovalStatus,
                        "approval is the actionable message even when register threw")
        }

        test("launchAtLogin.otherOutcomes") {
            let enabled = LaunchAtLoginPresenter.outcome(requestedEnabled: true, status: .enabled, errorDescription: nil)
            expectEqual(enabled.statusText, LaunchAtLoginPresenter.enabledStatus)
            expect(enabled.isEnabled && !enabled.needsApproval, "enabled")

            let silent = LaunchAtLoginPresenter.outcome(requestedEnabled: true, status: .notRegistered, errorDescription: nil)
            expectEqual(silent.statusText, LaunchAtLoginPresenter.notAddedStatus, "register without effect is not success")

            let failed = LaunchAtLoginPresenter.outcome(requestedEnabled: true, status: .notFound, errorDescription: "boom")
            expectEqual(failed.statusText, "Couldn't change Start at Login. boom")

            let off = LaunchAtLoginPresenter.outcome(requestedEnabled: false, status: .notRegistered, errorDescription: nil)
            expectEqual(off.statusText, LaunchAtLoginPresenter.disabledStatus)
            expect(!off.isEnabled && !off.needsApproval, "off")

            let refreshed = LaunchAtLoginPresenter.refreshed(status: .requiresApproval)
            expectEqual(refreshed.statusText, nil, "passive refresh stays quiet")
            expect(refreshed.needsApproval, "but still shows the approval row")
        }

        test("launchAtLogin.copy") {
            for text in [LaunchAtLoginPresenter.needsApprovalLabel, LaunchAtLoginPresenter.openLoginItemsTitle,
                         LaunchAtLoginPresenter.needsApprovalStatus, LaunchAtLoginPresenter.notAddedStatus] {
                expect(!text.contains("\u{2014}"), "no em dash: \(text)")
            }
            expect(LaunchAtLoginPresenter.needsApprovalLabel.contains("System Settings"), "names where to go")
        }
    }

    // MARK: - YA-63

    private static func helperBinaryPolicyTests() {
        let uid: UInt32 = 501
        let good = HelperFileFacts(exists: true, isRegularFile: true, isExecutable: true, posixPermissions: 0o755, ownerID: uid)
        func validate(_ path: String, _ facts: HelperFileFacts?, bundle: URL? = nil) -> HelperBinaryValidation {
            HelperBinaryPolicy.validate(path, bundleURL: bundle, currentUserID: uid, facts: { _ in facts })
        }

        test("helperBinary.refusesUnsafePaths") {
            expectEqual(validate("", good), .refused(.empty))
            expectEqual(validate("   ", good), .refused(.empty))
            expectEqual(validate("whisper-cli", good), .refused(.relativePath))
            expectEqual(validate("./bin/whisper-cli", good), .refused(.relativePath))
            expectEqual(validate("bin/../whisper-cli", good), .refused(.relativePath))
            expectEqual(validate("/opt/homebrew/bin/../../tmp/whisper-cli", good), .refused(.parentTraversal))
            expectEqual(validate("/opt/homebrew/bin/whisper-cli", nil), .refused(.missing))
        }

        test("helperBinary.refusesUnsafeFiles") {
            var facts = good
            facts.isRegularFile = false
            expectEqual(validate("/x/whisper-cli", facts), .refused(.notRegularFile))
            facts = good
            facts.isExecutable = false
            expectEqual(validate("/x/whisper-cli", facts), .refused(.notExecutable))
            facts = good
            facts.posixPermissions = 0o777
            expectEqual(validate("/x/whisper-cli", facts), .refused(.writableByOthers))
            facts.posixPermissions = 0o775
            expectEqual(validate("/x/whisper-cli", facts), .refused(.writableByOthers))
            facts = good
            facts.ownerID = 502
            expectEqual(validate("/x/whisper-cli", facts), .refused(.untrustedOwner))
            facts.ownerID = 0
            expectEqual(validate("/x/whisper-cli", facts), .allowed(path: "/x/whisper-cli", source: .userChosen),
                        "root-owned system installs are fine")
        }

        test("helperBinary.sourceClassification") {
            let bundle = URL(fileURLWithPath: "/Applications/YappYapp.app")
            expectEqual(HelperBinaryPolicy.source(of: "/Applications/YappYapp.app/Contents/Resources/bin/whisper-cli", bundleURL: bundle),
                        .appBundle)
            expectEqual(HelperBinaryPolicy.source(of: "/Applications/YappYapp.appx/whisper-cli", bundleURL: bundle),
                        .userChosen, "prefix match needs a path boundary")
            expectEqual(HelperBinaryPolicy.source(of: "/opt/homebrew/bin/whisper-cli", bundleURL: bundle), .userChosen)
            expectEqual(HelperBinaryPolicy.source(of: "/x/whisper-cli", bundleURL: URL(fileURLWithPath: "/usr/bin")),
                        .userChosen, "an unbundled process has no bundle source")
        }

        test("helperBinary.realFilesOnDisk") {
            try withConfigSandbox { base in
                let tool = base.appendingPathComponent("whisper-cli")
                try Data("#!/bin/sh\nexit 0\n".utf8).write(to: tool)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
                expectEqual(HelperBinaryPolicy.validate(tool.path).allowedPath, tool.path)

                try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: tool.path)
                expectEqual(HelperBinaryPolicy.validate(tool.path), .refused(.writableByOthers))
                if case .binaryRefused = WhisperError.binaryProblem(for: tool.path) {} else {
                    expect(false, "unsafe binary reports a refusal, not a missing file")
                }

                try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: tool.path)
                expectEqual(HelperBinaryPolicy.validate(tool.path), .refused(.notExecutable))

                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
                let link = base.appendingPathComponent("linked-cli")
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: tool)
                expectEqual(HelperBinaryPolicy.validate(link.path).allowedPath, link.path,
                            "symlinks like Homebrew's bin/ links resolve and pass")

                expectEqual(HelperBinaryPolicy.validate(base.path), .refused(.notRegularFile))
                expectEqual(HelperBinaryPolicy.validate(base.appendingPathComponent("nope").path), .refused(.missing))
            }
        }

        test("helperBinary.whisperReadinessAndErrors") {
            var config = AppConfig.defaultConfig
            config.whisperBinaryPath = "whisper-cli"
            expect(!WhisperTranscriber().readiness(for: config).binary, "relative path is never ready")
            if case .binaryRefused(_, let reason) = WhisperError.binaryProblem(for: "whisper-cli") {
                expect(reason.contains("relative"), "says why")
            } else {
                expect(false, "relative path reports a refusal")
            }
            if case .binaryMissing = WhisperError.binaryProblem(for: "/nonexistent/yappyapp/whisper-cli") {} else {
                expect(false, "an absent absolute path is still missing")
            }
            let message = WhisperError.binaryRefused("/x", "other users can modify it").localizedDescription
            expect(message.contains("will not run"), "refusal copy")
            expect(!message.contains("\u{2014}"), "no em dash")
        }

        test("helperBinary.llamaCandidates") {
            expectEqual(LLMCleaner.binaryCandidates(configured: LLMCleaner.stockBinaryPath),
                        ["/opt/homebrew/bin/llama-cli", "/usr/local/bin/llama-cli"])
            expectEqual(LLMCleaner.binaryCandidates(configured: ""),
                        ["/opt/homebrew/bin/llama-cli", "/usr/local/bin/llama-cli"])
            expectEqual(LLMCleaner.binaryCandidates(configured: "/Users/me/bin/llama-cli"),
                        ["/Users/me/bin/llama-cli"], "a chosen path never falls back elsewhere")
            expectEqual(LLMCleaner.binaryPath(configured: "llama-cli"), nil, "relative path refused")
        }

        test("helperBinary.serverRefusedWhenCliRelative") {
            expectEqual(
                HelperBinaryPolicy.validate(WhisperServerController.serverBinaryPath(forWhisperBinaryPath: "/abs/whisper-cli")),
                .refused(.missing)
            )
        }
    }
}
#endif
