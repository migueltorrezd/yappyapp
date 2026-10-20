import AVFoundation
import Foundation

enum TranscriptionDiagnostics {
    static func runSmoke() -> Never {
        let semaphore = DispatchSemaphore(value: 0)
        let exitCode = DiagnosticExitCode()

        Task {
            do {
                let store = ConfigStore()
                try store.prepareApplicationSupport()
                let config = try store.load()
                let glossary = try Glossary.load(from: AppPaths.glossaryURL)
                let audioURL = try makeSpeechFixture()
                defer { try? FileManager.default.removeItem(at: audioURL) }
                guard AudioNormalizer.signalProfile(url: audioURL)?.hasMeaningfulSignal == true else {
                    throw WhisperError.emptyTranscript
                }
                let gain = AudioNormalizer.normalize(url: audioURL)

                let transcript: String
                if ModelCatalog.engine(for: config.modelPath) == .parakeet {
                    let selectedID = ModelCatalog.selectedID(for: config.modelPath)
                    let variant = ModelCatalog.option(for: selectedID)?.parakeetVariant ?? "v3"
                    transcript = try await ParakeetTranscriber().transcribe(audioURL: audioURL, variant: variant)
                } else if let variant = Qwen3ASRVariant.from(modelPath: config.modelPath) {
                    transcript = try await Qwen3ASRTranscriber().transcribe(
                        audioURL: audioURL,
                        variant: variant,
                        config: config,
                        glossary: glossary,
                        audioSeconds: TranscriptionTimeouts.audioDuration(of: audioURL) ?? 0
                    )
                } else {
                    transcript = try await WhisperTranscriber().transcribe(
                        audioURL: audioURL,
                        config: config,
                        glossary: glossary
                    )
                }

                print("transcription.model=\(ModelCatalog.displayName(for: config.modelPath))")
                print(String(format: "transcription.normalizerGain=%.2f", gain))
                print("transcription.text=\(transcript)")
            } catch {
                FileHandle.standardError.write(Data("transcription-smoke failed: \(error.localizedDescription)\n".utf8))
                exitCode.set(1)
            }

            semaphore.signal()
        }

        semaphore.wait()
        exit(exitCode.value)
    }

    private static func makeSpeechFixture() throws -> URL {
        let aiffURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("yappyapp-transcription-\(UUID().uuidString)")
            .appendingPathExtension("aiff")
        let wavURL = aiffURL.deletingPathExtension().appendingPathExtension("wav")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", "Samantha", "-o", aiffURL.path, "hello world from YappYapp"]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw WhisperError.serverFailed("Could not generate speech fixture.")
        }

        let convert = Process()
        convert.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        convert.arguments = ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiffURL.path, wavURL.path]
        try convert.run()
        convert.waitUntilExit()
        guard convert.terminationStatus == 0 else {
            throw WhisperError.serverFailed("Could not convert speech fixture to WAV.")
        }

        try? FileManager.default.removeItem(at: aiffURL)
        return wavURL
    }
}
