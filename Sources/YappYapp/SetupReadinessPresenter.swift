import Foundation

enum SetupReadinessAction: Equatable {
    case downloadRecommendedModel
    case showModels
    case requestAccessibility
    // MIC-LIVE-VERIFY: guided microphone step actions.
    case requestMicrophone
    case openMicrophoneSettings
    // UX-WRITING: downloads are off by the user's choice; the switch is in SETUP.
    case showSetup
}

struct SetupReadinessInput: Equatable {
    let isWhisperReady: Bool
    let isModelReady: Bool
    let isAccessibilityTrusted: Bool
    let pasteWhenFocusIsUnclear: Bool
    let allowModelDownloads: Bool
    let activeDownloadProgress: Double?
    // MIC-LIVE-VERIFY: live microphone permission state.
    let isMicrophoneAuthorized: Bool
    let isMicrophoneDenied: Bool
    // GUIDED-FIRST-RUN: true until the wizard completes once; drives whether
    // the card shows one numbered step or every outstanding issue.
    let isGuidedFirstRun: Bool
    // YA-35: the stale-permission detector fired, so the copy is the
    // reinstall one. YA-73: DMG users never see terminal commands.
    // YA-01: the model the Download button fetches, named in the copy.
    let isAccessibilityStale: Bool
    let isPackagedApp: Bool
    let recommendedModelName: String?
    // UX-WRITING: the size line is only stated for the model we know, and a
    // managed Mac is told to ask its IT admin instead of flipping a switch
    // it can't touch.
    let recommendedModelID: String?
    let downloadsLockedByOrganization: Bool

    init(
        isWhisperReady: Bool,
        isModelReady: Bool,
        isAccessibilityTrusted: Bool,
        pasteWhenFocusIsUnclear: Bool,
        allowModelDownloads: Bool,
        activeDownloadProgress: Double?,
        isMicrophoneAuthorized: Bool = true,
        isMicrophoneDenied: Bool = false,
        isGuidedFirstRun: Bool = false,
        isAccessibilityStale: Bool = false,
        isPackagedApp: Bool = false,
        recommendedModelName: String? = nil,
        recommendedModelID: String? = nil,
        downloadsLockedByOrganization: Bool = false
    ) {
        self.isWhisperReady = isWhisperReady
        self.isModelReady = isModelReady
        self.isAccessibilityTrusted = isAccessibilityTrusted
        self.pasteWhenFocusIsUnclear = pasteWhenFocusIsUnclear
        self.allowModelDownloads = allowModelDownloads
        self.activeDownloadProgress = activeDownloadProgress
        self.isMicrophoneAuthorized = isMicrophoneAuthorized
        self.isMicrophoneDenied = isMicrophoneDenied
        self.isGuidedFirstRun = isGuidedFirstRun
        self.isAccessibilityStale = isAccessibilityStale
        self.isPackagedApp = isPackagedApp
        self.recommendedModelName = recommendedModelName
        self.recommendedModelID = recommendedModelID
        self.downloadsLockedByOrganization = downloadsLockedByOrganization
    }
}

struct SetupReadinessRow: Identifiable, Equatable {
    let id: String
    let iconName: String
    let title: String
    let detail: String
    let actionTitle: String?
    let action: SetupReadinessAction?
    // GUIDED-FIRST-RUN: "Step k of N" pill, only set when the row is the single
    // focused step of the wizard. nil in the legacy multi-row card.
    var stepBadge: String?
    // UX-WRITING: names the steps still to come, so "STEP 1 OF 3" is never a
    // mystery. nil on the last step and outside the wizard.
    var stepMap: String?

    func withStepBadge(_ badge: String, stepMap: String? = nil) -> SetupReadinessRow {
        var copy = self
        copy.stepBadge = badge
        copy.stepMap = stepMap
        return copy
    }
}

enum SetupReadinessPresenter {
    // Legacy multi-row card: every outstanding issue at once, no step badges.
    // Kept as a thin wrapper so existing presenter tests and the
    // --setup-readiness-status diagnostic keep their behavior.
    static func rows(for input: SetupReadinessInput) -> [SetupReadinessRow] {
        orderedSteps(for: input)
    }

    // GUIDED-FIRST-RUN: during first run emit a SINGLE numbered step (the first
    // incomplete one). After first run completes, fall back to listing all
    // outstanding issues so existing users are never nagged with the wizard.
    static func guidedRows(for input: SetupReadinessInput) -> [SetupReadinessRow] {
        let steps = orderedSteps(for: input)
        // YA-35: after the wizard the auto-paste banner is the one prompt.
        guard input.isGuidedFirstRun else { return steps.filter { $0.id != "accessibility" } }
        guard let current = steps.first else { return [] }

        let total = guidedStepCount(for: input)
        let index = min(completedBefore(current, input: input) + 1, total)
        return [current.withStepBadge(
            L10n.tr("Step %@ of %@", "\(index)", "\(total)"),
            stepMap: stepMap(after: current, input: input)
        )]
    }

    /// The step names, in wizard order.
    static var modelStepTitle: String { L10n.tr("Get the voice model") }
    static var microphoneStepTitle: String { L10n.tr("Allow the mic") }
    static var accessibilityStepTitle: String { L10n.tr("Allow auto-paste") }

    /// "Next: Allow the mic · Allow auto-paste" for the open steps after this one.
    static func stepMap(after current: SetupReadinessRow, input: SetupReadinessInput) -> String? {
        var upcoming: [String] = []
        let isModelStep = current.id.hasPrefix("model") || current.id == "whisper-runtime"
        if isModelStep, !input.isMicrophoneAuthorized {
            upcoming.append(microphoneStepTitle)
        }
        if current.id != "accessibility", input.pasteWhenFocusIsUnclear, !input.isAccessibilityTrusted {
            upcoming.append(accessibilityStepTitle)
        }
        guard !upcoming.isEmpty else { return nil }
        return L10n.tr("Next: %@", upcoming.joined(separator: " · "))
    }

    // Fixed order: Whisper runtime, Voice model, Microphone, Accessibility.
    private static func orderedSteps(for input: SetupReadinessInput) -> [SetupReadinessRow] {
        var rows: [SetupReadinessRow] = []

        if !input.isWhisperReady {
            rows.append(
                SetupReadinessRow(
                    id: "whisper-runtime",
                    iconName: "cpu",
                    title: L10n.tr("Whisper models can't run"),
                    detail: WhisperRuntimeCopy.missingDetail(isPackagedApp: input.isPackagedApp),
                    actionTitle: input.isPackagedApp ? L10n.tr("Models") : nil,
                    action: input.isPackagedApp ? .showModels : nil
                )
            )
        }

        if !input.isModelReady {
            rows.append(modelRow(for: input))
        }

        // MIC-LIVE-VERIFY: microphone is required for any dictation, so it
        // belongs in the ordered flow before the auto-paste permission.
        if !input.isMicrophoneAuthorized {
            rows.append(microphoneRow(for: input))
        }

        if input.pasteWhenFocusIsUnclear && !input.isAccessibilityTrusted {
            rows.append(
                SetupReadinessRow(
                    id: "accessibility",
                    iconName: "text.cursor",
                    title: accessibilityStepTitle,
                    detail: input.isGuidedFirstRun && !input.isAccessibilityStale
                        ? AutoPastePrompt.firstTimeDetail
                        : L10n.tr("macOS remembers an older YappYapp. Click ALLOW. If that doesn't work, remove YappYapp from Accessibility and add it again."),
                    actionTitle: L10n.tr("Allow"),
                    action: .requestAccessibility
                )
            )
        }

        return rows
    }

    // MIC-LIVE-VERIFY: literal, deterministic copy. Denied/restricted switches
    // to the System Settings recovery path. No cute language, no em dashes.
    private static func microphoneRow(for input: SetupReadinessInput) -> SetupReadinessRow {
        SetupReadinessRow(
            id: "microphone",
            iconName: "mic",
            title: microphoneStepTitle,
            detail: input.isMicrophoneDenied
                ? L10n.tr("The mic is blocked. Click OPEN, then turn on YappYapp in System Settings > Privacy & Security > Microphone.")
                : L10n.tr("Your audio stays on this Mac. Click ALLOW, then choose Allow when macOS asks."),
            actionTitle: input.isMicrophoneDenied ? L10n.tr("Open") : L10n.tr("Allow"),
            action: input.isMicrophoneDenied ? .openMicrophoneSettings : .requestMicrophone
        )
    }

    // GUIDED-FIRST-RUN: total required steps for this config. Whisper runtime is
    // not counted as a user step (it is an install problem, not a permission to
    // grant); the wizard counts Model, Microphone, and Accessibility, omitting
    // Accessibility when auto-paste is off so the count and badges stay honest.
    static func guidedStepCount(for input: SetupReadinessInput) -> Int {
        var total = 0
        total += 1 // Voice model
        total += 1 // Microphone
        if input.pasteWhenFocusIsUnclear {
            total += 1 // Accessibility (auto-paste)
        }
        return total
    }

    // GUIDED-FIRST-RUN: how many required steps come before the current one in
    // the fixed order Model -> Microphone -> Accessibility, so the badge reads
    // "Step 1/2/3 of N" as each prior flag flips true. The whisper-runtime row
    // is an install fault, not a counted step, so it shows as Step 1.
    private static func completedBefore(_ current: SetupReadinessRow, input: SetupReadinessInput) -> Int {
        switch current.id {
        case "microphone":
            // Model is the only step that can precede the microphone step.
            return input.isModelReady ? 1 : 0
        case "accessibility":
            // Both model and microphone precede the accessibility step.
            return (input.isModelReady ? 1 : 0) + (input.isMicrophoneAuthorized ? 1 : 0)
        default:
            // Model rows and the whisper-runtime install row are the first step.
            return 0
        }
    }

    private static func modelRow(for input: SetupReadinessInput) -> SetupReadinessRow {
        if let progress = input.activeDownloadProgress {
            return SetupReadinessRow(
                id: "model-download",
                iconName: "square.and.arrow.down",
                title: L10n.tr("Downloading the voice model"),
                detail: L10n.tr("You can close this. The download keeps going."),
                actionTitle: progressTitle(for: progress),
                action: .showModels
            )
        }

        if input.allowModelDownloads {
            return SetupReadinessRow(
                id: "model-missing",
                iconName: "square.and.arrow.down",
                title: modelStepTitle,
                detail: modelDownloadDetail(name: input.recommendedModelName, id: input.recommendedModelID),
                actionTitle: L10n.tr("Download"),
                action: .downloadRecommendedModel
            )
        }

        if input.downloadsLockedByOrganization {
            return SetupReadinessRow(
                id: "model-managed",
                iconName: "externaldrive",
                title: L10n.tr("No voice model yet"),
                detail: L10n.tr("Your organization turned downloads off. Ask your IT admin to install a voice model."),
                actionTitle: L10n.tr("Models"),
                action: .showModels
            )
        }

        return SetupReadinessRow(
            id: "model-managed",
            iconName: "externaldrive",
            title: L10n.tr("No voice model yet"),
            detail: L10n.tr("Model downloads are off. Turn them on in Setup to get one."),
            actionTitle: L10n.tr("Setup"),
            action: .showSetup
        )
    }

    /// Size and one-time facts. Only the two multilingual Parakeet sizes
    /// are spelled out here.
    static func modelDownloadDetail(name: String?, id: String?) -> String {
        guard let name else {
            return L10n.tr("Download the recommended voice model, or pick another in Models.")
        }
        switch id {
        case "parakeet-ultra":
            return L10n.tr("%@ is about 630 MB, one time. Then it runs on this Mac with no internet.", name)
        case "parakeet-v3":
            return L10n.tr("%@ is about 480 MB, one time. Then it runs on this Mac with no internet.", name)
        default:
            return L10n.tr("%@ downloads once. Then it runs on this Mac with no internet.", name)
        }
    }

    private static func progressTitle(for progress: Double) -> String {
        guard progress >= 0 else { return L10n.tr("Models") }
        let percent = Int((min(max(progress, 0), 1)) * 100)
        return "\(percent)%"
    }
}
