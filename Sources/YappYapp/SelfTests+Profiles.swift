#if DEBUG
import AppKit
import Foundation
import SwiftUI

// Self-tests owned by the "profiles" work track. Keep this track's new
// assertions here so parallel tracks never edit the same test lines.
//
// Everything runs on fakes: no app list is read by the renders, nothing is
// pasted and config files live in scratch folders under the self-test base.
extension SelfTests {
    static func profilesTrackTests() {
        profilesConfigTests()
        profilesResolverTests()
        profilesStoreTests()
        profilesDeliveryTests()
        profilesBadgeTests()
        profilesCandidateTests()
        profilesRenderTests()
    }

    // MARK: - Helpers

    private final class ProfileRecordingBackend: TranscriptDeliveryBackend {
        var autoPasteSeen: [Bool] = []
        var lastPasteRestoresClipboard: Bool { false }

        func insertOrCopy(_ text: String, config: AppConfig, target: PasteTarget?) -> PasteOutcome {
            autoPasteSeen.append(config.autoPaste)
            return config.autoPaste ? .pasted : .copiedOnly(.autoPasteOff)
        }

        @discardableResult
        func copy(_ text: String, purpose: PasteboardWritePurpose) -> Int { 0 }
    }

    private static func profilesScratchBase(_ name: String) throws -> URL {
        let base = ProcessInfo.processInfo.environment[AppPaths.applicationSupportBaseEnvironmentKey]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? temporaryURL("-profiles")
        let directory = base.appendingPathComponent("profiles-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func withProfilesSupportBase(_ name: String, _ body: (URL) throws -> Void) throws {
        let base = try profilesScratchBase(name)
        let previous = AppPaths.applicationSupportBaseOverride
        AppPaths.applicationSupportBaseOverride = base
        defer {
            AppPaths.applicationSupportBaseOverride = previous
            try? FileManager.default.removeItem(at: base)
        }
        try body(base)
    }

    private static let slackID = "com.tinyspeck.slackmacgap"
    private static let mailID = "com.apple.mail"

    private static func sampleProfiles() -> [AppProfile] {
        [
            AppProfile(
                id: UUID(uuidString: "00000000-0000-0000-0000-00000000001A")!,
                bundleID: slackID, appName: "Slack", language: "fr", cleanupMode: "clean", pasteBehavior: .copyOnly
            ),
            AppProfile(
                id: UUID(uuidString: "00000000-0000-0000-0000-00000000002B")!,
                bundleID: mailID, appName: "Mail", cleanupMode: "verbatim", modelPath: "parakeet://v2"
            )
        ]
    }

    private static func baseConfig(profiles: [AppProfile] = sampleProfiles()) -> AppConfig {
        var config = AppConfig.defaultConfig
        config.language = "en"
        config.modelPath = "parakeet://v3"
        config.autoPaste = true
        config.cleanup = .verbatim
        config.appProfiles = profiles
        return config
    }

    // MARK: - Config

    private static func profilesConfigTests() {
        test("profiles.config.olderFileHasNoProfiles") {
            let legacy = #"{"whisperBinaryPath":"/x","modelPath":"parakeet://v3","language":"auto","additionalPrompt":"","maxRecordingSeconds":300,"restoreClipboardAfterPaste":true,"pasteWhenFocusIsUnclear":true}"#
            let config = try JSONDecoder().decode(AppConfig.self, from: Data(legacy.utf8))
            expectEqual(config.appProfiles, [], "a config from before profiles has none")
            expectEqual(AppConfig.defaultConfig.appProfiles, [], "nothing is created for you")
        }

        test("profiles.config.roundTrips") {
            let config = baseConfig()
            let data = try JSONEncoder().encode(config)
            let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
            expectEqual(decoded.appProfiles, config.appProfiles)
            let json = String(decoding: data, as: UTF8.self)
            expect(json.contains("\"copyOnly\""), "paste behavior is stored as a plain string")
        }

        test("profiles.config.oneBadProfileCostsOnlyItself") {
            let json = """
            {"modelPath":"parakeet://v3","appProfiles":[
              {"bundleID":"com.apple.mail","appName":"Mail","language":"fr","pasteBehavior":"teleport"},
              {"appName":"No bundle"},
              {"bundleID":"   "},
              42,
              {"bundleID":"COM.APPLE.MAIL","appName":"Duplicate"},
              {"bundleID":"com.tinyspeck.slackmacgap","modelPath":7}
            ]}
            """
            let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
            expectEqual(config.appProfiles.map(\.bundleID), [mailID, slackID], "damaged and duplicate entries are dropped")
            expectEqual(config.appProfiles.first?.pasteBehavior, nil, "an unknown paste value follows Setup")
            expectEqual(config.appProfiles.first?.language, "fr", "the rest of the profile survives")
            expectEqual(config.appProfiles.last?.appName, slackID, "a missing name shows the bundle ID")
            expectEqual(config.appProfiles.last?.modelPath, nil, "a wrong-typed model follows Setup")
        }

        test("profiles.config.wrongTypedListFallsBackAlone") {
            let json = #"{"modelPath":"parakeet://v3","language":"fr","appProfiles":"slack"}"#
            let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
            expectEqual(config.appProfiles, [])
            expectEqual(config.language, "fr", "other keys are untouched")
        }

        test("profiles.config.recoveryKeepsProfiles") {
            var full = try JSONSerialization.jsonObject(with: JSONEncoder().encode(baseConfig())) as! [String: Any]
            full["playSounds"] = "loud"
            let data = try JSONSerialization.data(withJSONObject: full)
            let outcome = ConfigRecovery.decode(data: data, installDefaults: .defaultConfig, lastSaved: { nil })
            expect(outcome.isDamaged, "the wrong-typed key marks damage")
            expectEqual(outcome.config.appProfiles, baseConfig().appProfiles, "a repair never drops profiles")

            full["playSounds"] = true
            full["appProfiles"] = ["not": "a list"]
            let damaged = ConfigRecovery.decode(
                data: try JSONSerialization.data(withJSONObject: full),
                installDefaults: .defaultConfig,
                lastSaved: { baseConfig() }
            )
            expect(damaged.invalidKeys.contains("appProfiles"), "a non-list is damage")
            expectEqual(damaged.config.appProfiles, baseConfig().appProfiles, "the last saved profiles come back")
            expectEqual(ConfigRecovery.fieldTypes["appProfiles"].map { ConfigRecovery.isValid([], as: $0) }, true)
        }
    }

    // MARK: - Resolution

    private static func profilesResolverTests() {
        let installed: (String) -> Bool = { _ in true }

        test("profiles.resolve.noProfileFollowsSetup") {
            let base = baseConfig()
            for bundleID in [nil, "", "com.example.other"] as [String?] {
                let resolution = AppProfileResolver.resolve(base: base, bundleID: bundleID, lockedKeys: [], isModelInstalled: installed)
                expectEqual(resolution.profile, nil)
                expectEqual(resolution.config, TranscriptionLanguage.transcriptionConfig(from: base))
                expectEqual(resolution.autoPasteOverride, nil)
                expectEqual(resolution.cleanupMode, nil)
                expect(resolution.canUseWarmServer, "Setup values match the warm server")
                expectEqual(resolution.blocked, [])
            }
        }

        test("profiles.resolve.profileOverridesThisDictationOnly") {
            let base = baseConfig()
            let resolution = AppProfileResolver.resolve(base: base, bundleID: slackID.uppercased(), lockedKeys: [], isModelInstalled: installed)
            expectEqual(resolution.profile?.appName, "Slack", "bundle IDs match without case")
            expectEqual(resolution.config.language, "fr")
            expect(resolution.config.llmCleanup, "clean turns cleanup on for Slack")
            expectEqual(resolution.config.cleanup, .clean, "the mode the pipeline reads is clean")
            expectEqual(base.cleanup, .verbatim, "Setup's cleanup mode is never changed")
            expectEqual(resolution.cleanupMode, "clean")
            expectEqual(resolution.autoPasteOverride, false, "copy only")
            expect(!resolution.config.autoPaste, "the effective config copies only")
            expect(!resolution.canUseWarmServer, "a new language cannot use the warm server")
            expectEqual(base.language, "en", "Setup is never changed")
            expect(base.autoPaste, "Setup paste is never changed")
        }

        test("profiles.resolve.verbatimAndEnglishOnlyModel") {
            var base = baseConfig()
            base.cleanup = .clean
            base.language = "fr"
            let resolution = AppProfileResolver.resolve(base: base, bundleID: mailID, lockedKeys: [], isModelInstalled: installed)
            expect(!resolution.config.llmCleanup, "verbatim turns cleanup off")
            expectEqual(resolution.config.cleanup, .verbatim, "the mode the pipeline reads is off too")
            expectEqual(resolution.config.modelPath, "parakeet://v2")
            expectEqual(resolution.config.language, "en", "an English-only model forces English")
            expectEqual(resolution.autoPasteOverride, nil, "no paste choice follows Setup")
            expect(!resolution.canUseWarmServer, "a different model cannot use the warm server")
        }

        test("profiles.resolve.managedLocksWin") {
            let base = baseConfig()
            let slack = AppProfileResolver.resolve(
                base: base, bundleID: slackID, lockedKeys: [.language, .autoPaste], isModelInstalled: installed
            )
            expectEqual(slack.config.language, "en", "a locked language is not overridden")
            expectEqual(slack.autoPasteOverride, nil, "a locked auto-paste is not overridden")
            expect(slack.config.autoPaste, "the forced value stays")
            expectEqual(slack.blocked, [.languageLocked, .pasteLocked])
            expect(slack.config.llmCleanup, "unmanaged overrides still apply")
            expect(slack.canUseWarmServer, "nothing that the warm server cares about changed")

            let mail = AppProfileResolver.resolve(base: base, bundleID: mailID, lockedKeys: [.selectedModel], isModelInstalled: installed)
            expectEqual(mail.config.modelPath, "parakeet://v3", "a locked model is not overridden")
            expectEqual(mail.blocked, [.modelLocked])
        }

        test("profiles.resolve.missingModelFallsBack") {
            let resolution = AppProfileResolver.resolve(
                base: baseConfig(), bundleID: mailID, lockedKeys: [], isModelInstalled: { _ in false }
            )
            expectEqual(resolution.config.modelPath, "parakeet://v3", "Setup's model runs")
            expectEqual(resolution.blocked, [.modelMissing("parakeet://v2")])
            expect(resolution.canUseWarmServer, "fallback keeps the Setup model")
        }

        test("profiles.resolve.unknownValuesFollowSetup") {
            let odd = AppProfile(bundleID: "com.example.odd", appName: "Odd", language: "klingon", cleanupMode: "pirate")
            let resolution = AppProfileResolver.resolve(
                base: baseConfig(profiles: [odd]), bundleID: "com.example.odd", lockedKeys: [], isModelInstalled: installed
            )
            expectEqual(resolution.config.language, "en")
            expect(!resolution.config.llmCleanup, "an unknown mode keeps Setup's cleanup")
            expectEqual(resolution.cleanupMode, nil)
            expectEqual(resolution.config.cleanup, .verbatim, "an unknown mode keeps Setup's mode")
            expectEqual(AppProfileResolver.cleanupEnabled(for: "email"), true)
            expectEqual(AppProfileResolver.cleanupEnabled(for: "list"), true)
            expectEqual(AppProfileResolver.cleanupEnabled(for: nil), nil)
        }

        // INTEGRATION: a profile's mode reaches the cleanup pass, which reads
        // config.cleanup (cleanupMode), not just the legacy llmCleanup flag.
        test("profiles.resolve.cleanupModesReachThePipeline") {
            expectEqual(ProfileCleanupMode.offered.map(\.rawValue), CleanupMode.allCases.map(\.rawValue),
                        "every Setup cleanup mode is offered per app")
            for mode in CleanupMode.allCases {
                let profile = AppProfile(bundleID: "com.example.mode", appName: "Mode", cleanupMode: mode.rawValue)
                var base = baseConfig(profiles: [profile])
                base.cleanup = mode == .clean ? .email : .clean
                let resolution = AppProfileResolver.resolve(
                    base: base, bundleID: "com.example.mode", lockedKeys: [], isModelInstalled: installed
                )
                expectEqual(resolution.config.cleanup, mode, "\(mode.rawValue) profile runs \(mode.rawValue)")
                expectEqual(resolution.config.llmCleanup, mode.usesModel, "\(mode.rawValue) keeps the legacy flag in step")
                expectEqual(ProfileCleanupMode(rawValue: mode.rawValue)?.label, mode.label)
            }
        }

        test("profiles.resolve.sameModelAsSetupIsNoChange") {
            let same = AppProfile(bundleID: "com.example.same", appName: "Same", modelPath: "parakeet://v3")
            let resolution = AppProfileResolver.resolve(
                base: baseConfig(profiles: [same]), bundleID: "com.example.same", lockedKeys: [.selectedModel], isModelInstalled: { _ in false }
            )
            expectEqual(resolution.blocked, [], "picking Setup's own model is never blocked")
            expect(resolution.canUseWarmServer, "same model, same server")
        }
    }

    // MARK: - Store and managed preferences

    private static func profilesStoreTests() {
        test("profiles.store.savedAndLoadedWithLocks") {
            try withProfilesSupportBase("store") { _ in
                let store = ConfigStore(managedPreferences: StaticManagedPreferences([.language: .string("es")]))
                try store.prepareApplicationSupport()
                try store.save(baseConfig())
                let loaded = try store.load()
                expectEqual(loaded.appProfiles, baseConfig().appProfiles, "profiles survive a save")
                expectEqual(loaded.language, "es", "the managed language applies")

                let resolution = AppProfileResolver.resolve(
                    base: loaded, bundleID: slackID, lockedKeys: store.lockedKeys, isModelInstalled: { _ in true }
                )
                expectEqual(resolution.config.language, "es", "the profile cannot beat the managed language")

                var edited = loaded
                edited.appProfiles.removeAll { $0.bundleID == mailID }
                try store.save(edited)
                expectEqual(try store.load().appProfiles.map(\.bundleID), [slackID], "removing a profile persists")
            }
        }
    }

    // MARK: - Delivery

    private static func profilesDeliveryTests() {
        test("profiles.delivery.copyOnlyAppliesToOneDictation") {
            let state = YappYappState()
            state.config.autoPaste = true
            let sessions = RecordingSessionCoordinator(state: state, recorder: RecordingController())
            let backend = ProfileRecordingBackend()
            let delivery = DictationDeliveryCoordinator(
                state: state,
                sessions: sessions,
                backend: backend,
                notifier: FakeDeliveryNotifier()
            )

            let first = sessions.begin(target: nil)
            delivery.completeDictation(
                transcript: "for slack",
                session: first,
                sessionTarget: nil,
                elapsedLabel: nil,
                hasPetNews: false,
                autoPasteOverride: false
            )
            let second = sessions.begin(target: nil)
            delivery.completeDictation(
                transcript: "anywhere",
                session: second,
                sessionTarget: nil,
                elapsedLabel: nil,
                hasPetNews: false
            )
            expectEqual(backend.autoPasteSeen, [false, true], "the override covers only its own dictation")
            expect(state.config.autoPaste, "Setup is never changed")

            state.config.autoPaste = false
            delivery.deliver(text: "paste here", to: nil, autoPasteOverride: true)
            expectEqual(backend.autoPasteSeen.last, true, "a paste profile pastes even when Setup copies")
            sessions.endPaste()
        }
    }

    // MARK: - Badge

    private static func profilesBadgeTests() {
        test("profiles.badge.text") {
            var config = baseConfig()
            config.language = "fr"
            let plain = DictationBadge.make(config: config, profile: nil)
            // Parakeet v3 ignores the language setting, so the badge never claims FR.
            expectEqual(plain.text, "AUTO · PARAKEET V3")
            expectEqual(plain.accessibilityLabel, "language auto, model parakeet v3")

            let profile = AppProfile(bundleID: "com.example.long", appName: "Extremely Long App Name")
            let named = DictationBadge.make(config: config, profile: profile)
            expectEqual(named.profileName, "EXTREMELY L…", "long app names are cut")
            expect(named.text.hasPrefix("EXTREMELY L… · AUTO"), named.text)

            config.language = "auto"
            config.modelPath = "/tmp/models/ggml-small.en.bin"
            expectEqual(DictationBadge.make(config: config, profile: nil).text, "AUTO · SMALL EN")
            config.language = "fr"
            config.modelPath = "/tmp/models/ggml-small.bin"
            expect(DictationBadge.make(config: config, profile: nil).text.hasPrefix("FR · "), "Whisper keeps the picked language")
            expectEqual(DictationBadge.modelLabel(for: "/tmp/custom-model.bin"), "CUSTOM-MODEL")
        }

        test("profiles.badge.followsTheResolvedDictation") {
            let resolution = AppProfileResolver.resolve(
                base: baseConfig(), bundleID: mailID, lockedKeys: [], isModelInstalled: { _ in true }
            )
            expectEqual(resolution.badge.text, "MAIL · EN · PARAKEET V2")
        }

        test("profiles.badge.spokenWhileDictating") {
            // The bar draws no badge; VoiceOver reads it while the dictation runs.
            let badge = AppProfileResolver.resolve(
                base: baseConfig(), bundleID: slackID, lockedKeys: [], isModelInstalled: { _ in true }
            ).badge
            for phase in [CapturePhase.recording, .transcribing] {
                expect(IndicatorAccessibility.value(caption: nil, badge: badge, phase: phase).contains(badge.accessibilityLabel),
                       "badge spoken for \(phase.label)")
            }
            for phase in [CapturePhase.idle, .pasted, .copied, .canceled, .error("x")] {
                expect(!IndicatorAccessibility.value(caption: nil, badge: badge, phase: phase).contains(badge.accessibilityLabel),
                       "badge quiet for \(phase.label)")
            }
        }

        test("profiles.badge.autoStopWarningStillThere") {
            // Missing feature 12's second half ships with the pipeline track (YA-54).
            expectEqual(HUDPresenter.countdown(elapsed: 295, limit: 300), 5)
            expectEqual(HUDPresenter.countdown(elapsed: 100, limit: 300), nil)
        }
    }

    // MARK: - Apps to add

    private static func profilesCandidateTests() {
        test("profiles.candidates.recentFirstAndNoDuplicates") {
            let recent = [ProfileAppCandidate(bundleID: slackID, name: "Slack")]
            let running = [
                ProfileAppCandidate(bundleID: "com.apple.Safari", name: "Safari"),
                ProfileAppCandidate(bundleID: "com.apple.Notes", name: "notes"),
                ProfileAppCandidate(bundleID: slackID, name: "Slack"),
                ProfileAppCandidate(bundleID: mailID, name: "Mail"),
                ProfileAppCandidate(bundleID: "com.yappyapp.app", name: "YappYapp")
            ]
            let merged = ProfileAppCandidates.merge(
                recent: recent,
                running: running,
                existing: [AppProfile(bundleID: "COM.APPLE.MAIL", appName: "Mail")],
                ownBundleID: "com.yappyapp.app"
            )
            expectEqual(merged.map(\.name), ["Slack", "notes", "Safari"])
        }

        test("profiles.candidates.recentIsBoundedAndInMemory") {
            let recent = RecentProfileApps()
            recent.note(bundleID: nil, name: "Nothing")
            for index in 0..<10 {
                recent.note(bundleID: "com.example.\(index)", name: "App \(index)")
            }
            recent.note(bundleID: "com.example.5", name: "App 5")
            expectEqual(recent.apps.count, RecentProfileApps.limit)
            expectEqual(recent.apps.first?.bundleID, "com.example.5", "the newest target leads")
            expectEqual(Set(recent.apps.map(\.bundleID)).count, recent.apps.count, "no duplicates")
        }

        test("profiles.copy.summary") {
            let profiles = sampleProfiles()
            expectEqual(AppProfileCopy.summary(profiles[0], modelChoices: []), "FR · CLEAN · COPY ONLY")
            expectEqual(AppProfileCopy.summary(profiles[1], modelChoices: []), "AS SPOKEN · PARAKEET V2")
            expectEqual(AppProfileCopy.summary(AppProfile(bundleID: "x", appName: "X"), modelChoices: []), "SAME AS SETUP")
            expect(AppProfileCopy.needsCleanupModel(profiles[0], installed: false), "clean without the model warns")
            expect(!AppProfileCopy.needsCleanupModel(profiles[1], installed: false), "verbatim needs nothing")
            for copy in [AppProfileCopy.intro, AppProfileCopy.empty, AppProfileCopy.modelMissing, AppProfileCopy.cleanupModelMissing] {
                expect(!copy.contains("\u{2014}"), "no em dashes: \(copy)")
            }
        }
    }

    // MARK: - Rendering

    private static func profilesRenderTests() {
        test("profiles.render.settingsSection") {
            var providerCalls = 0
            let models = ModelCatalog.options.filter { $0.id == "parakeet-v3" || $0.id == "small-en" }
            for (profiles, expanded) in [([AppProfile](), nil), (sampleProfiles(), sampleProfiles().first?.id)] as [([AppProfile], UUID?)] {
                for locked in [Set<ManagedConfigKey>(), [.language, .autoPaste, .selectedModel]] {
                    let section = AppProfilesSettingsSection(
                        profiles: .constant(profiles),
                        lockedKeys: locked,
                        modelChoices: models,
                        cleanupModelInstalled: false,
                        candidateProvider: { providerCalls += 1; return [] },
                        initiallyExpanded: expanded
                    )
                    .frame(width: 400)
                    .background(Brutal.paper)
                    let snapshot = renderPixelSnapshot(section, width: 420, height: 700)
                    expect(snapshot != nil, "the profiles section renders")
                    expect((snapshot?.opaquePixelCount ?? 0) > 0, "the profiles section draws")
                }
            }
            expectEqual(providerCalls, 0, "rendering never lists running apps")
        }

        test("profiles.render.flowWraps") {
            let chips = BrutalChipFlow(spacing: 4) {
                ForEach(0..<12, id: \.self) { index in
                    Text("CHIP \(index)").padding(4).background(Brutal.card)
                }
            }
            .frame(width: 160)
            expect(renderImage(chips, width: 180, height: 300) != nil, "chips wrap inside a narrow column")
        }

        test("profiles.render.hudAtEveryTextSize") {
            for size in BrutalTextSize.allCases {
                let state = makeUIState(phase: .recording)
                state.config.textSize = size.rawValue
                state.dictationBadge = AppProfileResolver.resolve(
                    base: baseConfig(), bundleID: slackID, lockedKeys: [], isModelInstalled: { _ in true }
                ).badge
                let barSize = BrutalistHUDView.size(vertical: false)
                let listening = renderPixelSnapshot(BrutalistHUDView(state: state), width: barSize.width, height: barSize.height)
                state.phase = .pasted
                let pasted = renderPixelSnapshot(BrutalistHUDView(state: state), width: barSize.width, height: barSize.height)
                expect(listening != nil, "HUD renders at \(size.label)")
                expect(listening?.fingerprint != pasted?.fingerprint, "listening and pasted look different at \(size.label)")
            }
            let idle = makeUIState(phase: .transcribing)
            let window = AlwaysOnHUDView.windowSize(for: idle.config.hudPosition)
            expect(renderImage(AlwaysOnHUDView(state: idle), width: window.width, height: window.height) != nil, "renders without a profile")
        }
    }
}
#endif
