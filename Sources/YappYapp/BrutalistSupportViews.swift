import AppKit
import SwiftUI
import UniformTypeIdentifiers

// SUPPORT track: the SETUP sections for the support report (YA-44) and the
// mic check, plus the guided "Say something" card on the MIC tab. Lives in
// its own file so the shared tab files only gain one line each.

/// Ink header bar over a card body: the same frame as the SETUP sections.
struct BrutalSupportPanel<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        BrutalSettingsCard(title) {
            content
        }
    }
}

// MARK: - Mic check

/// The meter, the verdict and the buttons. Shared by the guided card and the
/// SETUP section.
struct MicCheckBody: View {
    @ObservedObject var check: MicCheckController
    let deviceUID: String?
    @Binding var quietVoiceBoost: Bool
    let microphoneAuthorized: Bool
    let capturePhase: CapturePhase
    var guided = false
    /// SETUP shows the headline beside the MIC CHECK label instead.
    var showsHeadline = true
    var onDone: () -> Void = {}

    private var copy: MicCheckCopy {
        check.copy(quietVoiceBoost: quietVoiceBoost, pickerAbove: !guided)
    }

    private var meterFill: Color {
        switch copy.tone {
        case .good: Brutal.green
        case .warning: Brutal.yellow
        case .neutral: Brutal.blue
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsHeadline {
                MicCheckHeadline(copy: copy)
            }

            BrutalCaption(microphoneAuthorized ? copy.detail : L10n.tr("Allow the mic first."))

            meter

            HStack(spacing: 8) {
                if check.isRunning {
                    Button(L10n.tr("STOP"), action: check.finish)
                        .buttonStyle(BrutalTextButtonStyle(fill: Brutal.ink, text: Brutal.paper))
                        .brutalInteractive(label: L10n.tr("Stop mic check"), hint: L10n.tr("Closes the microphone and keeps the result"))
                } else {
                    Button(check.phase == .idle ? L10n.tr("START TEST") : L10n.tr("TEST AGAIN")) {
                        check.start(deviceUID: deviceUID)
                    }
                    .buttonStyle(BrutalTextButtonStyle(fill: Brutal.blue, text: Brutal.paper))
                    .disabled(!microphoneAuthorized || capturePhase == .recording)
                    .brutalInteractive(
                        label: L10n.tr("Start mic check"),
                        hint: L10n.tr("Listens for six seconds. Nothing is saved or transcribed.")
                    )
                }

                if copy.offersBoost {
                    Button(L10n.tr("TURN ON BOOST")) { quietVoiceBoost = true }
                        .buttonStyle(BrutalTextButtonStyle(fill: Brutal.yellow, text: Brutal.contentOnYellow))
                        .brutalInteractive(label: L10n.tr("Turn on Quiet Voice Boost"), hint: L10n.tr("Helps quiet and whispered dictation"))
                }

                if guided {
                    Button(check.phase == .finished ? L10n.tr("DONE") : L10n.tr("SKIP"), action: onDone)
                        .buttonStyle(BrutalTextButtonStyle(fill: Brutal.paper, text: Brutal.ink))
                        .brutalInteractive(label: check.phase == .finished ? L10n.tr("Done") : L10n.tr("Skip mic check"), hint: L10n.tr("Hides this step"))
                }
            }
        }
        .onChange(of: capturePhase) { _, newPhase in
            // A dictation owns the mic; the check steps aside.
            if newPhase == .recording { check.stop() }
        }
        .onDisappear {
            if check.isRunning { check.stop() }
        }
    }

    private var meter: some View {
        GeometryReader { proxy in
            Rectangle()
                .fill(meterFill)
                .frame(width: max(0, proxy.size.width * CGFloat(check.meter.barLevel)))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .frame(height: 16)
        .background(Brutal.field)
        .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))
        .accessibilityElement()
        .accessibilityLabel(L10n.tr("Input level"))
        .accessibilityValue(copy.headline.capitalized)
    }
}

/// The verdict, in the value style, green when the level is good.
struct MicCheckHeadline: View {
    let copy: MicCheckCopy

    var body: some View {
        Text(copy.headline)
            .brutalText(.value)
            .foregroundStyle(copy.tone == .good ? Brutal.successText : Brutal.ink)
    }
}

/// MIC tab card during first run, after the microphone is allowed.
struct MicCheckGuidedCard: View {
    @ObservedObject var state: YappYappState
    @Binding var quietVoiceBoost: Bool
    @ObservedObject var check: MicCheckController = .shared

    var body: some View {
        if MicCheckController.showsGuidedCard(
            armed: check.guidedStepArmed,
            microphoneAuthorized: state.isMicrophoneAuthorized,
            phase: state.phase
        ) {
            BrutalSupportPanel(title: L10n.tr("MIC CHECK")) {
                MicCheckBody(
                    check: check,
                    deviceUID: state.config.inputDeviceUID,
                    quietVoiceBoost: $quietVoiceBoost,
                    microphoneAuthorized: state.isMicrophoneAuthorized,
                    capturePhase: state.phase,
                    guided: true,
                    onDone: check.finishGuidedStep
                )
            }
        }
    }
}

/// SETUP > MICROPHONE: the same check, right under the mic picker it tests.
struct MicCheckSettingsSection: View {
    @ObservedObject var state: YappYappState
    let deviceUID: String?
    @Binding var quietVoiceBoost: Bool
    @ObservedObject var check: MicCheckController = .shared

    var body: some View {
        VStack(alignment: .leading, spacing: BrutalControl.innerSpacing) {
            HStack(spacing: 10) {
                BrutalRowLabel(L10n.tr("MIC CHECK"))
                Spacer(minLength: 8)
                // Idle, the label already says what this is; the reading
                // appears once the check runs.
                if check.phase != .idle {
                    MicCheckHeadline(copy: check.copy(quietVoiceBoost: quietVoiceBoost, pickerAbove: true))
                }
            }
            MicCheckBody(
                check: check,
                deviceUID: deviceUID,
                quietVoiceBoost: $quietVoiceBoost,
                microphoneAuthorized: state.isMicrophoneAuthorized,
                capturePhase: state.phase,
                showsHeadline: false
            )
        }
    }
}

// MARK: - Support report

/// HELP: who made the app and where to reach him.
struct MadeByGroup: View {
    var openLink: (URL) -> Void = { DeveloperLinks.open($0) }

    var body: some View {
        VStack(alignment: .leading, spacing: BrutalControl.innerSpacing) {
            BrutalRowLabel(L10n.tr("MADE BY MIGUEL TORREZ"))
            BrutalCaption(L10n.tr("Questions or ideas? Message me."))
            HStack(spacing: 8) {
                BrutalActionButton(
                    title: L10n.tr("YOUTUBE"),
                    accessibilityLabel: L10n.tr("Miguel Torrez on YouTube"),
                    hint: L10n.tr("Opens YouTube in your browser"),
                    action: { openLink(DeveloperLinks.youTube) }
                )
                BrutalActionButton(
                    title: L10n.tr("LINKEDIN"),
                    accessibilityLabel: L10n.tr("Miguel Torrez on LinkedIn"),
                    hint: L10n.tr("Opens LinkedIn in your browser"),
                    action: { openLink(DeveloperLinks.linkedIn) }
                )
            }
        }
    }
}

struct SupportReportSection: View {
    @ObservedObject var state: YappYappState
    let onCopy: (String) -> Void
    var onRevealSupport: (() -> Void)?
    var openLink: (URL) -> Void = { DeveloperLinks.open($0) }
    var crashDirectory: URL? = SupportReportSection.defaultCrashDirectory

    @State private var crashes: [CrashReportEntry] = []
    @State private var note: String?

    /// nil skips the scan. Self-tests never read the real crash folder.
    static var defaultCrashDirectory: URL? {
        #if DEBUG
        if CommandLine.arguments.contains("--self-test") || CommandLine.arguments.contains("--render-gallery") { return nil }
        #endif
        return CrashReportScanner.defaultDirectory
    }

    var body: some View {
        BrutalSupportPanel(title: SetupSection.help.title) {
            VStack(alignment: .leading, spacing: BrutalControl.innerSpacing) {
                BrutalCaption(L10n.tr("For bug reports. Versions, model and settings only. No audio, transcripts, words or user names."))

                HStack(spacing: 8) {
                    Button(L10n.tr("COPY REPORT"), action: copyReport)
                        .buttonStyle(BrutalTextButtonStyle(fill: Brutal.blue, text: Brutal.paper))
                        .brutalInteractive(
                            label: L10n.tr("Copy support report"),
                            hint: L10n.tr("Copies a report with no personal content, for a GitHub issue")
                        )
                    Button(L10n.tr("SAVE AS FILE"), action: saveReport)
                        .buttonStyle(BrutalTextButtonStyle(fill: Brutal.paper, text: Brutal.ink))
                        .brutalInteractive(label: L10n.tr("Save support report"), hint: L10n.tr("Saves the same report as a file"))
                }

                if let note {
                    BrutalCaption(note, tone: .success)
                }
            }

            BrutalGroupBreak()

            MadeByGroup(openLink: openLink)

            BrutalGroupBreak()

            VStack(alignment: .leading, spacing: BrutalControl.innerSpacing) {
                HStack(spacing: 10) {
                    BrutalRowLabel(L10n.tr("RECENT CRASHES"))
                    Spacer(minLength: 8)
                    if let onRevealSupport {
                        BrutalActionButton(
                            title: L10n.tr("SHOW SUPPORT FILES"),
                            accessibilityLabel: L10n.tr("Show support files"),
                            hint: L10n.tr("Opens YappYapp support files in Finder"),
                            action: onRevealSupport
                        )
                    }
                }

                if crashes.isEmpty {
                    BrutalCaption(L10n.tr("None in the last 30 days."))
                } else {
                    VStack(spacing: 0) {
                        ForEach(crashes) { entry in
                            crashRow(entry)
                        }
                    }
                    .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))
                }
            }
        }
        .onAppear(perform: refreshCrashes)
    }

    private func crashRow(_ entry: CrashReportEntry) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
                    .brutalText(.caption)
                    .foregroundStyle(Brutal.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(Self.dateLabel(entry.date))
                    .brutalText(.caption)
                    .foregroundStyle(Brutal.textSecondary)
            }
            Spacer()
            BrutalActionButton(
                title: L10n.tr("REVEAL"),
                accessibilityLabel: L10n.tr("Reveal %@", entry.name),
                hint: L10n.tr("Shows the crash report in Finder")
            ) {
                NSWorkspace.shared.activateFileViewerSelecting([entry.url])
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Brutal.card)
    }

    static func dateLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func refreshCrashes() {
        guard let crashDirectory else { return }
        crashes = CrashReportScanner.recent(in: crashDirectory)
    }

    private func makeReport() -> String {
        refreshCrashes()
        var input = SupportReport.currentInput(state: state)
        input.crashReports = crashes
        return SupportReport.render(input)
    }

    private func copyReport() {
        onCopy(makeReport())
        note = L10n.tr("Copied. Paste it into the GitHub issue.")
    }

    private func saveReport() {
        let report = makeReport()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = SupportReport.fileName
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        NSApp.activate()
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                do {
                    try PrivateFile.write(Data(report.utf8), to: url)
                    note = L10n.tr("Saved.")
                } catch {
                    note = L10n.tr("Could not save. Try another folder.")
                }
            }
        }
    }
}
