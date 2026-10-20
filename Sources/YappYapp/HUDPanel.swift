import AppKit
import SwiftUI

/// FOCUS-AT-DELIVERY: the always-on indicator's window. A non-activating
/// panel that can never become key or main, so a click on the stop square,
/// KEEP or RETRY never activates YappYapp and never takes the keyboard from
/// the app you are dictating into. Before, a plain window at status-bar
/// level activated YappYapp on any click it caught: Ghostty lost its key
/// window (hollow cursor) and the dictation was routed by a stale target.
final class HUDPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        // A panel hides when its app deactivates by default; YappYapp is
        // almost never the active app, so the indicator must stay.
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Hosting view that acts on the first click: the indicator's window is
/// never key, so without this the first click would only "focus" it.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Pure rules for the indicator window's mouse handling, so tests pin them.
enum HUDMousePolicy {
    /// The window takes the click only when the phase has a button and the
    /// pointer is on the bar itself. Anywhere else (the pet, its headroom,
    /// the transparent margin) the click goes to the app underneath.
    static func takesClicks(phaseAcceptsMouse: Bool, pointer: NSPoint, windowFrame: NSRect, position: HUDPosition) -> Bool {
        guard phaseAcceptsMouse, position != .off else { return false }
        let local = position.interactiveRect(windowSize: windowFrame.size)
            .offsetBy(dx: windowFrame.minX, dy: windowFrame.minY)
        return local.contains(pointer)
    }
}
