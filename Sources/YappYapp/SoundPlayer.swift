import AppKit
import AVFoundation

final class SoundPlayer {
    private var cachedPlayers: [String: AVAudioPlayer] = [:]

    // Recording cues stay gentle because they fire on every dictation. The
    // chiptune voice is reserved for occasional pet jingles.
    static let startNotes: [(frequency: Double, duration: Double)] = [(523.25, 0.11), (659.25, 0.18)]
    static let stopNotes: [(frequency: Double, duration: Double)] = [(659.25, 0.11), (523.25, 0.18)]

    /// YA-53: how long each recording cue sounds, so the recorder can keep the
    /// start chime out of the WAV and the stop chime out of the warm pre-roll.
    static var startChimeDuration: TimeInterval { startNotes.reduce(0) { $0 + $1.duration } }
    static var stopChimeDuration: TimeInterval { stopNotes.reduce(0) { $0 + $1.duration } }

    func playStart() {
        playSoft(key: "start", notes: Self.startNotes, fallback: ["Pop", "Ping"])
    }

    func playStop() {
        playSoft(key: "stop", notes: Self.stopNotes, fallback: ["Tink", "Bottle", "Submarine"])
    }

    /// Short per-pet melody for level-ups, quest completions, hatches, and
    /// milestones. Synthesized like the Brutal blips, so no audio files.
    func playJingle(forPet pet: String) {
        let melodies: [String: [(Double, Double)]] = [
            "cat": [(659.25, 0.07), (880, 0.11)],
            "dog": [(440, 0.07), (554.37, 0.11)],
            "ghost": [(523.25, 0.09), (392, 0.13)],
            "penguin": [(1174.66, 0.06), (880, 0.10)],
            "fox": [(739.99, 0.07), (987.77, 0.11)],
            "frog": [(329.63, 0.06), (659.25, 0.13)],
            "crab": [(293.66, 0.07), (293.66, 0.08)],
            "robot": [(880, 0.06), (659.25, 0.06), (880, 0.09)],
            "dino": [(196, 0.09), (261.63, 0.13)],
            "duck": [(587.33, 0.06), (493.88, 0.10)],
            "snail": [(261.63, 0.16)],
            "dragon": [(440, 0.07), (554.37, 0.07), (659.25, 0.12)]
        ]

        let notes = melodies[pet] ?? [(659.25, 0.08), (880, 0.11)]
        playChip(key: "jingle-\(pet)", notes: notes, fallback: [])
    }

    private func play(_ names: [String], volume: Float = 0.3) {
        for name in names {
            if let sound = NSSound(named: NSSound.Name(name)) {
                sound.volume = volume
                sound.play()
                return
            }
        }
    }

    private func playSoft(key: String, notes: [(frequency: Double, duration: Double)], fallback: [String]) {
        if let player = cachedPlayers[key] {
            player.currentTime = 0
            player.play()
            return
        }

        let data = Self.softChimeWAV(notes: notes)
        guard let player = try? AVAudioPlayer(data: data) else {
            // The cue is the user's confirmation the shortcut fired; never fail silent.
            play(fallback)
            return
        }
        player.volume = 0.3
        cachedPlayers[key] = player
        player.play()
    }

    private func playChip(key: String, notes: [(frequency: Double, duration: Double)], fallback: [String]) {
        if let player = cachedPlayers[key] {
            player.currentTime = 0
            player.play()
            return
        }

        let data = Self.squareWaveWAV(notes: notes)
        guard let player = try? AVAudioPlayer(data: data) else {
            // The blip is the user's confirmation the shortcut fired; never fail silent.
            play(fallback)
            return
        }
        player.volume = 0.45
        cachedPlayers[key] = player
        player.play()
    }

    /// Soft recording cue: pure sine notes with a slow attack and an
    /// exponential decay tail, so the chime breathes instead of beeping.
    private static func softChimeWAV(notes: [(frequency: Double, duration: Double)]) -> Data {
        let sampleRate = 22_050.0
        var samples: [Double] = []

        for note in notes {
            let count = Int(sampleRate * note.duration)
            let attackSamples = sampleRate * 0.02

            for index in 0..<count {
                let time = Double(index) / sampleRate
                let progress = Double(index) / Double(count)
                let attack = min(1.0, Double(index) / attackSamples)
                let decay = exp(-3.5 * progress)
                let value = sin(2 * .pi * note.frequency * time) * 0.10 * attack * decay
                samples.append(value)
            }
        }

        return wavData(samples: samples, sampleRate: sampleRate)
    }

    /// Synthesizes a tiny square-wave melody as an in-memory WAV: the 8-bit
    /// blips for the pet jingles.
    private static func squareWaveWAV(notes: [(frequency: Double, duration: Double)]) -> Data {
        let sampleRate = 22_050.0
        var samples: [Double] = []

        for note in notes {
            let count = Int(sampleRate * note.duration)
            let period = sampleRate / note.frequency
            let fadeSamples = sampleRate * 0.015

            for index in 0..<count {
                let phase = Double(index).truncatingRemainder(dividingBy: period) / period
                let envelope = min(1.0, Double(count - index) / fadeSamples)
                samples.append((phase < 0.5 ? 1.0 : -1.0) * 0.22 * envelope)
            }
        }

        return wavData(samples: samples, sampleRate: sampleRate)
    }

    private static func wavData(samples doubleSamples: [Double], sampleRate: Double) -> Data {
        let samples = doubleSamples.map { Int16(max(-1, min(1, $0)) * 32767) }

        var data = Data()
        let byteCount = UInt32(samples.count * MemoryLayout<Int16>.size)

        func append32(_ value: UInt32) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }

        func append16(_ value: UInt16) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }

        data.append(contentsOf: Array("RIFF".utf8))
        append32(36 + byteCount)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append32(16)
        append16(1)
        append16(1)
        append32(UInt32(sampleRate))
        append32(UInt32(sampleRate) * 2)
        append16(2)
        append16(16)
        data.append(contentsOf: Array("data".utf8))
        append32(byteCount)
        samples.withUnsafeBytes { data.append(contentsOf: $0) }

        return data
    }
}
