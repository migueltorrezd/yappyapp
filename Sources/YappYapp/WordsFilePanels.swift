import AppKit
import UniformTypeIdentifiers

/// SNIPPETS: the open and save panels for sharing words. Only the WORDS tab
/// buttons call these; self-tests drive WordsImportParser and WordsExporter
/// directly and never open a panel.
@MainActor
enum WordsFilePanels {
    /// Asks for a words file to import. Nil when the user cancels.
    static func chooseImportFile() -> URL? {
        let panel = NSOpenPanel()
        panel.title = L10n.tr("Import words")
        panel.prompt = L10n.tr("Preview")
        panel.message = L10n.tr("Pick a YappYapp words file (.json) or a glossary CSV.")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.json, .commaSeparatedText]
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Asks where to save an export. Nil when the user cancels.
    static func chooseExportURL(for kind: WordsExportKind) -> URL? {
        let panel = NSSavePanel()
        panel.title = kind == .json ? L10n.tr("Export words and snippets") : L10n.tr("Export words as CSV")
        panel.prompt = L10n.tr("Export")
        panel.message = kind == .json
            ? L10n.tr("Words and snippets only. Never your history.")
            : L10n.tr("Words only. Pick EVERYTHING (.JSON) to include snippets.")
        panel.nameFieldStringValue = kind.suggestedFileName
        panel.allowedContentTypes = [kind == .json ? .json : .commaSeparatedText]
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// A file picked for import, parsed and merged, waiting for the user to confirm.
struct PendingWordsImport: Equatable {
    let fileName: String
    let payload: WordsImportPayload
    var policy: SnippetConflictPolicy = .keepMine

    func plan(glossary: [GlossaryEntry], snippets: [Snippet]) -> WordsImportPlan {
        WordsImportMerger.plan(payload: payload, glossary: glossary, snippets: snippets, conflictPolicy: policy)
    }

    /// Reads and parses `url`. Throws a plain-language error for the tab.
    static func load(from url: URL) throws -> PendingWordsImport {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attributes?[.size] as? Int, size > WordsFileFormat.maximumBytes {
            throw WordsImportError.tooLarge
        }
        let data = try Data(contentsOf: url)
        let payload = try WordsImportParser.parse(data: data, fileExtension: url.pathExtension)
        return PendingWordsImport(fileName: url.lastPathComponent, payload: payload)
    }
}
