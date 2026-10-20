import Foundation
import Testing
@testable import YappYapp

@Test
func readinessPollingBacksOffAfterGuidedSetup() {
    #expect(AppDelegate.readinessPollInterval(hasCompletedGuidedSetup: false) == 2)
    #expect(AppDelegate.readinessPollInterval(hasCompletedGuidedSetup: true) == 60)
}

@Test
func capturePhaseLabelsRemainExplicit() {
    #expect(CapturePhase.idle.label == "Ready")
    #expect(CapturePhase.recording.label == "Listening")
    #expect(CapturePhase.transcribing.label == "Transcribing")
    #expect(CapturePhase.error("fixture").label == "Needs attention")
}

@Test
func staleAccessibilityRequiresEvidence() {
    #expect(StaleAccessibilityDetector.verdict(for: StaleAccessibilitySignals(
        wantsAutoPaste: true,
        isTrusted: false,
        wasTrustedThisSession: false,
        grantAttempts: 0
    )) == .clean)
    #expect(StaleAccessibilityDetector.verdict(for: StaleAccessibilitySignals(
        wantsAutoPaste: true,
        isTrusted: false,
        wasTrustedThisSession: true,
        grantAttempts: 1
    )) != .clean)
}

@Test
func petDebugAccessUnlocksWithoutMutatingPersistedProgress() {
    let persisted = PetStats()
    let presented = PetDebugAccess.presented(persisted, enabled: true)

    #expect(persisted.starter.isEmpty)
    #expect(persisted.wordsByPet.isEmpty)
    #expect(PetKind.allCases.allSatisfy { presented.isUnlocked($0) })
    #expect(PetKind.allCases.filter { $0 != .none }.allSatisfy { !presented.isEggPhase($0) })
    #expect(PetKind.allCases.filter { $0 != .none }.allSatisfy {
        petLevel(forWords: presented.words(for: $0)) >= PetAccessory.halo.unlockLevel
    })
}

@MainActor
@Test
func recordingSessionGenerationRejectsStalePaste() {
    let state = YappYappState()
    let coordinator = RecordingSessionCoordinator(
        state: state,
        recorder: RecordingController()
    )

    let first = coordinator.begin(target: nil)
    let second = coordinator.begin(target: nil)

    #expect(!coordinator.isCurrent(first))
    #expect(coordinator.isCurrent(second))
    #expect(!coordinator.beginPaste(for: first))
    #expect(coordinator.beginPaste(for: second))
    #expect(!coordinator.beginPaste(for: second))
    coordinator.endPaste()
    #expect(!coordinator.isPasteInFlight)
}
