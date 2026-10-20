import Foundation
import Testing
@testable import YappYapp

// Pure logic owned by the "support" track: the mic check meter and the
// sanitized support report.

@Test
func micMeterJudgesWhispersAsTooQuietAndSpeechAsGood() {
    var whisper = MicLevelMeter()
    var speech = MicLevelMeter()
    for _ in 0..<20 {
        whisper.add(decibels: -47)
        speech.add(decibels: -24)
    }
    #expect(whisper.verdict(finished: true) == .tooQuiet)
    #expect(speech.verdict(finished: true) == .good)
}

@Test
func micMeterNeverScoldsBeforeTheCheckEnds() {
    var silent = MicLevelMeter()
    for _ in 0..<30 { silent.add(decibels: -80) }
    #expect(silent.verdict(finished: false) == .listening)
    #expect(silent.verdict(finished: true) == .nothingHeard)
}

@Test
func micMeterMatchesFloatAndInt16Buffers() {
    let floats: [Float] = (0..<800).map { 0.1 * Float(sin(Double($0) * 0.17)) }
    let ints = floats.map { Int16($0 * 32767) }
    let fromFloat = MicLevelMeter.decibels(floatSamples: floats)
    let fromInt = MicLevelMeter.decibels(int16Samples: ints)
    #expect(abs(fromFloat - fromInt) < 0.5)
}

@Test
func tooQuietCopyPointsAtQuietVoiceBoost() {
    let off = MicCheckCopy.make(phase: .finished, verdict: .tooQuiet, quietVoiceBoost: false)
    let on = MicCheckCopy.make(phase: .finished, verdict: .tooQuiet, quietVoiceBoost: true)
    #expect(off.offersBoost)
    #expect(!on.offersBoost)
    #expect(on.detail.contains("Quiet Voice Boost"))
}

@Test
func supportReportRedactsHomeAndOtherUsers() {
    let redacted = SupportReport.redact("/Users/carol/a /Users/dave/b", homeDirectory: "/Users/carol")
    #expect(redacted == "~/a /Users/<user>/b")
    #expect(SupportReport.modelFileLabel("/Users/carol/models/ggml-small.bin") == "ggml-small.bin")
}

@Test
func crashScannerMatchesOnlyYappYappReports() {
    #expect(CrashReportScanner.isYappYappReport(name: "YappYapp-2026-10-12-101112.ips"))
    #expect(CrashReportScanner.isYappYappReport(name: "yappyapp.crash"))
    #expect(!CrashReportScanner.isYappYappReport(name: "Safari-2026-10-12.ips"))
    #expect(!CrashReportScanner.isYappYappReport(name: "YappYapp.log"))
}
