import AVFoundation
import Foundation

/// Minimal WAV writer producing a plain 44-byte-header RIFF file that every
/// decoder (including whisper.cpp's miniaudio) reads. AVAudioFile inserts
/// JUNK/FLLR padding chunks and finalizes lazily on dealloc, which proved
/// fragile for short or interrupted recordings.
final class WAVFileWriter {
    let url: URL

    private let handle: FileHandle
    private let sampleRate: UInt32
    private let channels: UInt16
    private let bitsPerSample: UInt16 = 16
    private let lock = NSLock()
    private var dataBytes: UInt32 = 0
    private var isFinalized = false

    init(url: URL, sampleRate: UInt32, channels: UInt16) throws {
        self.url = url
        self.sampleRate = sampleRate
        self.channels = channels

        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Self.header(
            sampleRate: sampleRate,
            channels: channels,
            bitsPerSample: bitsPerSample,
            dataBytes: 0
        ))
    }

    var frameCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return Int(dataBytes) / (Int(channels) * Int(bitsPerSample) / 8)
    }

    /// Appends an interleaved Int16 PCM buffer. Safe to call from the audio
    /// render thread while another thread finalizes.
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }

        guard !isFinalized else { return }
        guard let channelData = buffer.int16ChannelData?[0] else { return }

        let byteCount = Int(buffer.frameLength) * Int(channels) * MemoryLayout<Int16>.size
        guard byteCount > 0 else { return }

        do {
            try handle.write(contentsOf: Data(bytes: channelData, count: byteCount))
            dataBytes += UInt32(byteCount)
        } catch {
            // Disk full or handle closed; finalize still writes a consistent header.
        }
    }

    /// FILE-TRANSCRIPTION: appends raw interleaved little-endian Int16 PCM
    /// bytes, for audio that never was an AVAudioPCMBuffer.
    func append(pcmBytes data: Data) throws {
        lock.lock()
        defer { lock.unlock() }

        guard !isFinalized, !data.isEmpty else { return }
        try handle.write(contentsOf: data)
        dataBytes += UInt32(data.count)
    }

    func finalize() {
        lock.lock()
        defer { lock.unlock() }

        guard !isFinalized else { return }
        isFinalized = true

        do {
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: Self.header(
                sampleRate: sampleRate,
                channels: channels,
                bitsPerSample: bitsPerSample,
                dataBytes: dataBytes
            ))
            try handle.close()
        } catch {
            try? handle.close()
        }
    }

    private static func header(
        sampleRate: UInt32,
        channels: UInt16,
        bitsPerSample: UInt16,
        dataBytes: UInt32
    ) -> Data {
        let bytesPerFrame = UInt32(channels) * UInt32(bitsPerSample) / 8

        var data = Data(capacity: 44)
        data.append(contentsOf: Array("RIFF".utf8))
        data.appendLittleEndian(36 + dataBytes)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(channels)
        data.appendLittleEndian(sampleRate)
        data.appendLittleEndian(sampleRate * bytesPerFrame)
        data.appendLittleEndian(UInt16(bytesPerFrame))
        data.appendLittleEndian(bitsPerSample)
        data.append(contentsOf: Array("data".utf8))
        data.appendLittleEndian(dataBytes)
        return data
    }
}

private extension Data {
    mutating func appendLittleEndian(_ value: UInt32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLittleEndian(_ value: UInt16) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
