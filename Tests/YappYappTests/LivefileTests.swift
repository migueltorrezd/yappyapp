import Foundation
import Testing
@testable import YappYapp

@Test
func livePreviewTailKeepsNewestWholeWords() {
    let text = "one two three four five six seven eight nine ten eleven twelve thirteen fourteen"
    let tail = LivePreviewText.tail(text, limit: 30)
    #expect(tail.hasPrefix("…"))
    #expect(tail.count <= 30)
    #expect(tail.hasSuffix("fourteen"))
    #expect(LivePreviewText.tail("short", limit: 30) == "short")
}

@Test
func livePreviewSchedulerNeverStacksDecodes() {
    var scheduler = LivePreviewScheduler()
    let window = LivePreviewPolicy.minimumWindowSamples
    #expect(scheduler.decide(totalAppended: 16_000, windowCount: window, inFlight: false) == .run)
    #expect(scheduler.decide(totalAppended: 40_000, windowCount: window, inFlight: true) == .skipInFlight)
    #expect(scheduler.decide(totalAppended: 16_100, windowCount: window, inFlight: false) == .skipNoNewAudio)
    #expect(scheduler.decide(totalAppended: 40_000, windowCount: window, inFlight: false) == .run)
    #expect(scheduler.decide(totalAppended: 40_000, windowCount: 10, inFlight: false) == .skipTooShort)
}

@Test
func livePreviewIsParakeetOnlyAndOptIn() {
    var config = AppConfig.defaultConfig
    #expect(!LivePreviewPolicy.isEligible(config: config))
    config.livePreview = true
    #expect(LivePreviewPolicy.isEligible(config: config))
    config.modelPath = "/tmp/ggml-small.bin"
    #expect(!LivePreviewPolicy.isEligible(config: config))
}

@Test
func fileInputAcceptsOnlySupportedLocalFiles() {
    #expect(FileTranscriptionInput.accepts(URL(fileURLWithPath: "/tmp/x.MP3")))
    #expect(FileTranscriptionInput.accepts(URL(fileURLWithPath: "/tmp/x.mov")))
    #expect(!FileTranscriptionInput.accepts(URL(fileURLWithPath: "/tmp/x.docx")))
}

@Test
func chunkerCoversEverySampleOnce() {
    let total = 10 * 60 * 16_000 + 1_234
    let ranges = FileTranscriptionChunker.ranges(totalSamples: total) { range in
        Double(range.lowerBound % 7_919)
    }
    #expect(ranges.first?.lowerBound == 0)
    #expect(ranges.last?.upperBound == total)
    #expect(zip(ranges, ranges.dropFirst()).allSatisfy { $0.upperBound == $1.lowerBound })
    #expect(ranges.allSatisfy { !$0.isEmpty })
    #expect(ranges.count >= 10)
}

@Test
func fileProgressIsMonotonic() {
    let stages: [FileTranscriptionStage] = [
        .converting(0), .converting(0.5), .converting(1),
        .transcribing(done: 0, total: 3), .transcribing(done: 1, total: 3), .transcribing(done: 3, total: 3)
    ]
    let values = stages.compactMap { FileTranscriptionPresenter.progress(for: .running(fileName: "a", stage: $0)) }
    #expect(values.count == stages.count)
    #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
    #expect(values.last == 1)
}
