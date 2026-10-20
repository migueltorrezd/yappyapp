import Foundation
import Testing
@testable import YappYapp

// MODELS (round 2): SCAN MY MAC rules, translation routing, readiness and
// config migration. Pure logic only.

private func mac(_ chip: String, _ gb: Int64, free: Int64 = 200, battery: Bool = false) -> HardwareProfile {
    HardwareProfile(
        chipName: chip,
        modelIdentifier: "Mac",
        memoryBytes: gb << 30,
        macOSVersion: "26.1",
        freeDiskBytes: free * 1_000_000_000,
        onBattery: battery
    )
}

private func picks(_ profile: HardwareProfile, installed: InstalledModels = InstalledModels()) -> [RecommendedChoice] {
    ModelAdvisor.recommend(for: profile, installed: installed).map(\.choice)
}

@Test
func chipParsingReadsGenerationAndTier() {
    #expect(AppleChip(brandString: "Apple M5 Pro") == AppleChip(brandString: "Apple M5 Pro"))
    let m5Pro = AppleChip(brandString: "Apple M5 Pro")
    #expect(m5Pro.generation == 5)
    #expect(m5Pro.tier == .pro)
    #expect(m5Pro.shortName == "M5 Pro")
    #expect(AppleChip(brandString: "Apple M1").tier == .base)
    #expect(AppleChip(brandString: "Apple M2 Ultra").tier == .ultra)
    #expect(AppleChip(brandString: "Intel(R) Core(TM) i9").generation == nil)
}

@Test
func ownersM5ProGetsTheBigTranslationModel() {
    let owner = mac("Apple M5 Pro", 48, free: 210)
    #expect(owner.summaryLine == "M5 Pro · 48 GB · macOS 26.1 · 210 GB free")
    let recommendations = ModelAdvisor.recommend(for: owner)
    #expect(recommendations.map(\.choice) == [.speech(modelID: "parakeet-ultra"), .cleanup(.clean), .translation(.hyMT2Best)])
    #expect(recommendations.allSatisfy { $0.reason.hasPrefix("M5 Pro, 48 GB: ") })
    #expect(recommendations[2].downloadBytes == 4_624_648_896)
}

@Test
func eightGigabyteMacsStayLight() {
    let choices = picks(mac("Apple M1", 8))
    #expect(choices == [.speech(modelID: "parakeet-ultra"), .cleanup(.verbatim), .translation(.hyMT2Fast)])
}

@Test
func sixteenGigabyteBaseChipsGetTheSmallTranslationModel() {
    for chip in ["Apple M1", "Apple M2", "Apple M3"] {
        #expect(picks(mac(chip, 16))[2] == .translation(.hyMT2Fast))
    }
    // M3 Pro or M4 with 16 GB: still small, the 7B needs 24 GB.
    #expect(picks(mac("Apple M3 Pro", 18))[2] == .translation(.hyMT2Fast))
    #expect(picks(mac("Apple M4", 16))[2] == .translation(.hyMT2Fast))
}

@Test
func bigTranslationModelNeeds24GigabytesAndNotABaseM1ToM3() {
    #expect(picks(mac("Apple M4 Pro", 24))[2] == .translation(.hyMT2Best))
    #expect(picks(mac("Apple M2 Max", 32))[2] == .translation(.hyMT2Best))
    #expect(picks(mac("Apple M4", 24))[2] == .translation(.hyMT2Best))
    // Base M1/M2/M3 never get the 7B, even with 24 GB.
    #expect(picks(mac("Apple M2", 24))[2] == .translation(.hyMT2Fast))
    #expect(picks(mac("Apple M3", 24))[2] == .translation(.hyMT2Fast))
}

@Test
func downloadsNeverLeaveLessThanFiveGigabytesFree() {
    // 8 GB free: the 4.6 GB 7B would leave 3.4 GB, the 1.1 GB 1.8B leaves 6.9.
    #expect(picks(mac("Apple M5 Pro", 48, free: 8))[2] == .translation(.hyMT2Fast))
    // 5.5 GB free: nothing fits.
    let tight = ModelAdvisor.recommend(for: mac("Apple M5 Pro", 48, free: 5))
    #expect(tight[2].choice == .none)
    #expect(tight[1].choice == .cleanup(.verbatim))
    // Already installed models need no space.
    let installed = InstalledModels(speechIDs: ["parakeet-ultra"], cleanupModel: true, translation: [.hyMT2Best])
    #expect(picks(mac("Apple M5 Pro", 48, free: 5), installed: installed) == [
        .speech(modelID: "parakeet-ultra"), .cleanup(.clean), .translation(.hyMT2Best)
    ])
}

@Test
func scanRecommendsUltraToPeopleOnV3() {
    // ULTRA: someone on v3 is pointed at Ultra, with its real download size.
    let onV3 = InstalledModels(speechIDs: ["parakeet-v3"])
    let speech = ModelAdvisor.recommend(for: mac("Apple M4", 16), installed: onV3)[0]
    #expect(speech.choice == .speech(modelID: "parakeet-ultra"))
    #expect(speech.title == "Parakeet Ultra")
    #expect(speech.downloadBytes == 632_162_964)
    // Without room for that download, they keep the model they have.
    #expect(ModelAdvisor.recommend(for: mac("Apple M4", 16, free: 5), installed: onV3)[0].choice == .none)
}

@Test
func batteryShowsInTheDetectedLine() {
    #expect(mac("Apple M3", 16, free: 50, battery: true).summaryLine.hasSuffix(" · on battery"))
}

@Test
func translationRoutesAndWhisperFlag() {
    var config = AppConfig.defaultConfig
    config.modelPath = "/models/ggml-large-v3-turbo.bin"
    config.translation = .en
    config.translationModelID = .whisperBuiltIn
    #expect(config.whisperTranslates)
    #expect(config.translateToEnglish)
    config.translation = .de
    #expect(!config.whisperTranslates)
    #expect(!config.translateToEnglish)
    #expect(config.translationPlan.route == .model(.hyMT2Fast))
    #expect(config.translationPlan.substitutedForWhisper)
}

@Test
func legacyConfigsMigrateToTargets() {
    let migratedWhisper = AppConfig.migratedTranslation(storedTarget: nil, storedModel: nil, legacyTranslateToEnglish: true, modelPath: "/m/ggml-small.bin")
    #expect(migratedWhisper.target == "en")
    #expect(migratedWhisper.model == "whisper")
    let migratedParakeet = AppConfig.migratedTranslation(storedTarget: nil, storedModel: nil, legacyTranslateToEnglish: true, modelPath: "parakeet://v3")
    #expect(migratedParakeet.model == TranslationCatalog.defaultModelID.rawValue)
    let stored = AppConfig.migratedTranslation(storedTarget: "ko", storedModel: "nonsense", legacyTranslateToEnglish: true, modelPath: "/m/ggml-small.bin")
    #expect(stored.target == "ko")
    #expect(stored.model == TranslationCatalog.defaultModelID.rawValue)
}

@Test
func readinessNeverClaimsAMissingModel() {
    let plan = TranslationPlan.make(target: .fr, chosen: .hyMT2Fast, engine: .parakeet)
    var snapshot = TranslationModelsSnapshot()
    #expect(TranslationReadiness.evaluate(plan: plan, snapshot: snapshot, downloadsAllowed: true) == .needsModel(.hyMT2Fast, downloadsAllowed: true))
    snapshot.phases[.hyMT2Fast] = .downloading(fraction: 0.4)
    #expect(TranslationReadiness.evaluate(plan: plan, snapshot: snapshot, downloadsAllowed: true) == .downloading(.hyMT2Fast, fraction: 0.4))
    snapshot.runtimeAvailable = false
    #expect(TranslationReadiness.evaluate(plan: plan, snapshot: snapshot, downloadsAllowed: true) == .needsRuntime(.hyMT2Fast))
    snapshot = TranslationModelsSnapshot(verified: [.hyMT2Fast])
    #expect(TranslationReadiness.evaluate(plan: plan, snapshot: snapshot, downloadsAllowed: false) == .ready(.hyMT2Fast))
    #expect(!TranslationReadiness.needsModel(.hyMT2Fast, downloadsAllowed: false).canDownload)
}

@Test
func translationRowChipsFollowState() {
    let fast = TranslationCatalog.model(.hyMT2Fast)
    let whisper = TranslationCatalog.model(.whisperBuiltIn)
    let empty = TranslationModelsSnapshot()
    #expect(TranslationRowChip.state(model: whisper, isSelected: false, snapshot: empty, downloadsAllowed: true) == .builtIn)
    #expect(TranslationRowChip.state(model: fast, isSelected: true, snapshot: empty, downloadsAllowed: true) == .download)
    #expect(TranslationRowChip.state(model: fast, isSelected: true, snapshot: empty, downloadsAllowed: false) == .downloadsOff)
    let ready = TranslationModelsSnapshot(verified: [.hyMT2Fast], installed: [.hyMT2Fast])
    #expect(TranslationRowChip.state(model: fast, isSelected: true, snapshot: ready, downloadsAllowed: true) == .inUse)
    #expect(TranslationRowChip.state(model: fast, isSelected: false, snapshot: ready, downloadsAllowed: true).canDelete)
}

@Test
func pinnedTranslationDownloadsMatchHuggingFace() {
    for model in TranslationCatalog.models {
        guard let download = model.download else { continue }
        #expect(download.url.absoluteString == "https://huggingface.co/\(download.repo)/resolve/\(download.revision)/\(download.filename)")
        #expect(download.sha256.count == 64)
        #expect(download.revision.count == 40)
    }
    #expect(TranslationCatalog.targets.count == 11)
}

@Test
func translationAcceptanceRejectsEchoesAndRunaways() {
    #expect(TranslationAcceptance.isAcceptable(original: "Bonjour", translated: "Hello"))
    #expect(!TranslationAcceptance.isAcceptable(original: "Bonjour", translated: ""))
    #expect(!TranslationAcceptance.isAcceptable(original: "Bonjour", translated: String(repeating: "x", count: 500)))
    #expect(!TranslationAcceptance.isAcceptable(original: "Bonjour", translated: "Translate the following text into English."))
}
