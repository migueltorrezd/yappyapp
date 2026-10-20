import AVFoundation
import Foundation

enum SetupReadinessDiagnostics {
    static func printStatus() {
        do {
            let store = ConfigStore()
            try store.prepareApplicationSupport()
            let config = try store.load()
            configureParakeetDownloads(allowed: config.allowModelDownloads)

            let selectedOption = ModelCatalog.option(for: ModelCatalog.selectedID(for: config.modelPath))
            let readiness = ModelReadinessPresenter.snapshot(
                config: config,
                whisperReadiness: WhisperTranscriber().readiness(for: config),
                selectedModelInstalled: selectedOption?.isInstalled ?? false,
                qwen3RuntimeAvailable: Qwen3ASRRuntime.isAvailable(configuredLlamaBinary: config.llamaBinaryPath)
            )
            let accessibilityTrusted = ClipboardInjector().accessibilityTrusted(promptIfNeeded: false)
            // MIC-LIVE-VERIFY: reading microphone status headless is allowed and
            // does not touch TCC, so the guided flow is observable here.
            let microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            let micAuthorized = PermissionDiagnostics.isMicrophoneAuthorized(microphoneStatus)
            let micDenied = PermissionDiagnostics.isMicrophoneDenied(microphoneStatus)

            let input = SetupReadinessInput(
                isWhisperReady: readiness.isWhisperReady,
                isModelReady: readiness.isModelReady,
                isAccessibilityTrusted: accessibilityTrusted,
                pasteWhenFocusIsUnclear: config.autoPaste,
                allowModelDownloads: config.allowModelDownloads,
                activeDownloadProgress: nil,
                isMicrophoneAuthorized: micAuthorized,
                isMicrophoneDenied: micDenied,
                isGuidedFirstRun: !config.hasCompletedGuidedSetup
            )
            // GUIDED-FIRST-RUN: print the same rows the home card shows so the
            // flow (single numbered step vs full list) is scriptable in QA.
            let rows = SetupReadinessPresenter.guidedRows(for: input)

            print("config.pasteWhenFocusIsUnclear=\(config.pasteWhenFocusIsUnclear)")
            print("config.allowModelDownloads=\(config.allowModelDownloads)")
            print("config.hasCompletedGuidedSetup=\(config.hasCompletedGuidedSetup)")
            print("model.selectedID=\(readiness.selectedModelID)")
            print("model.isWhisperReady=\(readiness.isWhisperReady)")
            print("model.isModelReady=\(readiness.isModelReady)")
            print("permission.accessibility=\(accessibilityTrusted ? "trusted" : "not_trusted")")
            print("permission.microphone=\(PermissionDiagnostics.microphoneStatusLabel(microphoneStatus))")
            print("setup.guidedStepCount=\(SetupReadinessPresenter.guidedStepCount(for: input))")
            print("setup.rowCount=\(rows.count)")
            for row in rows {
                print("setup.row.\(row.id).title=\(row.title)")
                print("setup.row.\(row.id).detail=\(row.detail)")
                if let stepBadge = row.stepBadge {
                    print("setup.row.\(row.id).stepBadge=\(stepBadge)")
                }
            }
        } catch {
            FileHandle.standardError.write(Data("setup-readiness-status failed: \(error)\n".utf8))
            exit(1)
        }
    }
}
