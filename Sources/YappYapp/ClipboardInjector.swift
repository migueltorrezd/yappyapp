import AppKit
import ApplicationServices
import Carbon
import Foundation

enum PasteOutcome: Equatable {
    // HONEST-PASTE-CONFIRM: .pasted is only returned when the AX value read-back
    // confirms the text actually landed. The synthetic Cmd+V path cannot be
    // verified, so it returns .pastedBestEffort instead of claiming confirmed success.
    case pasted
    case pastedBestEffort
    case copiedOnly(ClipboardPasteBlockReason)
    // HONEST-PASTE-CONFIRM: the secure-input path copies NOTHING — the transcript
    // stays inside YappYapp. Reporting it as .copiedOnly would make --paste-smoke
    // print "copiedOnly" and tell the user the text is on the clipboard when it is
    // not. .withheld means: kept private, nothing was copied.
    case withheld(ClipboardPasteBlockReason)
}

struct PasteTarget {
    let application: NSRunningApplication?
    let focusedElement: AXUIElement?
    let bundleIdentifier: String?
}

enum ClipboardPasteTargetKind: Equatable {
    case native
    case browser
    case terminal
    case webViewApp

    var requiresKeystrokePaste: Bool {
        switch self {
        case .browser, .terminal, .webViewApp:
            return true
        case .native:
            return false
        }
    }
}

enum ClipboardPasteBlockReason: Equatable {
    case accessibilityNotTrusted
    case secureInputActive
    case focusUnclear
    // FIX chordTimeout: the synthetic Cmd+V could not be posted because the
    // user's modifiers (typically Option from the "⌥ space" toggle) were still
    // held. Posting anyway would fire the wrong chord, so we degrade to copy-only.
    case modifiersHeld
    // PIPELINE (YA-17): the auto-paste master switch is off.
    case autoPasteOff
    // PIPELINE (YA-02): a newer dictation became current first.
    case newerDictation
}

enum ClipboardPasteDecision: Equatable {
    // HONEST-PASTE-CONFIRM: .withhold means keep the transcript private and copy
    // NOTHING (secure input). It is distinct from .copyOnly, which stages the
    // transcript on the clipboard for a manual Cmd+V. Keeping these separate lets
    // the pure layer mirror the runtime, where secure input returns .withheld and
    // never touches the shared pasteboard.
    case withhold(ClipboardPasteBlockReason)
    case copyOnly(ClipboardPasteBlockReason)
    case directAccessibility
    case commandV
}

// FIX dupInsert: three-way result of a direct AX value write so the caller can
// tell a silent no-op (safe to fall back to the next candidate / Cmd+V) apart
// from a mutation the field normalized (smart quotes, dashes, whitespace) which
// still means the text landed and MUST NOT be re-inserted.
private enum AXInsertionResult {
    case inserted   // read-back confirms the value grew by exactly the insertion
    case changed    // value changed from our write but was normalized — treat as landed, stop
    case unchanged  // value did not change — the write no-op'd, safe to retry / fall back
}

final class ClipboardInjector: TranscriptDeliveryBackend {
    /// YA-20: a hung target app must not freeze YappYapp for the default ~6s
    /// AX timeout. Every element we message gets this bound.
    static let axMessagingTimeout: Float = 0.35

    @discardableResult
    static func boundingTimeout(_ element: AXUIElement) -> AXUIElement {
        AXUIElementSetMessagingTimeout(element, axMessagingTimeout)
        return element
    }

    /// Terminals expose the whole screen as an AX text area, so a direct value
    /// write can report success without reaching the shell. Cmd+V is the only
    /// insertion that behaves correctly there.
    private static let terminalBundleIdentifiers: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
        "io.alacritty",
        "org.alacritty"
    ]

    /// Browsers accept AX value writes and even paint them, but the page's
    /// JavaScript state never sees the text (LinkedIn, Gmail, Notion drafts
    /// stay empty under the painted overlay). Only a real Cmd+V goes through
    /// the page's paste handling.
    private static let browserBundleIdentifiers: Set<String> = [
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.google.Chrome.canary",
        "org.chromium.Chromium",
        "org.mozilla.firefox",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "company.thebrowser.Browser",
        "company.thebrowser.dia",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera"
    ]

    /// Electron and WebView-based apps often accept or paint AX value writes
    /// without notifying the editor state. A real paste event is more reliable.
    private static let webViewAppBundleIdentifiers: Set<String> = [
        // FIX(electronDoubleInsert): Chromium applies AXSetValue ASYNCHRONOUSLY
        // and its contenteditable AXValue can include the placeholder text, so
        // AX insertion into these apps double-pastes and smears placeholder
        // text into the field. This list is a fast path only — unknown Electron
        // apps are caught at runtime by isWebContent(_:) on the focused element.
        "com.anthropic.claudefordesktop",
        "com.hnc.Discord",
        "com.microsoft.teams",
        "com.microsoft.teams2",
        "com.microsoft.VSCode",
        "com.tinyspeck.slackmacgap",
        "com.todesktop.230313mzl4w4u92",
        "net.whatsapp.WhatsApp",
        "notion.id"
    ]

    /// FIX(electronDoubleInsert): runtime web-content detection, because a
    /// bundle-id list can never be complete. Chromium and WebKit text fields
    /// expose DOM-backed AX attributes (AXDOMClassList/AXDOMIdentifier) and sit
    /// under an AXWebArea ancestor; native AppKit fields have neither. Any
    /// candidate that looks like web content must go through the real Cmd+V
    /// paste path instead of AX value writes.
    private static func isWebContent(_ element: AXUIElement) -> Bool {
        var namesRef: CFArray?
        if AXUIElementCopyAttributeNames(element, &namesRef) == .success,
           let names = namesRef as? [String],
           names.contains("AXDOMClassList") || names.contains("AXDOMIdentifier") {
            return true
        }

        var current = element
        for _ in 0..<6 {
            var roleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(current, kAXRoleAttribute as CFString, &roleRef) == .success,
               let role = roleRef as? String, role == "AXWebArea" {
                return true
            }
            var parentRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parentRef) == .success,
                  let parent = parentRef, CFGetTypeID(parent) == AXUIElementGetTypeID() else {
                return false
            }
            current = Self.boundingTimeout(parent as! AXUIElement)
        }
        return false
    }

    static func targetKind(for bundleIdentifier: String?) -> ClipboardPasteTargetKind {
        guard let bundleIdentifier else { return .native }

        if terminalBundleIdentifiers.contains(bundleIdentifier) {
            return .terminal
        }

        if browserBundleIdentifiers.contains(bundleIdentifier) {
            return .browser
        }

        if webViewAppBundleIdentifiers.contains(bundleIdentifier) {
            return .webViewApp
        }

        return .native
    }

    static func pasteDecision(
        accessibilityTrusted: Bool,
        secureInputActive: Bool,
        targetKind: ClipboardPasteTargetKind,
        directAccessibilitySucceeded: Bool,
        foundEditableField: Bool,
        pasteWhenFocusIsUnclear: Bool
    ) -> ClipboardPasteDecision {
        guard accessibilityTrusted else {
            return .copyOnly(.accessibilityNotTrusted)
        }

        // HONEST-PASTE-CONFIRM: secure input must NEVER copy — the transcript stays
        // inside YappYapp. The runtime short-circuits to .withheld before this pure
        // layer is consulted (insertOrCopy passes secureInputActive:false here), so
        // this branch encodes the same contract for any caller that does pass true.
        guard !secureInputActive else {
            return .withhold(.secureInputActive)
        }

        if targetKind.requiresKeystrokePaste {
            return .commandV
        }

        if directAccessibilitySucceeded {
            return .directAccessibility
        }

        if foundEditableField || pasteWhenFocusIsUnclear {
            return .commandV
        }

        return .copyOnly(.focusUnclear)
    }

    /// Pure rule for whether a clipboard restore should be scheduled after a
    /// paste attempt. A restore is only scheduled when the transcript was
    /// actually inserted somewhere (.pasted or .pastedBestEffort). The clipboard
    /// always comes back after a paste (no setting since 0.4.0). For copy-only / withheld outcomes the clipboard copy
    /// IS the deliverable (the UI tells the user to press Cmd+V), so we must
    /// never yank it back out from under them — this predicate returns false for
    /// those, encoding finding 2's "copy-only never restores" contract.
    static func shouldRestoreClipboard(after outcome: PasteOutcome) -> Bool {
        switch outcome {
        case .pasted, .pastedBestEffort:
            return true
        case .copiedOnly, .withheld:
            return false
        }
    }

    /// Pure guard for the deferred restore: the clipboard is only safe to
    /// overwrite when its changeCount still matches the value produced by OUR
    /// own write. Any other value means the user (or another process) copied
    /// something in the restore window, and clobbering it would destroy their
    /// clipboard. FIX clipDestroy.
    static func clipboardRestoreIsSafe(currentChangeCount: Int,
                                       expectedChangeCount: Int) -> Bool {
        currentChangeCount == expectedChangeCount
    }

    static func axElement(fromAccessibilityValue value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    static func selectedTextRange(fromAccessibilityValue value: CFTypeRef?, fallbackLocation: Int) -> CFRange {
        var selectedRange = CFRange(location: max(fallbackLocation, 0), length: 0)

        guard let value = axValue(fromAccessibilityValue: value),
              AXValueGetType(value) == .cfRange else {
            return selectedRange
        }

        AXValueGetValue(value, .cfRange, &selectedRange)
        return selectedRange
    }

    private static func axValue(fromAccessibilityValue value: CFTypeRef?) -> AXValue? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXValue.self)
    }

    func accessibilityTrusted(promptIfNeeded: Bool) -> Bool {
        let options = [
            "AXTrustedCheckOptionPrompt": promptIfNeeded
        ] as CFDictionary

        return AXIsProcessTrustedWithOptions(options)
    }

    func captureTarget(excludingBundleIdentifiers excludedBundleIdentifiers: Set<String>) -> PasteTarget? {
        guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
        return captureTarget(for: application, excludingBundleIdentifiers: excludedBundleIdentifiers)
    }

    func captureTarget(
        for application: NSRunningApplication,
        excludingBundleIdentifiers excludedBundleIdentifiers: Set<String>
    ) -> PasteTarget? {
        let bundleIdentifier = application.bundleIdentifier
        if let bundleIdentifier, excludedBundleIdentifiers.contains(bundleIdentifier) {
            return nil
        }

        return PasteTarget(
            application: application,
            focusedElement: focusedElement(in: application),
            bundleIdentifier: bundleIdentifier
        )
    }

    /// YA-15: true when the last insertOrCopy scheduled a clipboard restore.
    private(set) var lastPasteRestoresClipboard = false

    /// DELIVERY-TRAIL: what the last insertOrCopy did, without the text.
    private(set) var lastDeliveryAttempt: DeliveryAttempt?

    /// COMMANDS: how the last dictation went in, for undo. Copy-only and
    /// withheld outcomes clear it: nothing was typed.
    private(set) var lastInsertion: InsertionRecord?
    private var lastAccessibilityWrite: (location: Int, text: String)?

    func forgetLastInsertion() {
        lastInsertion = nil
    }

    func insertOrCopy(_ text: String, config: AppConfig, target: PasteTarget? = nil) -> PasteOutcome {
        lastPasteRestoresClipboard = false
        lastInsertion = nil
        lastDeliveryAttempt = DeliveryAttempt(decision: "none", activation: .none, frontmostMatchedTarget: nil, restoresClipboard: false)

        // YA-17: the auto-paste master switch. Off means nothing is typed into
        // any app, browsers and terminals included; the clipboard is the
        // deliverable. Secure input still keeps the transcript private.
        guard config.autoPaste else {
            guard !IsSecureEventInputEnabled() else {
                lastDeliveryAttempt?.decision = "withhold(secureInput)"
                return .withheld(.secureInputActive)
            }
            lastDeliveryAttempt?.decision = "copyOnly(autoPasteOff)"
            return copyOnly(text, reason: .autoPasteOff)
        }

        // Decide BEFORE writing to the public pasteboard. In a secure context
        // the transcript must never touch the shared clipboard.
        guard accessibilityTrusted(promptIfNeeded: false) else {
            lastDeliveryAttempt?.decision = "copyOnly(accessibilityNotTrusted)"
            return copyOnly(text, reason: .accessibilityNotTrusted)
        }

        // Never type into password or other secure fields. Terminals with
        // Secure Keyboard Entry enabled also trigger this. Do NOT copy: the
        // secret stays inside YappYapp and the user's clipboard is untouched.
        guard !IsSecureEventInputEnabled() else {
            // HONEST-PASTE-CONFIRM: nothing was copied, so report .withheld, not
            // .copiedOnly (which would falsely claim the clipboard holds the text).
            lastDeliveryAttempt?.decision = "withhold(secureInput)"
            return .withheld(.secureInputActive)
        }

        // YA-14: the clipboard is staged only after AX insertion fails (below),
        // so a direct insert never touches the pasteboard at all.
        lastDeliveryAttempt?.activation = activate(target)
        // FOCUS-AT-DELIVERY: what the paste is about to meet, for the trail.
        lastDeliveryAttempt?.focus = focusReport(targetPID: target?.application?.processIdentifier)

        let targetKind = Self.targetKind(for: target?.bundleIdentifier)
        let needsKeystrokePaste = targetKind.requiresKeystrokePaste

        // Try direct accessibility insertion first: it preserves the cursor and
        // works without keyboard simulation. Terminals, browsers, and
        // Electron/WebView apps are excluded: they need a real Cmd+V.
        //
        // FOCUS-AT-DELIVERY: only elements read NOW, after activation, are
        // candidates. The element captured at the stop (or by the activation
        // observer) is never written into: the user may have clicked another
        // field since, and the text must land where the cursor is, not in a
        // field they left (DeliveryFocusPolicy.admits).
        let targetPID = target?.application?.processIdentifier
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var candidates: [AXUIElement] = []
        if !needsKeystrokePaste {
            if let application = target?.application, !application.isTerminated,
               let fresh = focusedElement(in: application),
               DeliveryFocusPolicy.admits(.targetFocused, elementPID: Self.pid(of: fresh), targetPID: targetPID, ownPID: ownPID) {
                candidates.append(fresh)
            }
            if let fresh = focusedElement(),
               DeliveryFocusPolicy.admits(.systemFocused, elementPID: Self.pid(of: fresh), targetPID: targetPID, ownPID: ownPID) {
                candidates.append(fresh)
            }
        }

        // FIX dupInsert: the candidate list routinely holds the SAME element two
        // or three times (captured + re-resolved). Dedupe by identity so a
        // normalized-but-successful write is never retried on a twin, which would
        // append a second (and via the Cmd+V fallback, a third) copy of the text.
        var uniqueCandidates: [AXUIElement] = []
        for candidate in candidates where !uniqueCandidates.contains(where: { CFEqual($0, candidate) }) {
            uniqueCandidates.append(candidate)
        }

        // FIX(electronDoubleInsert): a web-content field from an app that isn't
        // on the bundle-id list (e.g. a new Electron app) must never receive an
        // AX value write — Chromium applies it asynchronously (the read-back
        // confirm lies, causing double insertion) and can embed placeholder
        // text in AXValue. Route those through the Cmd+V path below; keep them
        // in the editability check so pasteDecision still sees a real field.
        let axWritableCandidates = uniqueCandidates.filter { !Self.isWebContent($0) }

        // FIX dupInsert: stop on the first element that actually MUTATED, whether
        // the read-back matched exactly (.inserted) or the field normalized the
        // text (.changed). Only a true no-op (.unchanged) advances to the next
        // candidate / the Cmd+V fallback.
        var landedViaAccessibility = false
        for element in axWritableCandidates {
            lastAccessibilityWrite = nil
            switch insertUsingAccessibility(text, into: element) {
            case .inserted, .changed:
                landedViaAccessibility = true
                lastInsertion = InsertionRecord(
                    method: lastAccessibilityWrite.map { .accessibility(location: $0.location, text: $0.text) }
                        ?? .accessibilityNormalized,
                    processIdentifier: target?.application?.processIdentifier
                        ?? NSWorkspace.shared.frontmostApplication?.processIdentifier,
                    applicationName: target?.application?.localizedName,
                    element: element,
                    date: Date()
                )
            case .unchanged:
                continue
            }
            break
        }

        if landedViaAccessibility {
            // Nothing was staged, so there is nothing to restore.
            lastDeliveryAttempt?.decision = "accessibility"
            return .pasted
        }

        // FIX clipDestroy: snapshot the WHOLE pasteboard (every item, every type),
        // not just a plain string. Capturing only .string wipes an image/file the
        // user had copied when we restore.
        //
        // PERF pasteLatency: materializing every pasteboard flavor's data on the
        // main thread happens only here, once a paste is about to be staged.
        // YA-62: captureClipboard() returns nil for a concealed/transient item.
        let previousClipboard: ClipboardSnapshot? = captureClipboard()

        // Safe to stage the transcript for paste / manual Cmd+V. YA-14: marked
        // transient and current-host-only so clipboard managers and Universal
        // Clipboard skip it.
        // FIX clipDestroy: remember the changeCount produced by OUR write so a
        // scheduled restore can bail out if the user copies anything afterwards.
        let ourChangeCount = copy(text, purpose: .pasteStaging)

        // Web views and Electron apps reject AX value writes; Cmd+V works there
        // because the transcript is already on the clipboard.
        let foundEditableField = uniqueCandidates.contains(where: isEditable)
        let decision = Self.pasteDecision(
            accessibilityTrusted: true,
            secureInputActive: false,
            targetKind: targetKind,
            directAccessibilitySucceeded: false,
            foundEditableField: foundEditableField,
            pasteWhenFocusIsUnclear: config.pasteWhenFocusIsUnclear
        )

        switch decision {
        case .directAccessibility:
            // HONEST-PASTE-CONFIRM: unreachable here (we always pass
            // directAccessibilitySucceeded:false, and every real AX success already
            // returned .pasted above via the verified read-back). Reaching this
            // point means NO write was confirmed, so we must not claim .pasted.
            // Fall through to the honest best-effort keystroke path instead.
            fallthrough
        case .commandV:
            // HONEST-PASTE-CONFIRM: there is no reliable post-check for a synthetic
            // Cmd+V (no AX read-back applies for browsers/terminals/webviews), so we
            // do NOT claim confirmed success. Surface a best-effort outcome instead.
            //
            // FIX chordTimeout: sendCommandV returns false when it refused to post
            // because the user's modifiers were still held. Firing anyway would send
            // Cmd+Opt+V into exactly the Chromium/Electron apps this path targets, so
            // degrade to an honest copy-only outcome (the transcript is on the
            // clipboard for a manual Cmd+V).
            guard sendCommandV() else {
                lastDeliveryAttempt?.decision = "commandVRefused(modifiersHeld)"
                return copyOnly(text, reason: .modifiersHeld)
            }
            lastDeliveryAttempt?.decision = "commandV"

            if Self.shouldRestoreClipboard(after: .pastedBestEffort),
               let previousClipboard {
                restore(previousClipboard, ifChangeCountStillMatches: ourChangeCount, after: 4.0)
                // YA-15: the status must not say "press Cmd+V" when the old
                // clipboard comes back in 4s.
                lastPasteRestoresClipboard = true
            }

            let pasted = NSWorkspace.shared.frontmostApplication
            lastDeliveryAttempt?.restoresClipboard = lastPasteRestoresClipboard
            if let targetPID = target?.application?.processIdentifier {
                lastDeliveryAttempt?.frontmostMatchedTarget = pasted?.processIdentifier == targetPID
            }
            lastInsertion = InsertionRecord(
                method: .keystroke,
                processIdentifier: pasted?.processIdentifier,
                applicationName: pasted?.localizedName,
                element: nil,
                date: Date()
            )
            return .pastedBestEffort
        case .copyOnly(let reason):
            lastDeliveryAttempt?.decision = "copyOnly(\(DeliveryTrail.reasonLabel(reason)))"
            return copyOnly(text, reason: reason)
        case .withhold(let reason):
            lastDeliveryAttempt?.decision = "withhold(\(DeliveryTrail.reasonLabel(reason)))"
            // HONEST-PASTE-CONFIRM: unreachable from this call site (we pass
            // secureInputActive:false), but if the pure layer ever asks to withhold
            // we must keep the transcript private and copy NOTHING — mirror the
            // early secure-input return at the top of insertOrCopy.
            return .withheld(reason)
        }
    }

    /// Leaves the transcript on the clipboard for a manual Cmd+V. The copy IS the
    /// deliverable here, so we deliberately do NOT schedule a clipboard restore:
    /// the UI tells the user to press Cmd+V, and yanking the transcript back out
    /// from under them would contradict that. Never called for .secureInputActive
    /// (that outcome must not copy at all).
    private func copyOnly(_ text: String, reason: ClipboardPasteBlockReason) -> PasteOutcome {
        copy(text, purpose: .copyOnlyDelivery)
        return .copiedOnly(reason)
    }

    /// Writes a transcript to the general pasteboard with the purpose's
    /// privacy markers (YA-14). Returns the changeCount after the write.
    @discardableResult
    func copy(_ text: String, purpose: PasteboardWritePurpose = .userCopy) -> Int {
        PasteboardPrivacy.write(text, to: NSPasteboard.general, purpose: purpose)
    }

    /// Diagnostics only: stage `text` and paste it using ONLY the synthetic
    /// Cmd+V keystroke path (skipping AX insertion), to verify keystroke
    /// delivery in isolation. Not used by the normal dictation flow.
    ///
    /// HONEST-PASTE-CONFIRM: returns sendCommandV()'s result so the smoke test can
    /// report honestly. false means the synthetic Cmd+V was NOT posted (the user's
    /// modifiers were still held), so the smoke must not print success or exit 0.
    @discardableResult
    func diagnosticsKeystrokePaste(_ text: String, target: PasteTarget?) -> Bool {
        copy(text, purpose: .pasteStaging)
        activate(target)
        return sendCommandV()
    }

    private func isEditable(_ element: AXUIElement) -> Bool {
        var roleValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success,
           let role = roleValue as? String {
            let editableRoles: Set<String> = [
                "AXTextArea",
                "AXTextField",
                "AXSearchField",
                "AXComboBox",
                "AXWebArea"
            ]

            if editableRoles.contains(role) {
                return true
            }
        }

        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success {
            return settable.boolValue
        }

        return false
    }

    private func focusedElement() -> AXUIElement? {
        let systemWide = Self.boundingTimeout(AXUIElementCreateSystemWide())
        var focusedValue: CFTypeRef?

        let focusResult = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )

        guard focusResult == .success, let focusedValue else { return nil }
        return Self.axElement(fromAccessibilityValue: focusedValue).map(Self.boundingTimeout)
    }

    private func focusedElement(in application: NSRunningApplication) -> AXUIElement? {
        let applicationElement = Self.boundingTimeout(AXUIElementCreateApplication(application.processIdentifier))
        var focusedValue: CFTypeRef?

        let focusResult = AXUIElementCopyAttributeValue(
            applicationElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )

        guard focusResult == .success, let focusedValue else { return nil }
        return Self.axElement(fromAccessibilityValue: focusedValue).map(Self.boundingTimeout)
    }

    private func insertUsingAccessibility(_ text: String, into element: AXUIElement) -> AXInsertionResult {
        AXUIElementSetAttributeValue(
            element,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        )

        var valueRef: CFTypeRef?
        let valueResult = AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &valueRef
        )

        guard valueResult == .success, let currentValue = valueRef as? String else {
            return .unchanged
        }

        var selectedRangeRef: CFTypeRef?

        if AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &selectedRangeRef
        ) != .success {
            selectedRangeRef = nil
        }

        let selectedRange = Self.selectedTextRange(
            fromAccessibilityValue: selectedRangeRef,
            fallbackLocation: currentValue.utf16.count
        )

        guard selectedRange.location >= 0 else { return .unchanged }

        let nsValue = currentValue as NSString
        let safeLocation = min(selectedRange.location, nsValue.length)
        let safeLength = min(max(selectedRange.length, 0), nsValue.length - safeLocation)
        let replacementRange = NSRange(location: safeLocation, length: safeLength)

        // Smart spacing: avoid gluing the transcript onto surrounding text.
        var insertion = text

        if safeLocation > 0, let scalar = Unicode.Scalar(nsValue.character(at: safeLocation - 1)) {
            let beforeChar = Character(scalar)
            let glueStarters: Set<Character> = ["(", "[", "{", "\"", "'", "«", "‘", "“", "/", "-"]
            // COMMANDS: a transcript that opens with a line break needs no space.
            let startsWithPunctuation = insertion.first.map { ",.!?;:)]}".contains($0) || $0.isNewline } ?? false

            if !beforeChar.isWhitespace, !glueStarters.contains(beforeChar), !startsWithPunctuation {
                insertion = " " + insertion
            }
        }

        let afterLocation = safeLocation + safeLength
        if afterLocation < nsValue.length, let scalar = Unicode.Scalar(nsValue.character(at: afterLocation)) {
            let afterChar = Character(scalar)
            if afterChar.isLetter || afterChar.isNumber, let last = insertion.last, !last.isWhitespace {
                insertion += " "
            }
        }

        let newValue = nsValue.replacingCharacters(in: replacementRange, with: insertion)

        let setResult = AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            newValue as CFTypeRef
        )

        guard setResult == .success else { return .unchanged }

        // HONEST-PASTE-CONFIRM + FIX dupInsert: read the value back and classify
        // the outcome three ways. A .success set result does not prove the field
        // changed (some AX-quirky fields no-op silently), so without this check we
        // would claim a confirmed paste that never happened.
        // FIX(electronDoubleInsert): some editors apply AX writes a beat later,
        // so a single immediate read-back can see the OLD value and misclassify
        // a landed write as .unchanged — the caller then retries on a twin and
        // the text appears twice. Poll briefly before declaring a no-op; the
        // extra wait only happens in the rare genuinely-unchanged case.
        var confirmedValue: String?
        for attempt in 0..<4 {
            if attempt > 0 { usleep(60_000) }
            var confirmRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &confirmRef) == .success,
                  let read = confirmRef as? String else {
                // Cannot read back — assume nothing landed so the caller can fall back.
                return .unchanged
            }
            confirmedValue = read
            if read != currentValue { break }
        }

        // The field did not move at all across the poll: the write no-op'd.
        // Safe to retry / fall back.
        guard let confirmedValue, confirmedValue != currentValue else { return .unchanged }

        let expectedLength = nsValue.length + (insertion as NSString).length
        let exactMatch = (confirmedValue as NSString).length == expectedLength
            && confirmedValue.contains(insertion)

        // Either way the value CHANGED because of our write, so the text landed and
        // must not be re-inserted. Only update the caret when we can trust the
        // offsets (exact match); a normalized field would make them wrong.
        guard exactMatch else { return .changed }
        lastAccessibilityWrite = (location: safeLocation, text: insertion)

        var newRange = CFRange(location: safeLocation + insertion.utf16.count, length: 0)
        if let newRangeValue = AXValueCreate(.cfRange, &newRange) {
            AXUIElementSetAttributeValue(
                element,
                kAXSelectedTextRangeAttribute as CFString,
                newRangeValue
            )
        }

        return .inserted
    }

    /// Brings the target forward before the paste.
    ///
    /// FOCUS-AT-DELIVERY: "already in front" means the target is frontmost,
    /// owns the keyboard (system-wide AXFocusedApplication) and no YappYapp
    /// window is active or key (DeliveryFocusPolicy). Only then is it left
    /// alone, because re-activating an app that really is in front can
    /// reshuffle native tabs (Ghostty with `macos-titlebar-style = tabs`).
    /// An app that is frontmost but lost its key window gets its focused
    /// window raised, so Ghostty's surface takes the Cmd+V again.
    @discardableResult
    private func activate(_ target: PasteTarget?) -> DeliveryActivation {
        guard let application = target?.application else { return .none }
        guard !application.isTerminated else { return .none }
        let pid = application.processIdentifier
        let before = focusFacts(targetPID: pid)
        guard DeliveryFocusPolicy.needsActivation(before) else {
            return .alreadyFrontmost
        }

        let applicationElement = Self.boundingTimeout(AXUIElementCreateApplication(pid))
        AXUIElementSetAttributeValue(
            applicationElement,
            kAXFrontmostAttribute as CFString,
            kCFBooleanTrue
        )
        application.activate(options: [])
        if before.frontmostPID == pid {
            // Frontmost but not holding the keyboard: activate() alone is a
            // no-op for an app macOS already lists in front.
            raiseFocusedWindow(of: applicationElement)
        }

        let deadline = Date().addingTimeInterval(0.9)
        while Date() < deadline {
            if DeliveryFocusPolicy.isReady(focusFacts(targetPID: pid)) {
                break
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.03))
        }

        usleep(180_000)
        return DeliveryFocusPolicy.isReady(focusFacts(targetPID: pid))
            ? .activated
            : .notFrontmost
    }

    /// Makes the app's focused (else main) window its key window again.
    private func raiseFocusedWindow(of applicationElement: AXUIElement) {
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var windowRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(applicationElement, attribute as CFString, &windowRef) == .success,
                  let window = Self.axElement(fromAccessibilityValue: windowRef).map(Self.boundingTimeout) else { continue }
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            return
        }
    }

    // MARK: - FOCUS-AT-DELIVERY facts

    static func pid(of element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid > 0 else { return nil }
        return pid
    }

    /// The app macOS sends keystrokes to, from the system-wide element.
    private func focusedApplicationPID() -> pid_t? {
        let systemWide = Self.boundingTimeout(AXUIElementCreateSystemWide())
        var appRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &appRef) == .success,
              let app = Self.axElement(fromAccessibilityValue: appRef) else { return nil }
        return Self.pid(of: app)
    }

    private func yappyappFocusState() -> (active: Bool, keyWindow: Bool) {
        MainActor.assumeIsolated {
            (NSApp.isActive, NSApp.keyWindow != nil)
        }
    }

    private func focusFacts(targetPID: pid_t?) -> DeliveryFocusPolicy.Facts {
        let own = yappyappFocusState()
        return DeliveryFocusPolicy.Facts(
            targetPID: targetPID,
            frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            focusedAppPID: focusedApplicationPID(),
            yappyappActive: own.active,
            yappyappHasKeyWindow: own.keyWindow
        )
    }

    /// The support-report version of the facts: owners, never titles.
    private func focusReport(targetPID: pid_t?) -> DeliveryFocusReport {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let own = yappyappFocusState()
        let focusedAppPID = focusedApplicationPID()
        let focusedApp = FocusOwner.classify(pid: focusedAppPID, targetPID: targetPID, ownPID: ownPID)
        let elementPID = focusedElement().flatMap(Self.pid(of:))
        return DeliveryFocusReport(
            yappyappActive: own.active,
            yappyappKeyWindow: own.keyWindow,
            focusedApp: focusedApp,
            focusedAppBundle: focusedApp == .other
                ? focusedAppPID.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
                : nil,
            focusedElement: FocusOwner.classify(pid: elementPID, targetPID: targetPID, ownPID: ownPID)
        )
    }

    /// Posts a synthetic ⌘V. Returns false WITHOUT posting when the user's own
    /// modifiers are still held after the settle window, so the caller can degrade
    /// to an honest copy-only outcome instead of firing the wrong chord.
    @discardableResult
    private func sendCommandV() -> Bool {
        let keyCodeCommand: CGKeyCode = 0x37 // kVK_Command
        // YA-59: the key that types "v" on the current layout (0x09 on QWERTY,
        // a different key on Dvorak or Colemak).
        let keyCodeV = KeyboardLayoutKeyCode.commandVKeyCode()

        // Synthesize ⌘V by pressing a REAL Command key around V, on the combined
        // session state. Chromium/Electron apps (Brave, Chrome, Slack, VS Code,
        // Notion, Discord) and many native fields read the GLOBAL modifier state
        // at paste time, not just the event's own flags. A private/HID source
        // leaves that global state empty, so ⌘V was read as a bare "v" and paste
        // never fired even though Accessibility was granted. Holding a genuine
        // Command key makes the modifier state actually show ⌘ down while V is
        // typed, which is what those apps require.
        let source = CGEventSource(stateID: .combinedSessionState)

        // Suppress the user's physical keyboard during the brief synthetic burst
        // so a still-held key cannot interleave with the events.
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )

        // The dominant failure was firing paste while Option (from the "⌥ space"
        // toggle) was still physically down. Wait briefly for the hardware
        // modifiers to clear first; this also gives the freshly-activated target
        // a beat to take focus.
        //
        // FIX chordTimeout: if they never clear, do NOT post — a bare "⌘V" event
        // combined with a still-held Option reads as ⌘⌥V in the very Chromium/
        // Electron apps this path targets. Refuse and let the caller copy-only.
        guard waitForModifiersToClear() else { return false }

        let commandDown = CGEvent(keyboardEventSource: source, virtualKey: keyCodeCommand, keyDown: true)
        commandDown?.flags = .maskCommand
        commandDown?.post(tap: .cghidEventTap)

        let vDown = CGEvent(keyboardEventSource: source, virtualKey: keyCodeV, keyDown: true)
        vDown?.flags = .maskCommand
        vDown?.post(tap: .cghidEventTap)

        usleep(35_000)

        let vUp = CGEvent(keyboardEventSource: source, virtualKey: keyCodeV, keyDown: false)
        vUp?.flags = .maskCommand
        vUp?.post(tap: .cghidEventTap)

        // Release Command last, with cleared flags, so it can never stay stuck.
        let commandUp = CGEvent(keyboardEventSource: source, virtualKey: keyCodeCommand, keyDown: false)
        commandUp?.flags = []
        commandUp?.post(tap: .cghidEventTap)

        return true
    }

    /// Polls the live hardware modifier flags until Command/Option/Shift/Control
    /// are released (or a short deadline elapses), so the synthetic Cmd+V is not
    /// posted while the user is still holding the "⌥ space" toggle hotkey.
    /// Returns true once the modifiers are clear, false if the deadline elapsed
    /// with an interfering modifier still held.
    private func waitForModifiersToClear() -> Bool {
        let interferingModifiers: NSEvent.ModifierFlags = [.command, .option, .shift, .control]
        let deadline = Date().addingTimeInterval(0.6)

        // Always give at least the original short settle so target focus lands.
        usleep(140_000)

        while Date() < deadline {
            let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags.isDisjoint(with: interferingModifiers) {
                return true
            }
            usleep(20_000)
        }

        // FIX chordTimeout: final check after the deadline so a modifier released
        // on the very last poll still counts as clear.
        return NSEvent.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .isDisjoint(with: interferingModifiers)
    }

    // FIX clipDestroy: a full snapshot of the pasteboard — every item and every
    // one of its concrete data types — so restore() can put back images, files,
    // rich text, and multi-flavor content, not just a single plain string.
    private struct ClipboardSnapshot: Sendable {
        /// Pasteboard type raw value -> immutable bytes, one map per item.
        let items: [[String: Data]]
    }

    private func captureClipboard() -> ClipboardSnapshot? {
        let general = NSPasteboard.general
        // YA-62: never re-post what a password manager marked concealed or
        // transient; it may already have cleared it on purpose.
        let itemTypes = (general.pasteboardItems ?? []).map { $0.types.map(\.rawValue) }
        guard PasteboardPrivacy.isRestorable(itemTypes: itemTypes) else { return nil }
        var snapshot: [[String: Data]] = []

        // NSPasteboardItem can only belong to one pasteboard, so deep-copy each
        // item's data into a detached item we own.
        for item in general.pasteboardItems ?? [] {
            var duplicate: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    duplicate[type.rawValue] = data
                }
            }
            if !duplicate.isEmpty {
                snapshot.append(duplicate)
            }
        }

        return ClipboardSnapshot(items: snapshot)
    }

    /// Restores the captured pasteboard snapshot, but ONLY if the clipboard has
    /// not changed since our own write. changeCount advances on every write by any
    /// process, so a mismatch means the user copied something new in the restore
    /// window — clobbering it would destroy their clipboard, so we leave it alone.
    private func restore(_ snapshot: ClipboardSnapshot,
                         ifChangeCountStillMatches expectedChangeCount: Int,
                         after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let general = NSPasteboard.general
            // FIX clipDestroy: bail out if anything touched the clipboard after us.
            guard Self.clipboardRestoreIsSafe(currentChangeCount: general.changeCount,
                                              expectedChangeCount: expectedChangeCount) else { return }

            general.clearContents()
            if !snapshot.items.isEmpty {
                let items = snapshot.items.map { payloads in
                    let item = NSPasteboardItem()
                    for (rawType, data) in payloads {
                        item.setData(data, forType: NSPasteboard.PasteboardType(rawType))
                    }
                    return item
                }
                general.writeObjects(items)
            }
        }
    }
}
