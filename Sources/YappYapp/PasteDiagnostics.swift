import AppKit
import Foundation

enum PasteDiagnostics {
    static func runSmoke() -> Never {
        do {
            let store = ConfigStore()
            try store.prepareApplicationSupport()
            let config = try store.load()
            let injector = ClipboardInjector()
            let excluded = Set([
                Bundle.main.bundleIdentifier,
                "app.yappyapp.YappYapp",
                "ai.genial.yappyapp"  // pre-rename installs
            ].compactMap { $0 })
            let target = injector.captureTarget(excludingBundleIdentifiers: excluded)
            let text = "YappYapp paste smoke \(UUID().uuidString.prefix(8))"
            let outcome = injector.insertOrCopy(text, config: config, target: target)

            print("paste.targetBundle=\(target?.bundleIdentifier ?? "none")")
            print("paste.text=\(text)")
            switch outcome {
            case .pasted:
                print("paste.outcome=pasted")
                exit(0)
            case .pastedBestEffort: // HONEST-PASTE-CONFIRM
                print("paste.outcome=pastedBestEffort")
                exit(0)
            case .copiedOnly(let reason):
                print("paste.outcome=copiedOnly")
                print("paste.reason=\(reason)")
                exit(2)
            case .withheld(let reason): // HONEST-PASTE-CONFIRM: nothing was copied
                print("paste.outcome=withheld")
                print("paste.reason=\(reason)")
                exit(2)
            }
        } catch {
            FileHandle.standardError.write(Data("paste-smoke failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    /// Forces ONLY the synthetic Cmd+V keystroke path against the frontmost app,
    /// to verify keystroke delivery in isolation (the AX path is known to work).
    static func runCommandVSmoke() -> Never {
        do {
            let store = ConfigStore()
            try store.prepareApplicationSupport()
            _ = try store.load()
            let injector = ClipboardInjector()
            let excluded: Set<String> = ["app.yappyapp.YappYapp", "ai.genial.yappyapp"]
            let target = injector.captureTarget(excludingBundleIdentifiers: excluded)
            let text = "YappYapp cmdv smoke \(UUID().uuidString.prefix(8))"
            let posted = injector.diagnosticsKeystrokePaste(text, target: target)
            print("cmdv.targetBundle=\(target?.bundleIdentifier ?? "none")")
            print("cmdv.text=\(text)")
            // HONEST-PASTE-CONFIRM: sendCommandV() refuses to post while the user's
            // modifiers are still held, so posted==false means NO keystroke was
            // delivered. Report it and exit non-zero instead of lying about success.
            print("cmdv.posted=\(posted)")
            guard posted else {
                print("cmdv.reason=modifiersHeld")
                exit(2)
            }
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("cmdv-smoke failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
