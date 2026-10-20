#if DEBUG
import CryptoKit
import Foundation

// QWEN3-ASR-WARM: developer timing harness behind
// --qwen3asr-latency <llama-completion> <0.6b|1.7b> <language> <wav>...
// The model files must already sit verified (or verifiable) in the models
// folder of the current Application Support base. Each WAV goes through the
// production Qwen3ASRTranscriber, first one-shot (llama-mtmd-cli next to the
// given llama-completion), then through the warm llama-server. Prints
// timings, character counts and a short SHA-256 of each transcript, never the
// text itself.
enum Qwen3ASRLatencyBench {
    static func run(completionBinary: String, variantName: String, language: String, wavs: [String]) -> Never {
        guard let variant = Qwen3ASRVariant(rawValue: variantName) else {
            print("latency.error=unknown variant")
            exit(2)
        }
        guard Qwen3ASRModelStore.isVerified(variant) || Qwen3ASRModelStore.verifyExisting(variant) else {
            print("latency.error=model files missing or not the pinned ones")
            exit(2)
        }
        var config = AppConfig.defaultConfig
        config.modelPath = variant.modelPath
        config.language = language
        let glossary = Glossary(entries: [])

        var oneShot = Qwen3ASRTranscriber()
        oneShot.server = { _, _, _ in .unavailable }
        oneShot.cliBinary = { _ in Qwen3ASRRuntime.cliBinaryPath(forRuntimeBinary: completionBinary) }
        let oneShotHashes = wavs.map { report("oneShot", $0, oneShot, variant, config, glossary, sameAs: nil) }

        let server = LlamaServerController.speech
        let launchedAt = Date()
        server.synchronize(LlamaServerLaunch(
            binary: LlamaServerPolicy.serverBinaryPath(forRuntimeBinary: completionBinary),
            model: Qwen3ASRModelStore.modelURL(variant).path,
            contextTokens: Qwen3ASRPrompt.contextTokens,
            projector: Qwen3ASRModelStore.projectorURL(variant).path
        ))
        server.waitUntilReady()
        print("latency.server.launchToReadyIncludingWarmUp=\(CleanupLatencyBench.milliseconds(since: launchedAt))ms ready=\(server.isReady)")
        // A fallback here would time the one-shot run again: fail loudly.
        var warm = Qwen3ASRTranscriber()
        warm.cliBinary = { _ in nil }
        for (index, wav) in wavs.enumerated() {
            report("server", wav, warm, variant, config, glossary, sameAs: oneShotHashes[index])
        }
        server.stop()
        exit(0)
    }

    @discardableResult
    private static func report(
        _ label: String,
        _ wav: String,
        _ transcriber: Qwen3ASRTranscriber,
        _ variant: Qwen3ASRVariant,
        _ config: AppConfig,
        _ glossary: Glossary,
        sameAs: String?
    ) -> String {
        let url = URL(fileURLWithPath: wav)
        let seconds = TranscriptionTimeouts.audioDuration(of: url) ?? 0
        let startedAt = Date()
        let name = url.deletingPathExtension().lastPathComponent
        do {
            let text = try transcriber.transcribeBlocking(audioURL: url, variant: variant, config: config, glossary: glossary, audioSeconds: seconds)
            let hash = SHA256.hash(data: Data(text.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
            let same = sameAs.map { $0 == hash ? " sameAsOneShot=yes" : " sameAsOneShot=no" } ?? ""
            print("latency.\(label).\(name)=\(CleanupLatencyBench.milliseconds(since: startedAt))ms chars=\(text.count) sha=\(hash)\(same)")
            return hash
        } catch {
            print("latency.\(label).\(name)=\(CleanupLatencyBench.milliseconds(since: startedAt))ms error=\(error)")
            return ""
        }
    }
}
#endif
