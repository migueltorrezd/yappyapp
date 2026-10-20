import Foundation
import Testing
@testable import YappYapp

// SETUP-CONTROLS: the Setup files may only set type through the
// BrutalTextStyle roles and only draw choices through the shared controls,
// so the tab cannot drift back into several fonts and chip styles.

private let setupFiles = [
    "BrutalistSettingsTab.swift",
    "ShortcutSettingsSection.swift",
    "AppProfilesSettingsSection.swift",
    "CleanupSettingsControl.swift",
    "BrutalistAppLanguageControl.swift",
    "BrutalistTextSizeControl.swift",
    "BrutalSetupControls.swift"
]

/// The Setup part of a file. The MIC tab keycap row shares the shortcut file
/// but not the tab.
private func setupSource(_ name: String) throws -> String {
    let full = try fileSource(name)
    if let micRow = full.range(of: "struct ActiveShortcutKeys") {
        return String(full[..<micRow.lowerBound])
    }
    return full
}

private func fileSource(_ name: String) throws -> String {
    let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/YappYapp")
    return try String(contentsOf: sources.appendingPathComponent(name), encoding: .utf8)
}

@Test
func setupFilesSetTypeOnlyThroughTheTypeScale() throws {
    for name in setupFiles {
        let source = try setupSource(name)
        for banned in [".brutalFont(", ".font(", ".kerning(", "design: .monospaced"] {
            #expect(!source.contains(banned), "\(name) uses \(banned) instead of a BrutalTextStyle role")
        }
    }
}

@Test
func setupChoicesUseTheSharedControls() throws {
    let joined = try setupFiles.map(setupSource).joined(separator: "\n")
    #expect(!joined.contains("func chip("), "no file keeps its own chip style")
    #expect(!joined.contains("func hudChip("))
    #expect(!joined.contains("BrutalKey("), "shortcuts show in the field, not as keycaps")
    #expect(joined.range(of: #"(?<![A-Za-z])Slider\("#, options: .regularExpression) == nil, "the auto-stop slider is BrutalSlider")
    // MODE, DICTATE WITH ONE KEY, DICTATION LANGUAGE, CLEANUP, INDICATOR
    // POSITION, TEXT SIZE and the profile PASTE row.
    #expect(joined.components(separatedBy: "BrutalSegmented(").count - 1 >= 7)
    // APP LANGUAGE and the profile LANGUAGE, CLEANUP and MODEL rows.
    #expect(joined.components(separatedBy: "BrutalPicker(").count - 1 >= 3)
    #expect(!joined.contains("PUT MY CLIPBOARD BACK AFTER"))
}

// DROPDOWN-FLOAT: no dropdown opens inline any more. Every list floats
// through BrutalDropdown, so opening one never pushes the card down.
@Test
func everyDropdownFloatsInsteadOfOpeningInline() throws {
    let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/YappYapp")
    let names = try FileManager.default.contentsOfDirectory(atPath: sources.path).filter { $0.hasSuffix(".swift") }
    var dropdowns = 0
    for name in names {
        let source = try String(contentsOf: sources.appendingPathComponent(name), encoding: .utf8)
        #expect(!source.contains("BrutalMenuList"), "\(name) still opens a list inline")
        if name != "BrutalDropdown.swift" && name != "BrutalSetupControls.swift" {
            #expect(!source.contains("BrutalMenuRow("), "\(name) draws its own menu rows")
            #expect(!source.contains("BrutalDropdownField("), "\(name) builds its own dropdown")
        }
        dropdowns += source.components(separatedBy: "BrutalDropdown(").count - 1
    }
    // BrutalPicker, the Setup mic and ADD APP.
    #expect(dropdowns >= 3)
    let root = try String(contentsOf: sources.appendingPathComponent("BrutalistPopoverView.swift"), encoding: .utf8)
    #expect(root.contains(".brutalDropdownHost()"), "the window root hosts the floating lists")
}

@Test
func indicatorPositionOffersAllFivePlaces() {
    #expect(SetupChoices.indicatorPositions.map(\.value) == ["bottom", "top", "left", "right", "off"])
}

@Test
func clipboardAlwaysComesBack() throws {
    let old = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"restoreClipboardAfterPaste":false}"#.utf8))
    #expect(old.restoreClipboardAfterPaste)
    #expect(ClipboardInjector.shouldRestoreClipboard(after: .pastedBestEffort))
    #expect(!ClipboardInjector.shouldRestoreClipboard(after: .withheld(.secureInputActive)))
}

// SETUP-RHYTHM: one spacing scale for every section, set in
// BrutalSetupControls.swift, so captions read as part of their own row.

@Test
func rowsAreClearlyFurtherApartThanTheirParts() {
    // A caption sits 5pt under its control and 18pt above the next row.
    #expect(BrutalControl.rowSpacing >= 3 * BrutalControl.innerSpacing)
    #expect(BrutalControl.lineSpacing < BrutalControl.innerSpacing)
    // A group heading has more air above it than below it.
    #expect(BrutalControl.groupLead > 0)
    #expect(BrutalControl.headingTuck > 0 && BrutalControl.headingTuck < BrutalControl.rowSpacing)
    #expect(BrutalControl.rowSpacing + BrutalControl.groupLead > BrutalControl.rowSpacing - BrutalControl.headingTuck)
}

@Test
func setupSpacingComesFromTheSharedTokens() throws {
    // No one-off stack spacing or vertical padding in the Setup files: every
    // gap is a BrutalControl token. Spacing 0 (joined frames) is allowed.
    let literal = #"(VStack|LazyVStack)\([^)]*spacing:\s*[1-9]"#
    let padding = #"\.padding\(\.(top|bottom|vertical),\s*[0-9]"#
    for name in setupFiles where name != "BrutalSetupControls.swift" {
        let source = try setupSource(name)
        #expect(source.range(of: literal, options: .regularExpression) == nil, "\(name) sets a literal stack spacing")
        #expect(source.range(of: padding, options: .regularExpression) == nil, "\(name) pads rows by hand")
    }
}

@Test
func sectionsSplitTheirGroupsWithTheSharedBreak() throws {
    let tab = try setupSource("BrutalistSettingsTab.swift")
    // DICTATION, MICROPHONE, PASTING, INDICATOR AND SOUND and APP each have
    // more than one group.
    #expect(tab.components(separatedBy: "BrutalGroupBreak(").count - 1 >= 7)
    // Headed sections open with their first heading, without the extra air.
    #expect(tab.components(separatedBy: "first: true)").count - 1 == 2)
    let support = try fileSource("BrutalistSupportViews.swift")
    #expect(support.contains("BrutalGroupBreak()"), "HELP splits the report from the crash list")
}

@Test
func setupCaptionsAvoidJargon() {
    let captions = [
        LivePreviewPolicy.settingsNote(config: .defaultConfig),
        SpokenCommandCopy.settingsNote,
        AppProfileCopy.intro,
        AppProfileCopy.empty
    ] + ShortcutAction.allCases.map(\.detail) + RecordingMode.allCases.map(\.explanation)
    for caption in captions {
        for banned in ["AX", "HUD", "LLM", "Cmd+V", "staging", "·", "—"] {
            #expect(!caption.contains(banned), "\"\(caption)\" avoids \(banned)")
        }
    }
}
