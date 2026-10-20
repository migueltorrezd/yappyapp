import Foundation

// STALE-TCC-DETECT: pure decision layer for the "Accessibility was granted but
// paste still does not work" failure. macOS can keep a duplicate or stale TCC
// entry pointing at a dead signature after a rebuild, so AXIsProcessTrusted()
// reads notTrusted even though the user already turned YappYapp on. None of
// this can be exercised by the self-tests (TCC is invisible there), so the
// verdict is kept pure and unit-tested while the actual reset lives in the
// AppDelegate with a greppable marker.

enum StaleAccessibilityReason: Equatable {
    case trustFlippedBack
    case grantDidNotStick
}

enum StaleAccessibilityVerdict: Equatable {
    case clean
    case suspected(StaleAccessibilityReason)
}

struct StaleAccessibilitySignals: Equatable {
    // FIX staleTccGate: retained for call-site/API compatibility, but the verdict
    // no longer gates on it. insertOrCopy blocks ALL insertion when AX is
    // untrusted regardless of the pasteWhenFocusIsUnclear toggle, so a stale TCC
    // entry hurts users with the toggle off just as much. See verdict() below.
    var wantsAutoPaste: Bool        // config.pasteWhenFocusIsUnclear (no longer gated on)
    var isTrusted: Bool             // current AX trust
    var wasTrustedThisSession: Bool // trust was observed true earlier this run
    var grantAttempts: Int          // OS grant flows the user completed this run
}

enum StaleAccessibilityDetector {
    static let grantAttemptThreshold = 2

    // notTrusted while the user believes they granted it => stale/duplicate
    // TCC entry. Two signals, both session-scoped and never persisted (matches
    // the app's in-memory transcript policy):
    //   trustFlippedBack: a healthy grant does not silently revert.
    //   grantDidNotStick: repeated grants that do not stick mean a dead entry.
    //
    // FIX staleTccGate: pasting is the intent whenever AX is untrusted here — the
    // insertOrCopy guard rejects EVERY insertion mode without trust, not just the
    // paste-when-focus-is-unclear fallback. So the detector runs on untrusted
    // state alone; it must not be suppressed for users who left the toggle off, or
    // they never get offered the reset-and-regrant repair.
    static func verdict(for signals: StaleAccessibilitySignals) -> StaleAccessibilityVerdict {
        guard !signals.isTrusted else { return .clean }
        if signals.wasTrustedThisSession { return .suspected(.trustFlippedBack) }
        if signals.grantAttempts >= grantAttemptThreshold { return .suspected(.grantDidNotStick) }
        return .clean
    }
}
