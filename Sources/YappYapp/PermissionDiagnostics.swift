import ApplicationServices
import AVFoundation
import Foundation

struct PermissionSnapshot: Equatable {
    let microphone: String
    let accessibility: String
}

enum PermissionDiagnostics {
    static func snapshot() -> PermissionSnapshot {
        PermissionSnapshot(
            microphone: microphoneStatusLabel(AVCaptureDevice.authorizationStatus(for: .audio)),
            accessibility: AXIsProcessTrusted() ? "trusted" : "notTrusted"
        )
    }

    static func printSnapshot() -> Never {
        let snapshot = snapshot()
        print("permission.microphone=\(snapshot.microphone)")
        print("permission.accessibility=\(snapshot.accessibility)")
        exit(0)
    }

    static func microphoneStatusLabel(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized:
            "authorized"
        case .denied:
            "denied"
        case .restricted:
            "restricted"
        case .notDetermined:
            "notDetermined"
        @unknown default:
            "unknown"
        }
    }

    // MIC-LIVE-VERIFY: one tested place that maps an AVAuthorizationStatus to
    // the two booleans the guided microphone step and its repair loop read.
    static func isMicrophoneAuthorized(_ status: AVAuthorizationStatus) -> Bool {
        status == .authorized
    }

    static func isMicrophoneDenied(_ status: AVAuthorizationStatus) -> Bool {
        status == .denied || status == .restricted
    }

    // STALE-TCC-DETECT: prints the pure verdict for QA scripting without
    // touching TCC. It cannot know session history outside the app, so it
    // documents current trust plus the verdict for the "was trusted earlier"
    // synthetic case (the exact silent-revert failure this guards against).
    static func printStaleVerdict() -> Never {
        let trusted = AXIsProcessTrusted()
        print("permission.accessibility=\(trusted ? "trusted" : "notTrusted")")
        let verdict = StaleAccessibilityDetector.verdict(
            for: StaleAccessibilitySignals(
                wantsAutoPaste: true,
                isTrusted: trusted,
                wasTrustedThisSession: true,
                grantAttempts: 0
            )
        )
        print("accessibility.staleVerdictIfPreviouslyTrusted=\(verdict)")
        exit(0)
    }
}
