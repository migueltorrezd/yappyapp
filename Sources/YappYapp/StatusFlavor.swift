import Foundation

/// Centralized, on-brand rotating copy for the three NON-deterministic,
/// mood-setting status lines. Deterministic setup/permission/error/save copy
/// lives elsewhere and is intentionally NOT routed through here.
///
/// Privacy lines stay factual: the app's whole pitch is "your voice never
/// leaves this Mac", so at least one transcribing line states that plainly
/// and none of the pools ever joke about where audio goes.
enum StatusFlavor {
    /// Shown while the model transcribes locally. Privacy stated as fact.
    static var transcribing: [String] { [
        L10n.tr("Transcribing on this Mac…"),
        L10n.tr("Still on this Mac. Always."),
        L10n.tr("Working it out, locally."),
        L10n.tr("Turning sound into words. No cloud involved."),
        L10n.tr("On it. Your voice stays on this Mac.")
    ] }

    /// Shown when stop produced no audio file at all (mic gave us nothing).
    static var nothingRecorded: [String] { [
        L10n.tr("Heard nothing."),
        L10n.tr("That was just breathing. Try words."),
        L10n.tr("Silence. Bold choice, but I need sound."),
        L10n.tr("Caught air. Say something next time."),
        L10n.tr("Heard nothing. The mic and I are both waiting.")
    ] }

    /// The resting prompt when the app is idle and ready.
    static var idlePrompt: [String] { [
        L10n.tr("Press ⌥ space in any app and start talking."),
        L10n.tr("Press ⌥ space and just talk. I'll type it."),
        L10n.tr("Hit ⌥ space anywhere and start rambling."),
        L10n.tr("Ready when you are. ⌥ space to dictate."),
        L10n.tr("⌥ space, then talk. Your voice stays on this Mac.")
    ] }

    /// Deterministic pick from a pool by index. Empty pools return "" so a
    /// caller bug can never crash; in practice pools are always non-empty.
    static func line(from pool: [String], index: Int) -> String {
        guard !pool.isEmpty else { return "" }
        return pool[((index % pool.count) + pool.count) % pool.count]
    }
}
