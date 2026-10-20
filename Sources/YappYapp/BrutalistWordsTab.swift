import SwiftUI

extension BrutalistPopoverView {
    // MARK: - Words

    // SNIPPETS: the WORDS list; wordsTab (BrutalistSnippetsViews.swift) wraps it.
    var glossaryPane: some View {
        VStack(spacing: 10) {
            Text(L10n.tr("NAMES, CLIENTS, ACRONYMS. \"WRITE IT AS\" IS YOUR SPELLING. \"SOUNDS LIKE\" IS WHAT YAPPYAPP GETS WRONG. PRESS SAVE WORDS TO APPLY."))
                .brutalFont(size: 10, weight: .black, relativeTo: .caption)
                .kerning(0.6)
                .foregroundStyle(Brutal.ink)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Brutal.yellow)
                .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))

            BrutalScroll {
                VStack(spacing: 10) {
                    // YA-36: new rows go on top, next to this button, and take focus.
                    Button {
                        addGlossaryDraft(variantsText: "")
                    } label: {
                        Text(L10n.tr("+ ADD A WORD"))
                            .brutalFont(size: 11, weight: .black, relativeTo: .callout)
                            .kerning(0.8)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 34)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(BrutalButtonStyle(fill: Brutal.card))
                    .brutalInteractive(
                        label: L10n.tr("Add a word"),
                        hint: L10n.tr("Adds a new word"),
                        hitExpansion: 5
                    )

                    ForEach($glossaryDrafts) { $entry in
                        BrutalGlossaryRow(
                            entry: $entry,
                            issue: glossaryIssues[entry.id],
                            autoFocus: entry.id == focusedGlossaryDraftID
                        ) {
                            deleteGlossaryDraft(entry.id)
                        }
                    }
                }
                .padding(.bottom, Brutal.drop)
                .padding(.trailing, Brutal.drop)
            }
            .scrollIndicators(.never)

            if glossaryDirty {
                HStack(spacing: 10) {
                    Button(L10n.tr("REVERT")) {
                        resetDrafts()
                    }
                    .buttonStyle(BrutalTextButtonStyle(fill: Brutal.card, text: Brutal.ink))
                    .brutalInteractive(
                        label: L10n.tr("Revert word changes"),
                        hint: L10n.tr("Goes back to your saved words"),
                        hitExpansion: 5
                    )

                    // YA-36: rows are never dropped silently. A row with a
                    // problem shows it inline and blocks saving; a row left
                    // completely empty is simply not saved.
                    Button(glossaryIssues.isEmpty ? L10n.tr("SAVE WORDS") : L10n.tr("FIX MARKED WORDS")) {
                        onSaveGlossary(savableGlossaryDrafts.map(\.entry))
                        focusedGlossaryDraftID = nil
                        resetDrafts()
                    }
                    .buttonStyle(BrutalTextButtonStyle(
                        fill: glossaryIssues.isEmpty ? Brutal.blue : Brutal.card,
                        text: glossaryIssues.isEmpty ? Brutal.paper : Brutal.dangerText
                    ))
                    .disabled(!glossaryIssues.isEmpty)
                    .brutalInteractive(
                        label: L10n.tr("Save words"),
                        hint: glossaryIssues.isEmpty
                            ? L10n.plural("Saves %lld words", savableGlossaryDrafts.count)
                            : L10n.tr("Fix the marked words first"),
                        value: L10n.plural("%lld words", savableGlossaryDrafts.count),
                        hitExpansion: 5
                    )
                }
            }
        }
    }

    private var glossaryDirty: Bool {
        glossaryDrafts.map(\.entry) != state.glossaryEntries
    }

    /// YA-36: the problem with each row, keyed by draft id.
    private var glossaryIssues: [UUID: String] {
        let byIndex = GlossaryDraftValidator.issues(
            for: glossaryDrafts.map { (canonical: $0.canonical, variantsText: $0.variantsText) }
        )
        var result: [UUID: String] = [:]
        for (index, issue) in byIndex where glossaryDrafts.indices.contains(index) {
            result[glossaryDrafts[index].id] = issue
        }
        return result
    }

    var savableGlossaryDrafts: [GlossaryEntryDraft] {
        glossaryDrafts.filter {
            !GlossaryDraftValidator.isBlank(canonical: $0.canonical, variantsText: $0.variantsText)
        }
    }

    /// X on a word: the row goes, and a saved word is deleted on the spot
    /// so every count and the next dictation follow. Other rows keep their
    /// unsaved edits.
    func deleteGlossaryDraft(_ id: UUID) {
        guard let draft = glossaryDrafts.first(where: { $0.id == id }) else { return }
        glossaryDrafts.removeAll { $0.id == id }
        if focusedGlossaryDraftID == id {
            focusedGlossaryDraftID = nil
        }
        if let remaining = WordsDeletion.glossary(afterDeleting: draft.savedCanonical, from: state.glossaryEntries) {
            onSaveGlossary(remaining)
        }
    }

    /// YA-36: adds a row at the top of the list and focuses its spelling.
    /// Used by "+ ADD A WORD".
    func addGlossaryDraft(variantsText: String) {
        let draft = GlossaryEntryDraft(canonical: "", variantsText: variantsText, notes: "")
        glossaryDrafts.insert(draft, at: 0)
        focusedGlossaryDraftID = draft.id
    }
private struct BrutalGlossaryRow: View {
    @Binding var entry: GlossaryEntryDraft
    var issue: String?
    var autoFocus = false
    let onDelete: () -> Void
    @FocusState private var spellingFocused: Bool

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(L10n.tr("WRITE IT AS"))
                            .brutalFont(size: 7.5, weight: .black, relativeTo: .caption2)
                            .kerning(0.8)
                            .foregroundStyle(Brutal.textTertiary)
                        // LEARN-FROM-FIXES: words YappYapp learned from a fix.
                        if entry.showsLearnedMark {
                            LearnedTag()
                        }
                    }

                    BrutalField(label: L10n.tr("Write it as"), placeholder: GlossaryPlaceholders.writeItAs, text: $entry.canonical)
                        .focused($spellingFocused)
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
                .help(L10n.tr("Delete this word"))
                .brutalInteractive(
                    label: L10n.tr("Delete word"),
                    hint: L10n.tr("Deletes this word right away"),
                    value: entry.canonical.isEmpty ? L10n.tr("Empty word") : entry.canonical,
                    hitExpansion: 10
                )
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.tr("SOUNDS LIKE"))
                    .brutalFont(size: 7.5, weight: .black, relativeTo: .caption2)
                    .kerning(0.8)
                    .foregroundStyle(Brutal.textTertiary)

                // YA-52: misheard spellings only. A real word here ("génial")
                // would teach users to rewrite ordinary sentences.
                BrutalField(label: L10n.tr("Sounds like"), placeholder: GlossaryPlaceholders.soundsLike, text: $entry.variantsText)
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
            guard autoFocus else { return }
            // Focus after the row is in the window, or the request is lost.
            DispatchQueue.main.async { spellingFocused = true }
        }
    }
}
}

/// LEARN-FROM-FIXES: the small mark on a word YappYapp learned by itself.
struct LearnedTag: View {
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "sparkles")
                .font(.system(size: 7, weight: .black))
                .accessibilityHidden(true)
            Text(LearnFromFixesCopy.learnedTag)
                .brutalFont(size: 7.5, weight: .black, relativeTo: .caption2)
                .kerning(0.8)
        }
        .foregroundStyle(Brutal.ink)
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(Brutal.yellow)
        .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: 1))
        .help(LearnFromFixesCopy.learnedTagHelp)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(LearnFromFixesCopy.learnedTagHelp))
    }
}
