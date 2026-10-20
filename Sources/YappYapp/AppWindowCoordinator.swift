import AppKit
import SwiftUI

/// Owns every AppKit window surface so `AppDelegate` can focus on application
/// lifecycle and workflow orchestration. All mutations stay on the main actor,
/// matching AppKit's threading contract.
@MainActor
final class AppWindowCoordinator: NSObject, NSWindowDelegate {
    private let state: YappYappState
    private let rootView: () -> AnyView
    private let onToggleRecording: () -> Void
    private let onWillPresentControls: () -> Void
    private let onUndoCancel: () -> Void
    private let onRetry: () -> Void

    private var popover: NSPopover?
    private var controlWindow: NSWindow?
    private var hudWindows: [NSWindow] = []
    /// FOCUS-AT-DELIVERY: pointer watchers, installed only while the
    /// indicator has a button, so its window takes clicks on the bar alone.
    private var pointerMonitors: [Any] = []
    private var screenObserver: NSObjectProtocol?
    private var displayOptionsObserver: NSObjectProtocol?

    init(
        state: YappYappState,
        rootView: @escaping () -> AnyView,
        onToggleRecording: @escaping () -> Void,
        onWillPresentControls: @escaping () -> Void,
        onUndoCancel: @escaping () -> Void = {},
        onRetry: @escaping () -> Void = {}
    ) {
        self.state = state
        self.rootView = rootView
        self.onToggleRecording = onToggleRecording
        self.onWillPresentControls = onWillPresentControls
        self.onUndoCancel = onUndoCancel
        self.onRetry = onRetry
    }

    /// Missing feature 3: true while the popover or the focused control window
    /// is on screen, so delivery problems are shown there instead of notified.
    var controlsVisible: Bool {
        if popover?.isShown == true { return true }
        guard let controlWindow, controlWindow.isVisible else { return false }
        return NSApp.isActive
    }

    func start() {
        setupPopover()
        observeAccessibilityDisplayOptions()
        rebuildHUDWindows()

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.rebuildHUDWindows()
            }
        }
    }

    func stop() {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        if let displayOptionsObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(displayOptionsObserver)
        }
        screenObserver = nil
        displayOptionsObserver = nil

        removePointerMonitors()
        for window in hudWindows {
            window.orderOut(nil)
        }
        hudWindows.removeAll()
        popover?.performClose(nil)
        controlWindow?.orderOut(nil)
    }

    func togglePopover(anchor button: NSStatusBarButton?, sender: Any?) {
        guard let popover else { return }

        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover(anchor: button)
        }
    }

    func showPopover(anchor button: NSStatusBarButton?) {
        guard let button, let popover, !popover.isShown else { return }

        onWillPresentControls()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.isOpaque = false
        popover.contentViewController?.view.window?.backgroundColor = .clear
        NSApp.activate(ignoringOtherApps: true)
        Self.clearInitialFocus(popover.contentViewController?.view.window)
    }

    func showControlWindow() {
        onWillPresentControls()

        if controlWindow == nil {
            let controller = hostingController(rootView())
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 596),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )

            window.title = "YappYapp"
            window.contentViewController = controller
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.backgroundColor = NSColor(red: 0.96, green: 0.94, blue: 0.88, alpha: 1.0)
            // YA-27: an ordinary window. It no longer floats above every
            // other app or follows into full-screen spaces.
            window.level = .normal
            window.collectionBehavior = [.moveToActiveSpace]
            window.center()
            window.delegate = self
            controlWindow = window
        }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        controlWindow?.makeKeyAndOrderFront(nil)
        controlWindow?.orderFrontRegardless()
        Self.clearInitialFocus(controlWindow)
    }

    /// AppKit hands focus to the first control in the key loop (the MIC tab)
    /// when a window becomes key, which used to draw a blue frame around it.
    /// Nothing is focused on open; Tab still enters the loop when the Mac's
    /// keyboard navigation is on. SwiftUI may assign its default focus on
    /// the next pass, so clear it again then.
    static func clearInitialFocus(_ window: NSWindow?) {
        guard let window else { return }
        window.initialFirstResponder = nil
        window.makeFirstResponder(nil)
        Task { @MainActor in
            if window.firstResponder !== window, !(window.firstResponder is NSText) {
                window.makeFirstResponder(nil)
            }
        }
    }

    func rebuildHUDWindows() {
        for window in hudWindows {
            window.orderOut(nil)
        }
        hudWindows.removeAll()

        let position = HUDPosition(configValue: state.config.hudPosition)
        guard position != .off else { return }
        let size = position.windowSize

        for screen in NSScreen.screens {
            let window = HUDPanel(contentRect: NSRect(origin: .zero, size: size))
            let hosting = FirstMouseHostingView(rootView: AnyView(AlwaysOnHUDView(
                state: state,
                onToggleRecording: onToggleRecording,
                onUndoCancel: onUndoCancel,
                onRetry: onRetry
            )))
            hosting.wantsLayer = true
            hosting.focusRingType = .none
            hosting.layer?.backgroundColor = NSColor.clear.cgColor
            window.contentView = hosting
            window.isOpaque = false
            window.backgroundColor = .clear
            window.level = .statusBar
            window.ignoresMouseEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

            // Bottom/top: centered on that edge. Left/right: the bar centered
            // on that edge, a small inset in from it.
            window.setFrameOrigin(position.windowOrigin(in: screen.visibleFrame))
            window.orderFrontRegardless()
            hudWindows.append(window)
        }
        updateHUDMouseBehavior(for: state.phase)
    }

    /// The indicator takes clicks only on the bar, and only while it has a
    /// button (stop, KEEP, RETRY). Pointer watchers run only then.
    func updateHUDMouseBehavior(for phase: CapturePhase) {
        let accepts = HUDPresenter.acceptsMouse(phase, retryAvailable: state.retryAvailable)
        if accepts, !hudWindows.isEmpty {
            installPointerMonitors()
        } else {
            removePointerMonitors()
        }
        refreshHUDMouse(phaseAccepts: accepts)
    }

    private func refreshHUDMouse(phaseAccepts: Bool? = nil) {
        let accepts = phaseAccepts ?? HUDPresenter.acceptsMouse(state.phase, retryAvailable: state.retryAvailable)
        let position = HUDPosition(configValue: state.config.hudPosition)
        let pointer = NSEvent.mouseLocation
        for window in hudWindows {
            let takes = HUDMousePolicy.takesClicks(
                phaseAcceptsMouse: accepts,
                pointer: pointer,
                windowFrame: window.frame,
                position: position
            )
            if window.ignoresMouseEvents == takes {
                window.ignoresMouseEvents = !takes
            }
        }
    }

    private func installPointerMonitors() {
        guard pointerMonitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        // Moves over other apps (no permission needed for mouse events).
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshHUDMouse() }
        }) {
            pointerMonitors.append(global)
        }
        // Moves while the pointer is over the indicator itself.
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.refreshHUDMouse() }
            return event
        }) {
            pointerMonitors.append(local)
        }
    }

    private func removePointerMonitors() {
        for monitor in pointerMonitors {
            NSEvent.removeMonitor(monitor)
        }
        pointerMonitors.removeAll()
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === controlWindow else { return }

        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let hasOtherRegularWindow = NSApp.windows.contains { window in
                    guard window !== self.controlWindow else { return false }
                    guard !self.hudWindows.contains(window) else { return false }
                    guard window.isVisible else { return false }
                    return window.styleMask.contains(.titled)
                }
                if !hasOtherRegularWindow {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }
    }

    private func setupPopover() {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.contentSize = NSSize(width: 440, height: 596)
        popover.appearance = NSAppearance(named: .aqua)
        popover.contentViewController = hostingController(rootView())
        self.popover = popover
    }

    private func observeAccessibilityDisplayOptions() {
        displayOptionsObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.popover?.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            }
        }
    }

    private func hostingController(_ view: AnyView) -> NSHostingController<AnyView> {
        let controller = NSHostingController(rootView: view)
        controller.view.wantsLayer = true
        // No AppKit focus ring on the hosting view itself.
        controller.view.focusRingType = .none
        controller.view.layer?.backgroundColor = NSColor.clear.cgColor
        return controller
    }
}
