import Foundation

struct AudioSignalProfile: Equatable, Sendable {
    static let silenceReferencePeak: Float = 0.0005

    let sampleCount: Int
    let referencePeak: Float

    var hasMeaningfulSignal: Bool {
        sampleCount > 1_600 && referencePeak > Self.silenceReferencePeak
    }
}

/// Loudness normalization for recorded WAVs. Whispered or quiet speech sits
/// 20 to 30 dB below what Whisper models were trained on; amplifying the
/// recording to a healthy peak level dramatically improves recognition.
enum AudioNormalizer {
    private static let headerSize = 44
    private static let maxGain: Float = 40
    private static let targetPeak: Float = 0.9

    private struct PCMRegion {
        let sampleDataOffset: Int
        let sampleCount: Int
    }

    /// Returns the gain that was applied (1 means the file was left untouched).
    @discardableResult
    static func normalize(url: URL) -> Float {
        guard var data = try? Data(contentsOf: url), data.count > headerSize + 2 else { return 1 }

        guard let (profile, region) = signalProfileAndRegion(from: data) else { return 1 }
        guard profile.sampleCount > 1_600 else { return 1 }

        // Essentially silence: amplifying would only raise the noise floor.
        guard profile.hasMeaningfulSignal else { return 1 }

        let gain = min(maxGain, max(1, targetPeak / profile.referencePeak))
        guard gain > 1.05 else { return 1 }

        data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            let samples = base.advanced(by: region.sampleDataOffset).assumingMemoryBound(to: Int16.self)
            for index in 0..<profile.sampleCount {
                let scaled = Float(samples[index]) * gain
                samples[index] = Int16(max(-32768, min(32767, scaled)))
            }
        }

        try? data.write(to: url, options: .atomic)
        return gain
    }

    /// YA-23: `skippingLeadingSamples` excludes the Super Fast Mode pre-roll,
    /// so the silence check judges only what was recorded after the hotkey.
    static func signalProfile(url: URL, skippingLeadingSamples: Int = 0) -> AudioSignalProfile? {
        guard let data = try? Data(contentsOf: url), data.count > headerSize + 2 else { return nil }
        return signalProfileAndRegion(from: data, skippingLeadingSamples: skippingLeadingSamples)?.0
    }

    private static func signalProfileAndRegion(
        from data: Data,
        skippingLeadingSamples: Int = 0
    ) -> (AudioSignalProfile, PCMRegion)? {
        guard let region = pcmRegion(in: data) else { return nil }
        let skip = min(max(0, skippingLeadingSamples), region.sampleCount)
        let sampleCount = region.sampleCount - skip
        guard sampleCount > 0 else { return nil }

        // Reference peak is the 99.7th percentile of sample magnitudes, so a
        // single click or pop cannot make silence look like speech.
        var magnitudes: [Float] = []
        magnitudes.reserveCapacity(sampleCount / 16 + 1)

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            let samples = base.advanced(by: region.sampleDataOffset).assumingMemoryBound(to: Int16.self)
            var index = skip
            while index < region.sampleCount {
                magnitudes.append(abs(Float(samples[index])) / 32768)
                index += 16
            }
        }

        guard !magnitudes.isEmpty else { return nil }
        magnitudes.sort()
        let referenceIndex = min(magnitudes.count - 1, Int(Float(magnitudes.count) * 0.997))
        return (AudioSignalProfile(sampleCount: sampleCount, referencePeak: magnitudes[referenceIndex]), region)
    }

    private static func pcmRegion(in data: Data) -> PCMRegion? {
        guard data.count >= headerSize,
              asciiString(in: data, start: 0, count: 4) == "RIFF",
              asciiString(in: data, start: 8, count: 4) == "WAVE" else {
            return nil
        }

        var cursor = 12
        while cursor + 8 <= data.count {
            let chunkID = asciiString(in: data, start: cursor, count: 4)
            guard let chunkSize = littleEndianUInt32(in: data, at: cursor + 4) else { return nil }

            let chunkStart = cursor + 8
            let chunkByteCount = Int(chunkSize)
            let chunkEnd = chunkStart + chunkByteCount
            guard chunkEnd <= data.count else { return nil }

            if chunkID == "data" {
                return PCMRegion(
                    sampleDataOffset: chunkStart,
                    sampleCount: chunkByteCount / MemoryLayout<Int16>.size
                )
            }

            cursor = chunkEnd + (chunkByteCount % 2)
        }

        return nil
    }

    private static func asciiString(in data: Data, start: Int, count: Int) -> String? {
        guard start >= 0, count >= 0, start + count <= data.count else { return nil }
        return String(data: data[start..<(start + count)], encoding: .ascii)
    }

    private static func littleEndianUInt32(in data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }

        var value: UInt32 = 0
        for byteIndex in 0..<4 {
            value |= UInt32(data[offset + byteIndex]) << UInt32(byteIndex * 8)
        }
        return value
    }
}
