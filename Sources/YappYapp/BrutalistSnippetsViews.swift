import SwiftUI

/// SNIPPETS: which list the WORDS tab shows.
enum WordsMode: Equatable {
    case words
    case snippets
}

/// SNIPPETS: the share strip under the WORDS tab mode bar.
enum WordsShareState: Equatable {
    case idle
    case choosingExport
    case previewing(PendingWordsImport)
}

enum SnippetPlaceholders {
    static var trigger: String { L10n.tr("my email address") }
    static let expansion = "you@example.com"
}

extension BrutalistPopoverView {
    // MARK: - Words tab shell

    var wordsTab: some View {
        VStack(spacing: 10) {
            wordsModeBar

            switch wordsShare {
            case .previewing(let pending):
                WordsImportPreviewCard(
                    pending: pending,
                    plan: pending.plan(glossary: state.glossaryEntries, snippets: state.snippets),
                    onPolicy: { policy in
                        var updated = pending
                        updated.policy = policy
                        wordsShare = .previewing(updated)
                    },
                    onCancel: { wordsShare = .idle },
                    onApply: { applyWordsImport(pending) }
                )
                Spacer(minLength: 0)
            case .choosingExport:
                WordsExportChooser(
                    snippetCount: state.snippets.count,
                    onExport: { kind in exportWords(kind) },
                    onCancel: { wordsShare = .idle }
                )
                wordsModePane
            case .idle:
                wordsModePane
            }
        }
    }

    @ViewBuilder
    private var wordsModePane: some View {
        switch wordsMode {
        case .words:
            glossaryPane
        case .snippets:
            snippetsPane
        }
    }

    private var wordsModeBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 0) {
                // Counts follow the rows on screen, not the last save.
                wordsModeButton(.words, title: L10n.tr("WORDS %@", "\(WordsDeletion.visibleCount(glossaryDrafts))"))
                Rectangle().fill(Brutal.ink).frame(width: Brutal.border)
                wordsModeButton(.snippets, title: L10n.tr("SNIPPETS %@", "\(WordsDeletion.visibleCount(snippetDrafts))"))
            }
            .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))
            .background(Rectangle().fill(Brutal.ink).offset(x: Brutal.drop, y: Brutal.drop))

            Button(L10n.tr("IMPORT")) {
                chooseWordsImport()
            }
            .buttonStyle(BrutalTextButtonStyle(fill: Brutal.card, text: Brutal.ink))
            // L10N: longer words shrink a little instead of wrapping.
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .frame(width: 74)
            .disabled(wordsHaveUnsavedEdits)
            .brutalInteractive(
                label: L10n.tr("Import words"),
                hint: wordsHaveUnsavedEdits
                    ? L10n.tr("Save or revert your edits first")
                    : L10n.tr("Opens a words file and shows what it adds before anything changes"),
                hitExpansion: 5
            )

            Button(L10n.tr("EXPORT")) {
                wordsShare = wordsShare == .choosingExport ? .idle : .choosingExport
            }
            .buttonStyle(BrutalTextButtonStyle(fill: Brutal.card, text: Brutal.ink))
            // L10N: longer words shrink a little instead of wrapping.
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .frame(width: 74)
            .brutalInteractive(
                label: L10n.tr("Export words"),
                hint: L10n.tr("Saves your words and snippets to a file. Never your history."),
                hitExpansion: 5
            )
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.trailing, Brutal.drop)
    }

    private func wordsModeButton(_ mode: WordsMode, title: String) -> some View {
        Button {
            wordsMode = mode
        } label: {
            Text(title)
                .brutalFont(size: 10, weight: .black, relativeTo: .caption)
                .kerning(0.6)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background(wordsMode == mode ? Brutal.ink : Brutal.card)
                .foregroundStyle(wordsMode == mode ? Brutal.paper : Brutal.ink)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .brutalInteractive(
            label: mode == .words ? L10n.tr("Words") : L10n.tr("Snippets"),
            hint: mode == .words ? L10n.tr("Shows your spellings") : L10n.tr("Shows phrases that expand to stored text"),
            value: wordsMode == mode ? L10n.tr("Selected") : L10n.tr("Not selected"),
            selected: wordsMode == mode,
            hitExpansion: 5
        )
    }

    private var wordsHaveUnsavedEdits: Bool {
        glossaryDrafts.map(\.entry) != state.glossaryEntries || snippetsDirty
    }

    // MARK: - Snippets list

    private var snippetsPane: some View {
        VStack(spacing: 10) {
            Text(L10n.tr("SAY A PHRASE, GET THE TEXT. \"MY EMAIL ADDRESS\" BECOMES YOUR ADDRESS. SAY IT EXACTLY. PRESS SAVE SNIPPETS TO APPLY."))
                .brutalFont(size: 10, weight: .black, relativeTo: .caption)
                .kerning(0.6)
                .foregroundStyle(Brutal.ink)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Brutal.yellow)
                .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))

            BrutalScroll {
                VStack(spacing: 10) {
                    Button {
                        snippetDrafts.insert(SnippetDraft(trigger: "", expansion: "", wantsFocus: true), at: 0)
                    } label: {
                        Text(L10n.tr("+ ADD A SNIPPET"))
                            .brutalFont(size: 11, weight: .black, relativeTo: .callout)
                            .kerning(0.8)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 34)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(BrutalButtonStyle(fill: Brutal.card))
                    .brutalInteractive(
                        label: L10n.tr("Add a snippet"),
                        hint: L10n.tr("Adds a new snippet"),
                        hitExpansion: 5
                    )

                    ForEach($snippetDrafts) { $draft in
                        BrutalSnippetRow(draft: $draft, issue: snippetIssues[draft.id]) {
                            deleteSnippetDraft(draft.id)
                        }
                    }
                }
                .padding(.bottom, Brutal.drop)
                .padding(.trailing, Brutal.drop)
            }
            .scrollIndicators(.never)

            if snippetsDirty {
                HStack(spacing: 10) {
                    Button(L10n.tr("REVERT")) {
                        resetSnippetDrafts()
                    }
                    .buttonStyle(BrutalTextButtonStyle(fill: Brutal.card, text: Brutal.ink))
                    .brutalInteractive(
                        label: L10n.tr("Revert snippet changes"),
                        hint: L10n.tr("Restores the last saved snippets"),
                        hitExpansion: 5
                    )

                    Button(snippetIssues.isEmpty ? L10n.tr("SAVE SNIPPETS") : L10n.tr("FIX MARKED SNIPPETS")) {
                        onSaveSnippets(savableSnippetDrafts.map(\.snippet))
                        resetSnippetDrafts()
                    }
                    .buttonStyle(BrutalTextButtonStyle(
                        fill: snippetIssues.isEmpty ? Brutal.blue : Brutal.card,
                        text: snippetIssues.isEmpty ? Brutal.paper : Brutal.dangerText
                    ))
                    .disabled(!snippetIssues.isEmpty)
                    .brutalInteractive(
                        label: L10n.tr("Save snippets"),
                        hint: snippetIssues.isEmpty
                            ? L10n.plural("Saves %lld snippets", savableSnippetDrafts.count)
                            : L10n.tr("Fix the marked snippets first"),
                        value: L10n.plural("%lld snippets", savableSnippetDrafts.count),
                        hitExpansion: 5
                    )
                }
            }
        }
    }

    private var snippetsDirty: Bool {
        SnippetStore.cleaned(savableSnippetDrafts.map(\.snippet)) != state.snippets
            || snippetDrafts.count != state.snippets.count
    }

    private var snippetIssues: [UUID: String] {
        let byIndex = SnippetDraftValidator.issues(
            for: snippetDrafts.map { (trigger: $0.trigger, expansion: $0.expansion) },
            glossary: state.glossaryEntries
        )
        var result: [UUID: String] = [:]
        for (index, issue) in byIndex where snippetDrafts.indices.contains(index) {
            result[snippetDrafts[index].id] = issue
        }
        return result
    }

    private var savableSnippetDrafts: [SnippetDraft] {
        snippetDrafts.filter { !SnippetDraftValidator.isBlank(trigger: $0.trigger, expansion: $0.expansion) }
    }

    /// X on a snippet: gone from the list and, when it was saved, from
    /// snippets.json right away. Other rows keep their unsaved edits.
    func deleteSnippetDraft(_ id: UUID) {
        snippetDrafts.removeAll { $0.id == id }
        if let remaining = WordsDeletion.snippets(afterDeleting: id, from: state.snippets) {
            onSaveSnippets(remaining)
        }
    }

    func resetSnippetDrafts() {
        snippetDrafts = state.snippets.map(SnippetDraft.init)
    }

    // MARK: - Import and export

    private func chooseWordsImport() {
        wordsShare = .idle
        guard let url = WordsFilePanels.chooseImportFile() else { return }
        do {
            wordsShare = .previewing(try PendingWordsImport.load(from: url))
        } catch {
            state.postFeedback(.error(L10n.tr("Import failed. %@", error.localizedDescription), topic: "words-import"), on: .words)
        }
    }

    private func applyWordsImport(_ pending: PendingWordsImport) {
        let plan = pending.plan(glossary: state.glossaryEntries, snippets: state.snippets)
        wordsShare = .idle
        guard plan.hasChanges else {
            state.postFeedback(.info(L10n.tr("Nothing new in %@.", pending.fileName), topic: "words-import"), on: .words)
            return
        }
        if plan.glossary != state.glossaryEntries {
            onSaveGlossary(plan.glossary)
        }
        if plan.snippets != state.snippets {
            onSaveSnippets(plan.snippets)
        }
        resetDrafts()
        resetSnippetDrafts()
        state.postFeedback(.success(WordsImportPreview.appliedMessage(for: plan), topic: "words-import"), on: .words)
    }

    private func exportWords(_ kind: WordsExportKind) {
        wordsShare = .idle
        guard let url = WordsFilePanels.chooseExportURL(for: kind) else { return }
        do {
            let data = try WordsExporter.data(kind, glossary: state.glossaryEntries, snippets: state.snippets)
            try data.write(to: url, options: .atomic)
            state.postFeedback(.success(L10n.tr("Exported to %@.", url.lastPathComponent), topic: "words-export"), on: .words)
        } catch {
            state.postFeedback(.error(L10n.tr("Export failed. %@", error.localizedDescription), topic: "words-export"), on: .words)
        }
    }
}

// MARK: - Rows and cards

struct BrutalSnippetRow: View {
    @Binding var draft: SnippetDraft
    var issue: String?
    let onDelete: () -> Void
    @FocusState private var phraseFocused: Bool

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    fieldCaption(L10n.tr("WHEN I SAY"))
                    BrutalField(label: L10n.tr("When I say"), placeholder: SnippetPlaceholders.trigger, text: $draft.trigger)
                        .focused($phraseFocused)
                }

                Button(action: onDelete) {
                    Text(L10n.tr("X"))
                        .brutalFont(size: 10, weight: .black, relativeTo: .caption)
                        .foregroundStyle(Brutal.contentOnRed)
                        .frame(width: 24, height: 24)
                        .background(Brutal.red)
                        .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 11)
                .help(L10n.tr("Delete this snippet"))
                .brutalInteractive(
                    label: L10n.tr("Delete snippet"),
                    hint: L10n.tr("Deletes this snippet right away"),
                    value: draft.trigger.isEmpty ? L10n.tr("Empty snippet") : draft.trigger,
                    hitExpansion: 10
                )
            }

            VStack(alignment: .leading, spacing: 2) {
                fieldCaption(L10n.tr("WRITE THIS"))
                TextField(L10n.tr("Write this"), text: $draft.expansion, prompt: Text(SnippetPlaceholders.expansion).foregroundStyle(Brutal.textTertiary), axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.plain)
                    .brutalFont(size: 11.5, weight: .semibold, design: .monospaced, relativeTo: .callout)
                    .foregroundStyle(Brutal.ink)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Brutal.field)
                    .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))
                    .focusEffectDisabled()
                    .brutalFocusRing()
                    .accessibilityLabel(Text(L10n.tr("Write this")))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let issue {
                Text(issue.uppercased())
                    .brutalFont(size: 8.5, weight: .black, relativeTo: .caption2)
                    .kerning(0.5)
                    .foregroundStyle(Brutal.dangerText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(Text(L10n.tr("Problem: %@", issue)))
            }
        }
        .padding(10)
        .background(Brutal.card)
        .overlay(Rectangle().strokeBorder(issue == nil ? Brutal.ink : Brutal.red, lineWidth: Brutal.border))
        .background(Rectangle().fill(Brutal.ink).offset(x: Brutal.drop, y: Brutal.drop))
        .onAppear {
            guard draft.wantsFocus else { return }
            draft.wantsFocus = false
            // Focus after the row is in the window, or the request is lost.
            DispatchQueue.main.async { phraseFocused = true }
        }
    }

    private func fieldCaption(_ text: String) -> some View {
        Text(text)
            .brutalFont(size: 7.5, weight: .black, relativeTo: .caption2)
            .kerning(0.8)
            .foregroundStyle(Brutal.textTertiary)
    }
}

/// Shows what an import adds before anything is saved.
struct WordsImportPreviewCard: View {
    let pending: PendingWordsImport
    let plan: WordsImportPlan
    let onPolicy: (SnippetConflictPolicy) -> Void
    let onCancel: () -> Void
    let onApply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.tr("IMPORT %@", pending.fileName.uppercased()))
                .brutalFont(size: 12, weight: .black, relativeTo: .headline)
                .kerning(0.8)
                .foregroundStyle(Brutal.ink)
                .lineLimit(2)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(WordsImportPreview.lines(for: plan, policy: pending.policy), id: \.self) { line in
                    Text(line)
                        .brutalFont(size: 10, weight: .black, relativeTo: .caption)
                        .kerning(0.5)
                        .foregroundStyle(Brutal.ink)
                }
            }
            .accessibilityElement(children: .combine)

            Text(L10n.tr("NOTHING IS REMOVED. YOUR SPELLINGS STAY. NEW WORDS AND \"SOUNDS LIKE\" SPELLINGS ARE ADDED."))
                .brutalFont(size: 8.5, weight: .bold, relativeTo: .caption2)
                .kerning(0.4)
                .foregroundStyle(Brutal.textSecondary)

            if plan.hasConflicts {
                HStack(spacing: 8) {
                    policyButton(.keepMine, title: L10n.tr("KEEP MINE"))
                    policyButton(.useImported, title: L10n.tr("USE NEW"))
                }
            }

            HStack(spacing: 10) {
                Button(L10n.tr("CANCEL"), action: onCancel)
                    .buttonStyle(BrutalTextButtonStyle(fill: Brutal.card, text: Brutal.ink))
                    .brutalInteractive(label: L10n.tr("Cancel import"), hint: L10n.tr("Closes the preview without changing anything"), hitExpansion: 5)

                Button(plan.hasChanges ? L10n.tr("IMPORT") : L10n.tr("NOTHING TO ADD"), action: onApply)
                    .buttonStyle(BrutalTextButtonStyle(
                        fill: plan.hasChanges ? Brutal.blue : Brutal.card,
                        text: plan.hasChanges ? Brutal.paper : Brutal.textSecondary
                    ))
                    .disabled(!plan.hasChanges)
                    .brutalInteractive(label: L10n.tr("Import"), hint: L10n.tr("Saves the merged words and snippets"), hitExpansion: 5)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brutal.card)
        .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))
        .background(Rectangle().fill(Brutal.ink).offset(x: Brutal.drop, y: Brutal.drop))
        .padding(.trailing, Brutal.drop)
    }

    private func policyButton(_ policy: SnippetConflictPolicy, title: String) -> some View {
        let selected = pending.policy == policy
        return Button(title) { onPolicy(policy) }
            .buttonStyle(BrutalTextButtonStyle(fill: selected ? Brutal.ink : Brutal.card, text: selected ? Brutal.paper : Brutal.ink))
            .brutalInteractive(
                label: policy == .keepMine ? L10n.tr("Keep my snippet text") : L10n.tr("Use the imported snippet text"),
                hint: L10n.tr("Decides clashing snippets"),
                value: selected ? L10n.tr("Selected") : L10n.tr("Not selected"),
                selected: selected,
                hitExpansion: 5
            )
    }
}

/// Picks the export format: everything as JSON, or words only as CSV.
struct WordsExportChooser: View {
    let snippetCount: Int
    let onExport: (WordsExportKind) -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(L10n.tr("EVERYTHING (.JSON)")) { onExport(.json) }
                .buttonStyle(BrutalTextButtonStyle(fill: Brutal.yellow, text: Brutal.contentOnYellow))
                .brutalInteractive(
                    label: L10n.tr("Export as JSON"),
                    hint: L10n.plural("Words and %lld snippets in one file. Never your history", snippetCount),
                    hitExpansion: 5
                )

            Button(L10n.tr("WORDS ONLY (.CSV)")) { onExport(.glossaryCSV) }
                .buttonStyle(BrutalTextButtonStyle(fill: Brutal.card, text: Brutal.ink))
                .brutalInteractive(label: L10n.tr("Export as CSV"), hint: L10n.tr("Words only, for a spreadsheet"), hitExpansion: 5)

            Button(L10n.tr("X"), action: onCancel)
                .buttonStyle(BrutalTextButtonStyle(fill: Brutal.card, text: Brutal.ink))
                .frame(width: 40)
                .brutalInteractive(label: L10n.tr("Close export"), hint: L10n.tr("Hides the export choices"), hitExpansion: 5)
        }
        .padding(.trailing, Brutal.drop)
    }
}
