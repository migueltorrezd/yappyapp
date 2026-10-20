import Foundation

enum RecordingDiagnostics {
    static func runSmoke() -> Never {
        let semaphore = DispatchSemaphore(value: 0)
        let exitCode = DiagnosticExitCode()

        Task {
            let recorder = RecordingController()
            do {
                let store = ConfigStore()
                try store.prepareApplicationSupport()
                let config = try store.load()
                let meterFloor: Float = config.quietVoiceBoost ? -55 : -42
                let useSystemDefault = CommandLine.arguments.contains("--system-default-input")
                let inputDeviceUID = useSystemDefault ? nil : config.inputDeviceUID

                try await recorder.start(
                    preferredDeviceUID: inputDeviceUID,
                    meterFloor: meterFloor
                )
                try? await Task.sleep(nanoseconds: 1_200_000_000)

                let peakDecibels = recorder.peakDecibels
                let audioURL = recorder.stop()
                let byteCount = audioURL.flatMap {
                    (try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? NSNumber)?.int64Value
                } ?? 0
                let signalProfile = audioURL.flatMap { AudioNormalizer.signalProfile(url: $0) }
                recorder.cleanup(audioURL)

                print("recording.inputDeviceUID=\(inputDeviceUID ?? "system-default")")
                print("recording.audioCaptured=\(audioURL != nil)")
                print("recording.byteCount=\(byteCount)")
                print(String(format: "recording.peakDecibels=%.1f", peakDecibels))
                print("recording.signalMeaningful=\(signalProfile?.hasMeaningfulSignal == true)")
                if let signalProfile {
                    print(String(format: "recording.referencePeak=%.6f", signalProfile.referencePeak))
                }

                if audioURL == nil || byteCount <= 44 {
                    exitCode.set(2)
                }
            } catch {
                FileHandle.standardError.write(Data("recording-smoke failed: \(error.localizedDescription)\n".utf8))
                exitCode.set(1)
            }

            semaphore.signal()
        }

        semaphore.wait()
        exit(exitCode.value)
    }
}
