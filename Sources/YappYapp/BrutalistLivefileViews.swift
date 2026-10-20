import SwiftUI
import UniformTypeIdentifiers

// LIVEFILE: views for the HUD live preview and FILES-tab file transcription.
// The actions travel through the environment so the popover's long init
// stays untouched.

struct FileTranscriptionActions: Sendable {
    var start: @MainActor @Sendable (URL) -> Void = { _ in }
    var choose: @MainActor @Sendable () -> Void = {}
    var cancel: @MainActor @Sendable () -> Void = {}
    var dismiss: @MainActor @Sendable () -> Void = {}
}

private struct FileTranscriptionActionsKey: EnvironmentKey {
    static let defaultValue = FileTranscriptionActions()
}

extension EnvironmentValues {
    var fileTranscriptionActions: FileTranscriptionActions {
        get { self[FileTranscriptionActionsKey.self] }
        set { self[FileTranscriptionActionsKey.self] = newValue }
    }
}

/// The file job card on the FILES tab: progress with CANCEL while running, the
/// outcome with OK afterwards. Hidden when there is no job.
struct FileTranscriptionCard: View {
    let status: FileTranscriptionStatus
    @Environment(\.fileTranscriptionActions) private var actions

    private var fill: Color {
        switch status {
        case .running: Brutal.card
        case .finished: Brutal.green
        case .failed: Brutal.yellow
        case .canceled: Brutal.paper
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(FileTranscriptionPresenter.headline(for: status))
                        .brutalFont(size: 11, weight: .black, relativeTo: .callout)
                        .kerning(0.8)
                        .foregroundStyle(Brutal.ink)
                    Text(status.fileName)
                        .brutalFont(size: 10, weight: .semibold, design: .monospaced, relativeTo: .caption)
                        .foregroundStyle(Brutal.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                Button(status.isRunning ? L10n.tr("CANCEL") : L10n.tr("OK")) {
                    status.isRunning ? actions.cancel() : actions.dismiss()
                }
                .buttonStyle(.plain)
                .brutalFont(size: 10, weight: .black, relativeTo: .caption)
                .kerning(0.6)
                .foregroundStyle(status.isRunning ? Brutal.ink : Brutal.paper)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(status.isRunning ? Brutal.paper : Brutal.ink)
                .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))
                .brutalInteractive(
                    label: status.isRunning ? L10n.tr("Cancel file transcription") : L10n.tr("Dismiss"),
                    hint: status.isRunning
                        ? L10n.tr("Stops transcribing this file. Nothing is copied.")
                        : L10n.tr("Hides this file result"),
                    hitExpansion: 10
                )
            }

            if let progress = FileTranscriptionPresenter.progress(for: status) {
                BrutalProgressBar(fraction: progress)
                    .accessibilityHidden(true)
            }

            Text(FileTranscriptionPresenter.detail(for: status))
                .brutalFont(size: 9, weight: .black, relativeTo: .caption2)
                .kerning(0.6)
                .foregroundStyle(Brutal.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fill)
        .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))
        .background(Rectangle().fill(Brutal.ink).offset(x: Brutal.drop, y: Brutal.drop))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "\(FileTranscriptionPresenter.headline(for: status).lowercased()). \(FileTranscriptionPresenter.detail(for: status).lowercased())"
        )
        .accessibilityIdentifier("fileTranscriptionCard.brutal")
    }
}

/// Flat fill inside a 2pt frame. No rounding, no animation.
struct BrutalProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            Rectangle()
                .fill(Brutal.blue)
                .frame(width: max(0, proxy.size.width * min(max(fraction, 0), 1)))
        }
        .frame(height: 10)
        .background(Brutal.paper)
        .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))
    }
}

/// Accepts a dropped audio or video file and hands it to the file job.
private struct FileTranscriptionDropModifier: ViewModifier {
    @Environment(\.fileTranscriptionActions) private var actions
    // Offscreen renders (self-tests, gallery) cannot draw the platform drop
    // target and paint a placeholder over the tab instead, so skip it there.
    @Environment(\.brutalFlattensScroll) private var offscreen
    @State private var targeted = false

    func body(content: Content) -> some View {
        if offscreen {
            content
        } else {
            dropTarget(content)
        }
    }

    private func dropTarget(_ content: Content) -> some View {
        content
            .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in
                guard let provider = providers.first else { return false }
                let start = actions.start
                _ = provider.loadDataRepresentation(for: .fileURL) { data, _ in
                    guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    Task { @MainActor in
                        start(url)
                    }
                }
                return true
            }
            .overlay {
                if targeted {
                    VStack(spacing: 6) {
                        Text(L10n.tr("DROP TO TRANSCRIBE"))
                            .brutalFont(size: 16, weight: .black, relativeTo: .headline)
                            .kerning(1)
                        Text(L10n.tr("COPIED WHEN DONE · NEVER PASTED"))
                            .brutalFont(size: 9, weight: .black, relativeTo: .caption2)
                            .kerning(0.6)
                    }
                    .foregroundStyle(Brutal.ink)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Brutal.yellow)
                    .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))
                    .allowsHitTesting(false)
                }
            }
    }
}

extension View {
    func fileTranscriptionDropTarget() -> some View {
        modifier(FileTranscriptionDropModifier())
    }
}

/// One line of live text above the HUD bar while recording. Paper on ink
/// border, monospaced, never interactive.
struct LivePreviewStrip: View {
    let text: String

    // Sized to sit on the compact indicator bar.
    static let height: CGFloat = 20

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .lineLimit(1)
            .truncationMode(.head)
            .foregroundStyle(Brutal.ink)
            .padding(.horizontal, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: Self.height)
            .background(Brutal.paper)
            .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))
            .accessibilityLabel(L10n.tr("Live preview: %@", text))
            .accessibilityAddTraits(.updatesFrequently)
    }
}

/// Caption under SHOW WORDS WHILE I TALK in SETUP.
struct LivePreviewSettingsNote: View {
    let config: AppConfig

    var body: some View {
        BrutalCaption(LivePreviewPolicy.settingsNote(config: config))
    }
}
