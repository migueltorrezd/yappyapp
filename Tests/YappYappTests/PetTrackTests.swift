import Foundation
import Testing
@testable import YappYapp

@Test
func petUnlockProgressGroupsAndClamps() {
    #expect(PetUnlockRequirement.grouped(0) == "0")
    #expect(PetUnlockRequirement.grouped(999) == "999")
    #expect(PetUnlockRequirement.grouped(1_500) == "1,500")
    #expect(PetUnlockRequirement.grouped(1_234_567) == "1,234,567")

    var stats = PetStats()
    stats.starter = PetKind.cat.rawValue
    stats.totalWords = 120
    #expect(PetKind.ghost.unlockRequirement?.progressText(in: stats) == "120/500")
    #expect(PetKind.ghost.unlockRequirementText == "500 words since your first pet")
}

@Test
func petMasterSwitchSilencesCelebrations() {
    #expect(PetGamification.celebrationIntensity(enabled: false, hasEvents: true, wordCount: 200) == 0)
    #expect(PetGamification.overlayPet(enabled: false, active: .dog) == PetKind.none)
    #expect(PetOverlayLayout.bottomReserve(for: .none) == 0)
    #expect(PetOverlayLayout.bottomReserve(for: .dog) > 0)
}

@Test
func petDebugUnlocksIgnoredInReleaseBuilds() {
    let flag = [PetDebugAccess.environmentKey: "true"]
    #expect(!PetDebugAccess.isEnabled(environment: flag, debugBuild: false))
    #expect(PetDebugAccess.isEnabled(environment: flag, debugBuild: true))
}

@Test
func petSignedDayDifferenceGoesNegative() {
    #expect(PetStatsStore.signedDaysBetween("2026-10-16", and: "2026-10-15") == -1)
    #expect(PetStatsStore.signedDaysBetween("bad", and: "2026-10-15") == nil)
}
