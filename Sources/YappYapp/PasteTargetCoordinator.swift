import AppKit

/// Tracks the last non-YappYapp application and resolves a fresh focused target
/// at paste time. This keeps activation notifications and stale-target fallback
/// policy out of the application lifecycle owner.
@MainActor
final class PasteTargetCoordinator {
    private let clipboard: ClipboardInjector
    private var activationObserver: NSObjectProtocol?
    private var deactivationObserver: NSObjectProtocol?
    private var lastExternalApplication: NSRunningApplication?
    private var lastExternalPasteTarget: PasteTarget?

    init(clipboard: ClipboardInjector) {
        self.clipboard = clipboard
    }

    func start() {
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let pid = (
                notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            )?.processIdentifier else { return }
            MainActor.assumeIsolated {
                guard let self, let application = NSRunningApplication(processIdentifier: pid) else { return }
                self.remember(application)
            }
        }

        deactivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let pid = (
                notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            )?.processIdentifier else { return }
            MainActor.assumeIsolated {
                guard let self, let application = NSRunningApplication(processIdentifier: pid) else { return }
                // FOCUS-AT-DELIVERY: a deactivation only refreshes the app we
                // already remember. Its notification can arrive AFTER the next
                // app's activation; capturing it then made the app the user
                // just LEFT the fallback target, so a dictation stopped from
                // the indicator went back into the old field.
                guard PasteTargetMemory.deactivationRefreshes(
                    deactivatedPID: pid,
                    rememberedPID: self.lastExternalApplication?.processIdentifier
                ) else { return }
                self.capture(application)
            }
        }

        if let application = NSWorkspace.shared.frontmostApplication {
            remember(application)
        }
    }

    func stop() {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        if let deactivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(deactivationObserver)
        }
        activationObserver = nil
        deactivationObserver = nil
    }

    func captureCurrent(allowFallback: Bool = true) -> PasteTarget? {
        if let target = clipboard.captureTarget(excludingBundleIdentifiers: localBundleIdentifiers) {
            lastExternalApplication = target.application
            lastExternalPasteTarget = target
            return target
        }

        guard allowFallback else { return nil }
        return fallback()
    }

    func fallback() -> PasteTarget? {
        if let application = lastExternalApplication, !application.isTerminated {
            let target = clipboard.captureTarget(
                for: application,
                excludingBundleIdentifiers: localBundleIdentifiers
            ) ?? PasteTarget(
                application: application,
                focusedElement: nil,
                bundleIdentifier: application.bundleIdentifier
            )

            lastExternalPasteTarget = target
            return target
        }

        return lastExternalPasteTarget
    }

    private var localBundleIdentifiers: Set<String> {
        Set([
            Bundle.main.bundleIdentifier,
            "app.yappyapp.YappYapp",
            "ai.genial.yappyapp"
        ].compactMap { $0 })
    }

    private func remember(_ application: NSRunningApplication) {
        guard let bundleIdentifier = application.bundleIdentifier,
              !localBundleIdentifiers.contains(bundleIdentifier) else { return }
        lastExternalApplication = application

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self, weak application] in
            MainActor.assumeIsolated {
                guard let self, let application else { return }
                guard self.lastExternalApplication?.processIdentifier == application.processIdentifier else {
                    return
                }
                self.capture(application)
            }
        }
    }

    private func capture(_ application: NSRunningApplication) {
        guard let bundleIdentifier = application.bundleIdentifier,
              !localBundleIdentifiers.contains(bundleIdentifier) else { return }

        lastExternalApplication = application
        lastExternalPasteTarget = clipboard.captureTarget(
            for: application,
            excludingBundleIdentifiers: localBundleIdentifiers
        ) ?? PasteTarget(
            application: application,
            focusedElement: nil,
            bundleIdentifier: bundleIdentifier
        )
    }
}

/// FOCUS-AT-DELIVERY: pure rules for which app the coordinator remembers.
enum PasteTargetMemory {
    /// A deactivated app refreshes the remembered target only when it IS the
    /// remembered app (or nothing is remembered yet). A late deactivation of
    /// the previous app must never replace the app the user moved to.
    static func deactivationRefreshes(deactivatedPID: pid_t, rememberedPID: pid_t?) -> Bool {
        guard let rememberedPID else { return true }
        return rememberedPID == deactivatedPID
    }
}
