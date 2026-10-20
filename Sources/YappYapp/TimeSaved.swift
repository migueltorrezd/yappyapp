import Foundation

// MARKER privacyAndTimeSaved: time-saved helper
/// Deterministic "time saved by dictating instead of typing" math. Pure: no
/// clock, no locale, no I/O. The baseline is intentionally conservative so the
/// claim under-promises rather than over-promises.
enum TimeSavedMath {
    /// Average typing speed in words per minute. Dictation replaces typing, so
    /// words / WPM is the time a typist would have spent for the same words.
    static let baselineTypingWPM = 40

    /// Minutes a typist would have spent for `words`, at `typingWPM`.
    static func minutesSaved(words: Int, typingWPM: Int = baselineTypingWPM) -> Double {
        Double(max(0, words)) / Double(max(1, typingWPM))
    }

    /// Compact label for a stat block: "0m", "12m", "2h", "2h 30m". No locale,
    /// no em dashes.
    static func shortLabel(words: Int, typingWPM: Int = baselineTypingWPM) -> String {
        let totalMinutes = Int(minutesSaved(words: words, typingWPM: typingWPM).rounded())
        if totalMinutes < 60 { return L10n.tr("%@m", "\(totalMinutes)") }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return minutes == 0 ? L10n.tr("%@h", "\(hours)") : L10n.tr("%@h %@m", "\(hours)", "\(minutes)")
    }
}
