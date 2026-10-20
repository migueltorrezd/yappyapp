import Foundation

// SUPPORT (YA-44): the in-app "Copy support report". Same sanitized content as
// scripts/support_report.sh: versions, engine, model ids, permissions and
// settings flags. Never transcripts, glossary text, the custom vocabulary
// prompt, device names, config contents or paths that carry a user name.

/// One recent YappYapp crash report. Only the file name and date ever reach
/// the report; the file itself is never read.
struct CrashReportEntry: Equatable, Sendable, Identifiable {
    let url: URL
    let date: Date

    var id: String { url.path }
    var name: String { url.lastPathComponent }
}

enum CrashReportScanner {
    static let maxAge: TimeInterval = 30 * 24 * 60 * 60
    static let limit = 10
    static let extensions: Set<String> = ["ips", "crash"]

    /// Where macOS writes per-user crash reports.
    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
    }

    /// YappYapp's own reports from the last 30 days, newest first. Names and
    /// modification dates only.
    static func recent(
        in directory: URL = defaultDirectory,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) -> [CrashReportEntry] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let entries: [CrashReportEntry] = urls.compactMap { url in
            guard isYappYappReport(name: url.lastPathComponent) else { return nil }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true, let date = values?.contentModificationDate else { return nil }
            guard now.timeIntervalSince(date) <= maxAge else { return nil }
            return CrashReportEntry(url: url, date: date)
        }

        return Array(entries.sorted { $0.date > $1.date }.prefix(limit))
    }

    static func isYappYappReport(name: String) -> Bool {
        let lowered = name.lowercased()
        let ext = (lowered as NSString).pathExtension
        return lowered.hasPrefix("yappyapp") && extensions.contains(ext)
    }
}

/// Everything the report prints, gathered up front so the rendering is pure
/// and testable without the app, TCC or the file system.
struct SupportReportInput: Sendable {
    var generatedAt: Date
    var appVersion: String
    var buildNumber: String
    var bundleIdentifier: String?
    var isPackagedApp: Bool
    var macOSVersion: String
    var architecture: String
    var config: AppConfig
    var selectedModelID: String
    var selectedModelName: String
    var isModelReady: Bool
    var isWhisperReady: Bool
    var microphone: String
    var accessibilityTrusted: Bool
    var staleAccessibilitySuspected: Bool
    var launchAtLogin: Bool
    var launchAtLoginNeedsApproval: Bool
    var managedKeys: [String]
    var glossaryEntryCount: Int
    /// LEARN-FROM-FIXES: counts only, never the words.
    var glossaryLearnedCount: Int = 0
    var neverLearnCount: Int = 0
    var crashReports: [CrashReportEntry]
    var homeDirectory: String
    /// DELIVERY-TRAIL: newest 20 deliveries, no transcript text.
    var deliveryTrail: [String] = []
    /// LLM-CLEANUP-WARM, TRANSLATION-WARM: the two warm llama-servers.
    var cleanupServer: LlamaServerStatus = .notRunning
    var translationServer: LlamaServerStatus = .notRunning
    /// QWEN3-ASR-WARM: the warm speech server.
    var speechServer: LlamaServerStatus = .notRunning
}

enum SupportReport {
    static let fileName = "YappYapp Support Report.md"

    static func render(_ input: SupportReportInput) -> String {
        var lines: [String] = []
        func line(_ text: String = "") { lines.append(text) }
        func item(_ label: String, _ value: String) { lines.append("- \(label): \(value)") }
        func flag(_ value: Bool) -> String { value ? "on" : "off" }
        func yes(_ value: Bool) -> String { value ? "yes" : "no" }

        let config = input.config

        line("# YappYapp Support Report")
        line()
        line("This report is designed for GitHub issues. It does not include audio, transcripts, glossary entries, the custom vocabulary prompt, device names, config contents or app logs.")
        line()

        line("## Generated")
        line()
        item("UTC time", isoTimestamp(input.generatedAt))
        item("Source", "in-app (SETUP, SUPPORT)")
        line()

        line("## App")
        line()
        item("Version", "\(input.appVersion) (\(input.buildNumber))")
        item("Bundle identifier", input.bundleIdentifier ?? "none (source build)")
        item("Build type", input.isPackagedApp ? "packaged app" : "source build")
        line()

        line("## System")
        line()
        item("macOS", input.macOSVersion)
        item("Architecture", input.architecture)
        line()

        line("## Engine")
        line()
        let option = ModelCatalog.option(for: input.selectedModelID)
        item("Selected model", "\(input.selectedModelID) (\(input.selectedModelName))")
        item("Engine", option?.engine.rawValue ?? "unknown")
        item("Model file", modelFileLabel(config.modelPath))
        item("Model ready", yes(input.isModelReady))
        item("Whisper runtime ready", yes(input.isWhisperReady))
        item("Language", config.language)
        item("Keep the model warm", flag(config.keepModelWarm))
        item("Super Fast Mode", flag(config.superFastMode))
        item("LLM cleanup", flag(config.llmCleanup))
        item("Cleanup mode", config.cleanup.rawValue)
        item("Warm cleanup server", input.cleanupServer.rawValue)
        item("Warm translation server", input.translationServer.rawValue)
        item("Warm Qwen3-ASR server", input.speechServer.rawValue)
        line()

        line("## Permissions")
        line()
        item("Microphone", input.microphone)
        item("Accessibility", input.accessibilityTrusted ? "trusted" : "not trusted")
        item("Stale Accessibility entry suspected", yes(input.staleAccessibilitySuspected))
        item("Start at login", flag(input.launchAtLogin) + (input.launchAtLoginNeedsApproval ? " (needs approval)" : ""))
        line()

        line("## Settings")
        line()
        item("Auto-paste", flag(config.autoPaste))
        item("Paste even without a text field", flag(config.pasteWhenFocusIsUnclear))
        item("Esc cancels dictation", flag(config.escCancelsRecording))
        item("Text in notifications", flag(config.showTextInNotifications))
        item("Quiet Voice Boost", flag(config.quietVoiceBoost))
        item("Remove filler words", flag(config.removeFillerWords))
        item("Translate to", config.translation.rawValue)
        item("Translation model", config.translationPlan.modelID?.rawValue ?? "none")
        item("Spoken commands", flag(config.spokenCommands))
        item("Numbers", config.numbers.rawValue)
        item("Live preview", flag(config.livePreview))
        item("Per-app profiles", "\(config.appProfiles.count) (apps hidden)")
        item("Recording mode", config.shortcuts.mode.rawValue)
        item("One-key trigger", config.shortcuts.modifierHold?.rawValue ?? "off")
        item("Auto-stop after", "\(Int(config.maxRecordingSeconds)) s")
        item("Input device", config.inputDeviceUID == nil ? "system default" : "a specific device (name hidden)")
        item("Indicator", HUDPosition(configValue: config.hudPosition).rawValue)
        item("Play sounds", flag(config.playSounds))
        item("Pet and quests", flag(config.petEnabled))
        item("Text size", config.textSize)
        item("App language", "\(config.appLanguage) (shows \(L10n.language))")
        item("Allow model downloads", flag(config.allowModelDownloads))
        item("Automatic update checks", flag(config.automaticUpdateChecks))
        item("Custom vocabulary prompt", config.additionalPrompt == AppConfig.defaultConfig.additionalPrompt ? "default" : "custom (text hidden)")
        item("Glossary", "\(input.glossaryEntryCount) entries, \(input.glossaryLearnedCount) learned from fixes (text hidden)")
        item("Learn from my fixes", flag(config.learnFromFixes))
        item("Never-learn list", "\(input.neverLearnCount) words (text hidden)")
        item("Managed settings", input.managedKeys.isEmpty ? "none" : input.managedKeys.sorted().joined(separator: ", "))
        line()

        line("## Recent Deliveries")
        line()
        if input.deliveryTrail.isEmpty {
            line("None since YappYapp started.")
        } else {
            line("Oldest first. Target app, route and outcome only; never the text.")
            line()
            input.deliveryTrail.forEach { line($0) }
        }
        line()

        line("## Recent Crash Reports")
        line()
        if input.crashReports.isEmpty {
            line("None in the last 30 days.")
        } else {
            for entry in input.crashReports {
                line("- \(entry.name) (\(isoTimestamp(entry.date)))")
            }
            line()
            line("Attach a crash file only if a maintainer asks for it.")
        }
        line()

        line("## Before Posting")
        line()
        line("- [ ] I reviewed this report and removed anything I consider private.")
        line("- [ ] I did not attach audio recordings, transcripts, glossary files, config files or app logs unless a maintainer explicitly asked for them.")

        return redact(lines.joined(separator: "\n") + "\n", homeDirectory: input.homeDirectory)
    }

    /// Whisper model paths can sit under the user's home; only the file name
    /// matters for support. Parakeet and Qwen3-ASR ids are not paths and stay
    /// as they are.
    static func modelFileLabel(_ modelPath: String) -> String {
        if modelPath.hasPrefix("parakeet://") || modelPath.hasPrefix(Qwen3ASRVariant.scheme) { return modelPath }
        let name = (modelPath as NSString).lastPathComponent
        return name.isEmpty ? "none" : name
    }

    /// Same rules as support_report.sh: the home directory becomes ~ and any
    /// other /Users/<name> becomes /Users/<user>.
    static func redact(_ text: String, homeDirectory: String) -> String {
        var result = text
        let home = homeDirectory.hasSuffix("/") ? String(homeDirectory.dropLast()) : homeDirectory
        if home.count > 1 {
            result = result.replacingOccurrences(of: home, with: "~")
        }
        if let pattern = try? NSRegularExpression(pattern: #"/Users/[^/\s]+"#) {
            let range = NSRange(result.startIndex..., in: result)
            result = pattern.stringByReplacingMatches(in: result, range: range, withTemplate: "/Users/<user>")
        }
        return result
    }

    static func isoTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    static var architecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }

    static func microphoneLabel(authorized: Bool, denied: Bool) -> String {
        if authorized { return "authorized" }
        return denied ? "denied" : "not granted yet"
    }

    /// Reads the live app state. Permission values come from the state the app
    /// already polls, so building a report never prompts or touches TCC.
    @MainActor
    static func currentInput(
        state: YappYappState,
        crashDirectory: URL = CrashReportScanner.defaultDirectory,
        now: Date = Date(),
        bundle: Bundle = .main
    ) -> SupportReportInput {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return SupportReportInput(
            generatedAt: now,
            appVersion: version ?? "unknown",
            buildNumber: build ?? "unknown",
            bundleIdentifier: bundle.bundleIdentifier,
            isPackagedApp: bundle.bundleIdentifier != nil,
            macOSVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            architecture: architecture,
            config: state.config,
            selectedModelID: state.selectedModelID,
            selectedModelName: state.selectedModelName,
            isModelReady: state.isModelReady,
            isWhisperReady: state.isWhisperReady,
            microphone: microphoneLabel(authorized: state.isMicrophoneAuthorized, denied: state.isMicrophoneDenied),
            accessibilityTrusted: state.isAccessibilityTrusted,
            staleAccessibilitySuspected: state.staleAccessibility != .clean,
            launchAtLogin: state.launchAtLoginEnabled,
            launchAtLoginNeedsApproval: state.launchAtLoginNeedsApproval,
            managedKeys: state.managedConfigKeys.map(\.rawValue),
            glossaryEntryCount: state.glossaryEntries.count,
            glossaryLearnedCount: state.glossaryEntries.filter(\.isLearned).count,
            neverLearnCount: NeverLearnList.load().count,
            crashReports: CrashReportScanner.recent(in: crashDirectory, now: now),
            homeDirectory: NSHomeDirectory(),
            deliveryTrail: state.deliveryTrail.reportLines(),
            cleanupServer: LlamaServerController.cleanup.status,
            translationServer: LlamaServerController.translation.status,
            speechServer: LlamaServerController.speech.status
        )
    }
}
