import SwiftUI

// FILES: file transcription has its own tab. A drop zone with CHOOSE FILE,
// the running job with progress and CANCEL, and this session's results with
// COPY and SAVE. Results live in memory only, like the MIC history.

extension BrutalistPopoverView {
    var filesTab: some View {
        BrutalScroll {
            VStack(spacing: 12) {
                FileTranscriptionDropZone(isBusy: state.fileTranscription?.isRunning == true)

                if let fileJob = state.fileTranscription {
                    FileTranscriptionCard(status: fileJob)
                }

                fileResultsBlock
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 92)
            .padding(.trailing, Brutal.drop)
        }
        .scrollIndicators(.never)
        .fileTranscriptionDropTarget()
    }

    private var fileResultsBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L10n.tr("RESULTS"))
                    .brutalFont(size: 10, weight: .black, relativeTo: .caption)
                    .kerning(1)
                    .foregroundStyle(Brutal.paper)

                Spacer()

                if !state.fileResults.isEmpty {
                    Button(L10n.tr("CLEAR")) {
                        state.fileResults = []
                    }
                    .buttonStyle(.plain)
                    .brutalFont(size: 9, weight: .black, relativeTo: .caption)
                    .kerning(0.8)
                    .foregroundStyle(Brutal.yellow)
                    .help(L10n.tr("Clears these results. The clipboard stays as it is."))
                    .brutalInteractive(
                        label: L10n.tr("Clear results"),
                        hint: L10n.tr("Clears these results. The clipboard stays as it is."),
                        value: "\(state.fileResults.count)",
                        hitExpansion: 10
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Brutal.ink)

            if state.fileResults.isEmpty {
                Text(L10n.tr("Transcripts of your files show up here. They live in memory only and are gone when you quit."))
                    .brutalFont(size: 11.5, weight: .semibold, relativeTo: .callout)
                    .foregroundStyle(Brutal.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .background(Brutal.card)
            } else {
                VStack(spacing: 0) {
                    ForEach(state.fileResults) { result in
                        FileTranscriptResultRow(
                            result: result,
                            onCopy: { copyFileResult(result) },
                            onSave: { saveFileResult(result) }
                        )
                    }
                }
                .background(Brutal.card)
            }
        }
        .frame(maxWidth: .infinity)
        .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))
        .background(Rectangle().fill(Brutal.ink).offset(x: Brutal.drop, y: Brutal.drop))
    }

    private func copyFileResult(_ result: FileTranscriptResult) {
        onCopyText(result.text)
        state.postFeedback(.success(L10n.tr("Copied to the clipboard."), topic: "file-result"), on: .files)
    }

    private func saveFileResult(_ result: FileTranscriptResult) {
        do {
            guard let url = try FileTranscriptSaver.save(result) else { return }
            state.postFeedback(.success(L10n.tr("Saved to %@.", url.lastPathComponent), topic: "file-result"), on: .files)
        } catch {
            state.postFeedback(.error(L10n.tr("Not saved. %@", error.localizedDescription), topic: "file-result"), on: .files)
        }
    }
}

/// The big target at the top of FILES: drop here or CHOOSE FILE. One job at
/// a time, so the button waits while a file runs.
struct FileTranscriptionDropZone: View {
    let isBusy: Bool
    @Environment(\.fileTranscriptionActions) private var actions

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.down.to.line")
                .brutalFont(size: 22, weight: .black, relativeTo: .title2)
                .foregroundStyle(Brutal.contentOnYellow)
                .frame(width: 48, height: 48)
                .background(Brutal.yellow)
                .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))
                .accessibilityHidden(true)

            VStack(spacing: 4) {
                Text(L10n.tr("DROP AUDIO OR VIDEO HERE"))
                    .brutalFont(size: 14, weight: .black, relativeTo: .headline)
                    .kerning(0.8)
                    .foregroundStyle(Brutal.ink)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Text(FileTranscriptionInput.supportedLabel.uppercased())
                    .brutalFont(size: 9, weight: .black, relativeTo: .caption2)
                    .kerning(0.6)
                    .foregroundStyle(Brutal.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(isBusy ? L10n.tr("ONE FILE AT A TIME") : L10n.tr("CHOOSE FILE")) {
                actions.choose()
            }
            .buttonStyle(BrutalTextButtonStyle(
                fill: isBusy ? Brutal.card : Brutal.blue,
                text: isBusy ? Brutal.textSecondary : Brutal.contentOnBlue
            ))
            .frame(maxWidth: 200)
            .disabled(isBusy)
            .padding(.top, 2)
            .brutalInteractive(
                label: L10n.tr("Transcribe audio file"),
                hint: isBusy
                    ? L10n.tr("A file is already being transcribed")
                    : L10n.tr("Pick an audio or video file. The transcript shows up in FILES, ready to copy or save."),
                hitExpansion: 5
            )

            Text(L10n.tr("TRANSCRIBED ON THIS MAC · KEPT IN FILES · NEVER PASTED"))
                .brutalFont(size: 8.5, weight: .black, relativeTo: .caption2)
                .kerning(0.5)
                .foregroundStyle(Brutal.textTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
        .background(Brutal.card)
        .overlay(
            Rectangle().strokeBorder(Brutal.ink, style: StrokeStyle(lineWidth: Brutal.border, dash: [7, 4]))
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fileDropZone.brutal")
    }
}

/// One finished file: name, word count, the first lines, COPY and SAVE.
struct FileTranscriptResultRow: View {
    let result: FileTranscriptResult
    let onCopy: () -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.fileName)
                        .brutalFont(size: 10, weight: .bold, design: .monospaced, relativeTo: .caption)
                        .foregroundStyle(Brutal.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(L10n.plural("%lld words", result.wordCount).uppercased())
                        .brutalFont(size: 8.5, weight: .black, relativeTo: .caption2)
                        .kerning(0.5)
                        .foregroundStyle(Brutal.textTertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 4) {
                    BrutalIconButton("doc.on.doc", title: L10n.tr("COPY"), help: L10n.tr("Copy to clipboard"), action: onCopy)
                    BrutalIconButton("square.and.arrow.down", title: L10n.tr("SAVE"), help: L10n.tr("Save as a text file"), action: onSave)
                }
            }

            Text(result.text)
                .brutalFont(size: 11.5, weight: .medium, relativeTo: .callout)
                .foregroundStyle(Brutal.textSecondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(Rectangle().frame(height: Brutal.border).foregroundStyle(Brutal.ink), alignment: .bottom)
        .accessibilityElement(children: .contain)
    }
}
