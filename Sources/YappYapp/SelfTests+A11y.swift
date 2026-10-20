#if DEBUG
import AppKit
import Foundation
import SwiftUI

// Self-tests owned by the "a11y" work track. Keep this track's new
// assertions here so parallel tracks never edit the same test lines.
extension SelfTests {
    static func a11yTrackTests() {
        a11yTypeScaleTests()
        a11yFocusRingTests()
        a11yAnnouncerTests()
        a11yContrastTests()
        a11yRenderTests()
    }

    // MARK: - Text size (YA-40)

    private static func a11yTypeScaleTests() {
        test("a11y.textSizeParsesConfigValues") {
            expectEqual(BrutalTextSize.allCases.map(\.rawValue), ["small", "default", "large", "larger"])
            expectEqual(BrutalTextSize.allCases.map(\.label), ["SMALL", "DEFAULT", "LARGE", "LARGER"])
            expectEqual(BrutalTextSize(configValue: "larger"), .larger)
            expectEqual(BrutalTextSize(configValue: "default"), .standard)
            expectEqual(BrutalTextSize(configValue: ""), .standard)
            expectEqual(BrutalTextSize(configValue: "HUGE"), .standard)
        }

        test("a11y.typeScaleKeepsDefaultsAndRaisesTheFloor") {
            // Shipped sizes at or above the floor stay byte-identical at DEFAULT.
            for base: CGFloat in [9, 10, 11.5, 14, 22] {
                expectEqual(BrutalTypeScale.pointSize(base: base, textSize: .standard), base)
            }
            // Compact 7.5-8.5pt labels render at the floor at every setting.
            for size in BrutalTextSize.allCases {
                for base: CGFloat in [7.5, 8, 8.5] {
                    let point = BrutalTypeScale.pointSize(base: base, textSize: size)
                    expect(point >= BrutalTypeScale.minimumPointSize, "\(base)pt at \(size.rawValue) rendered \(point)pt")
                }
            }
            expect(BrutalTypeScale.minimumPointSize >= 9, "label floor should be at least 9pt")
        }

        test("a11y.typeScaleGrowsMonotonicallyAndCaps") {
            let sizes = BrutalTextSize.allCases.map { BrutalTypeScale.pointSize(base: 12, textSize: $0) }
            expectEqual(sizes, sizes.sorted(), "text sizes should grow from SMALL to LARGER")
            expectEqual(Set(sizes).count, 4, "each text size should render a distinct body size")
            expectEqual(BrutalTypeScale.pointSize(base: 12, textSize: .larger), 15.5)

            let capped = BrutalTypeScale.pointSize(base: 10, textSize: .larger, dynamicTypeSize: .accessibility5)
            expectEqual(capped, 10 * BrutalTypeScale.maximumMultiplier)
            expectEqual(BrutalTypeScale.dynamicTypeMultiplier(.large), 1)
            expect(
                BrutalTypeScale.pointSize(base: 10, textSize: .standard, dynamicTypeSize: .accessibility5) > 10,
                "an explicit accessibility Dynamic Type size should still scale"
            )
        }

        test("a11y.textSizeConfigIsBackwardCompatible") {
            expectEqual(AppConfig.defaultConfig.textSize, "default")

            var config = AppConfig.defaultConfig
            config.textSize = "larger"
            let encoded = try JSONEncoder().encode(config)
            let decoded = try JSONDecoder().decode(AppConfig.self, from: encoded)
            expectEqual(decoded.textSize, "larger")

            // An older config.json without the key decodes at the default size.
            var legacy = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] ?? [:]
            legacy.removeValue(forKey: "textSize")
            let legacyData = try JSONSerialization.data(withJSONObject: legacy)
            let legacyDecoded = try JSONDecoder().decode(AppConfig.self, from: legacyData)
            expectEqual(legacyDecoded.textSize, "default")
            expectEqual(BrutalTextSize(configValue: legacyDecoded.textSize), .standard)
        }
    }

    // MARK: - Focus ring (YA-39)

    private static func a11yFocusRingTests() {
        test("a11y.focusRingIsHardAndKeyboardOnly") {
            expectEqual(BrutalFocusRing.lineWidth, Brutal.border)
            expect(BrutalFocusRing.outset > BrutalFocusRing.lineWidth, "ring should leave a paper gap around the control")
            // No macOS-blue frame anywhere in the window or popover.
            expectEqual(BrutalFocusRing.color, Brutal.ink)
            expect(BrutalFocusRing.color != Brutal.blue, "the focus ring is never blue")

            expect(BrutalFocusRing.isVisible(focused: true, focusedByPointer: false, keyboardNavigation: true), "keyboard focus paints the ring")
            expect(!BrutalFocusRing.isVisible(focused: true, focusedByPointer: true, keyboardNavigation: true), "pointer focus stays unpainted")
            expect(!BrutalFocusRing.isVisible(focused: false, focusedByPointer: false, keyboardNavigation: true), "unfocused controls stay unpainted")
            // Opening the window parks focus on the first tab; without the
            // Mac's keyboard navigation that focus is never painted.
            expect(!BrutalFocusRing.isVisible(focused: true, focusedByPointer: false, keyboardNavigation: false), "no ring without keyboard navigation")
        }

        test("a11y.focusRingDrawsOutsideTheControl") {
            // A 40pt control centered in 60pt: the ring sits 2-4pt outside it,
            // with a paper gap between control and ring.
            let view = ZStack {
                Brutal.paper
                Rectangle()
                    .fill(Brutal.ink)
                    .frame(width: 40, height: 40)
                    .overlay { BrutalFocusRingShape() }
            }
            guard let snapshot = renderPixelSnapshot(view, width: 60, height: 60),
                  let ring = a11yReferencePixel(BrutalFocusRing.color),
                  let paper = a11yReferencePixel(Brutal.paper) else {
                failures.append("[\(currentTest)] focus ring snapshot failed to render")
                return
            }
            // Control spans 10..<50. Ring occupies 6..<8, the inner edge band
            // 8..<10 is the paper gap.
            expect(a11yMatches(snapshot.pixel(x: 30, y: 6), ring), "ring top edge should be ink")
            expect(a11yMatches(snapshot.pixel(x: 6, y: 30), ring), "ring left edge should be ink")
            expect(a11yMatches(snapshot.pixel(x: 30, y: 9), paper), "ring should leave a paper gap")
            expect(a11yMatches(snapshot.pixel(x: 30, y: 3), paper), "ring should not glow beyond its edge")
        }
    }

    // MARK: - VoiceOver announcements (YA-39)

    private final class AnnouncementLog {
        var messages: [String] = []
    }

    private static func a11yAnnouncerTests() {
        test("a11y.announcerIsSilentInSelfTest") {
            expect(
                AccessibilityAnnouncer.defaultPoster(arguments: ["YappYapp", "--self-test"]) == nil,
                "self-test runs must never post accessibility announcements"
            )
            expect(
                AccessibilityAnnouncer.defaultPoster(arguments: ["YappYapp"]) != nil,
                "the running app should post announcements"
            )
        }

        test("a11y.announcerSpeaksPhaseChangesOnce") {
            let log = AnnouncementLog()
            let announcer = AccessibilityAnnouncer(poster: { log.messages.append($0) })

            announcer.announcePhase(.idle)
            announcer.announcePhase(.recording)
            announcer.announcePhase(.recording)
            announcer.announcePhase(.transcribing)
            announcer.announcePhase(.error("  Microphone unplugged  "))
            announcer.announcePhase(.error(""))
            announcer.announcePhase(.idle)
            announcer.announcePhase(.recording)

            expectEqual(log.messages, [
                "Listening.",
                "Transcribing.",
                "Needs attention. Microphone unplugged",
                "Needs attention.",
                "Listening."
            ])
        }

        test("a11y.announcerSpeaksPasteOutcomesWithoutRepeatingThePhase") {
            let log = AnnouncementLog()
            let announcer = AccessibilityAnnouncer(poster: { log.messages.append($0) })

            // AppDelegate.apply announces the outcome before the phase sink runs.
            let pasted = PasteStatusSnapshot(phase: .pasted, statusText: "Inserted into Notes.")
            announcer.announcePasteOutcome(pasted)
            announcer.announcePhase(.pasted)

            let failed = PasteStatusSnapshot(phase: .error("No text"), statusText: "Nothing was copied.")
            announcer.announcePasteOutcome(failed)
            announcer.announcePhase(.error("No text"))

            announcer.announcePasteOutcome(PasteStatusSnapshot(phase: .copied, statusText: "   "))

            expectEqual(log.messages, ["Inserted into Notes.", "Nothing was copied."])
            expectEqual(AccessibilityAnnouncer.message(for: .copied), nil)
            expectEqual(AccessibilityAnnouncer.message(for: .pasted), nil)
            expectEqual(AccessibilityAnnouncer.message(for: .idle), nil)
        }

        test("a11y.silentAnnouncerDropsMessages") {
            let announcer = AccessibilityAnnouncer(poster: nil)
            announcer.announcePhase(.recording)
            announcer.announce("Copied.")
            passed += 1
        }
    }

    // MARK: - Contrast on paper

    private static func a11yContrastTests() {
        test("a11y.textRolesMeetWCAGAAOnPaperAndField") {
            let backgrounds: [(String, Color)] = [("paper", Brutal.paper), ("card", Brutal.card), ("field", Brutal.field)]
            let foregrounds: [(String, Color)] = [
                ("primary", Brutal.textPrimary),
                ("secondary", Brutal.textSecondary),
                ("tertiary", Brutal.textTertiary),
                ("disabled", Brutal.textDisabled),
                ("danger", Brutal.dangerText),
                ("success", Brutal.successText),
                // Blue carries levels, durations and progress text on paper and card.
                ("blue", Brutal.blue)
            ]
            for (backgroundName, background) in backgrounds {
                for (foregroundName, foreground) in foregrounds {
                    let ratio = contrastRatio(foreground: foreground, background: background)
                    expect(
                        ratio >= 4.5,
                        "\(foregroundName) on \(backgroundName) contrast \(String(format: "%.2f", ratio)):1 is below 4.5:1"
                    )
                }
            }
            let onYellow = contrastRatio(foreground: Brutal.yellow, background: Brutal.ink)
            expect(onYellow >= 4.5, "yellow on ink contrast \(String(format: "%.2f", onYellow)):1 is below 4.5:1")
        }
    }

    // MARK: - Render pass (YA-41, YA-74)

    private static func a11yRenderTests() {
        test("a11y.renderPassFlattensScrollContainers") {
            // Without the flag ImageRenderer leaves ScrollView bodies blank;
            // renderImage sets it, so the tab body must draw ink.
            let tab = makeBrutalPopover(makeUIState()).settingsTab.background(Brutal.paper)
            guard let snapshot = renderPixelSnapshot(tab, width: 404, height: 420) else {
                failures.append("[\(currentTest)] settings tab failed to render")
                return
            }
            expect(a11yNonPaperCount(snapshot, rows: 0..<420) > 0, "flattened settings body should draw content")
        }

        test("a11y.everyTabBodyDrawsContentInKeyStates") {
            let states: [(String, YappYappState)] = [
                ("ready", makeUIState()),
                ("recording", makeUIState(phase: .recording)),
                ("transcribing", makeUIState(phase: .transcribing)),
                ("error", makeUIState(phase: .error("Microphone unplugged"))),
                ("downloading", makeUIState(downloads: ["small": 0.42, "parakeet-v3": 0.05])),
                ("managedOffline", {
                    let state = makeUIState(allowModelDownloads: false)
                    state.isModelReady = false
                    state.isAccessibilityTrusted = false
                    return state
                }()),
                ("starterChooser", makeUIState(starter: nil)),
                ("egg", makeUIState(starter: .crab, hatched: false))
            ]

            for (stateName, state) in states {
                let popover = makeBrutalPopover(state)
                let tabs: [(String, AnyView)] = [
                    ("home", AnyView(popover.homeTab)),
                    ("files", AnyView(popover.filesTab)),
                    ("models", AnyView(popover.modelsTab)),
                    ("words", AnyView(popover.wordsTab)),
                    ("pet", AnyView(popover.petTab)),
                    ("settings", AnyView(popover.settingsTab))
                ]
                for (tabName, tab) in tabs {
                    // 404 x 420 is the tab body area inside the 440 x 596 popover.
                    guard let snapshot = renderPixelSnapshot(tab.background(Brutal.paper), width: 404, height: 420) else {
                        failures.append("[\(currentTest)] \(stateName).\(tabName) failed to render")
                        continue
                    }
                    // Both halves must draw: a blank renderer, or one that
                    // shows only a header, fails here.
                    let top = a11yNonPaperCount(snapshot, rows: 0..<210)
                    let bottom = a11yNonPaperCount(snapshot, rows: 210..<420)
                    expect(top >= 2_000, "\(stateName).\(tabName) top of the tab body is blank (\(top) ink pixels)")
                    expect(bottom >= 2_000, "\(stateName).\(tabName) lower tab body is blank (\(bottom) ink pixels)")
                }
            }
        }

        test("a11y.popoverTabBodyDrawsContentInEveryPhase") {
            let phases: [CapturePhase] = [.idle, .recording, .transcribing, .copied, .pasted, .error("Microphone unplugged")]
            var fingerprints: [String: UInt64] = [:]
            for phase in phases {
                guard let snapshot = renderPixelSnapshot(makeBrutalPopover(makeUIState(phase: phase)), width: 440, height: 596) else {
                    failures.append("[\(currentTest)] popover \(phase.label) failed to render")
                    continue
                }
                fingerprints[phase.label] = snapshot.fingerprint
                // Below the header and tab bar, above the pet strip.
                let body = a11yNonPaperCount(snapshot, rows: 200..<480)
                expect(body >= 2_000, "popover \(phase.label) tab body is blank (\(body) ink pixels)")
            }
            expect(
                fingerprints["Ready"] != fingerprints["Listening"],
                "the record block should render differently while listening"
            )
        }

        test("a11y.textSizeChangesTheRenderedTabs") {
            let popover = makeBrutalPopover(makeUIState())
            var fingerprints: [UInt64] = []
            for size in BrutalTextSize.allCases {
                guard let snapshot = renderPixelSnapshot(
                    popover.settingsTab.background(Brutal.paper).environment(\.brutalTextSize, size),
                    width: 404,
                    height: 420
                ) else {
                    failures.append("[\(currentTest)] settings at \(size.rawValue) failed to render")
                    continue
                }
                fingerprints.append(snapshot.fingerprint)
            }
            expectEqual(Set(fingerprints).count, BrutalTextSize.allCases.count, "every text size should render differently")
        }

        test("a11y.textSizeRowRendersAllChoices") {
            let popover = makeBrutalPopover(makeUIState())
            guard let snapshot = renderPixelSnapshot(
                popover.textSizeRow.padding(4).background(Brutal.paper),
                width: 360,
                height: 60
            ) else {
                failures.append("[\(currentTest)] text size row failed to render")
                return
            }
            expect(a11yNonPaperCount(snapshot, rows: 0..<60) > 1_000, "text size chooser should draw its chips")
        }

        test("a11y.settingsSectionHeaderHasNoPaperHairline") {
            // The first section starts at the top of the flattened tab. Rows
            // 2..<4 right of the header label used to show paper between the
            // 2pt frame and the 4pt drop shadow.
            let tab = makeBrutalPopover(makeUIState()).settingsTab.background(Brutal.paper)
            guard let snapshot = renderPixelSnapshot(tab, width: 404, height: 120),
                  let paper = a11yReferencePixel(Brutal.paper) else {
                failures.append("[\(currentTest)] settings header failed to render")
                return
            }
            var paperPixels = 0
            for y in 0..<6 {
                for x in 200..<380 where a11yMatches(snapshot.pixel(x: x, y: y), paper) {
                    paperPixels += 1
                }
            }
            expectEqual(paperPixels, 0, "section header bar should be solid ink across its full width")
        }

        test("a11y.settingsCardHeaderHasNoPaperHairline") {
            // Every SETUP section, DICTATION included, draws its header through
            // BrutalSettingsCard; the 2026-10-16 gallery caught a section
            // without the YA-74 full-width bar.
            let section = BrutalSettingsCard(SetupSection.dictation.title) {
                ShortcutSettingsSection(settings: .constant(.default), isAccessibilityTrusted: true)
            }
                .padding(.trailing, 4)
                .fixedSize(horizontal: false, vertical: true)
                // Taller than the frame: pin the header to the top row.
                .frame(width: 404, height: 120, alignment: .top)
                .clipped()
                .background(Brutal.paper)
            guard let snapshot = renderPixelSnapshot(section, width: 404, height: 120),
                  let paper = a11yReferencePixel(Brutal.paper) else {
                failures.append("[\(currentTest)] section card header failed to render")
                return
            }
            var paperPixels = 0
            for y in 0..<6 {
                for x in 200..<380 where a11yMatches(snapshot.pixel(x: x, y: y), paper) {
                    paperPixels += 1
                }
            }
            expectEqual(paperPixels, 0, "the DICTATION header bar should be solid ink across its full width")
        }
    }

    // MARK: - Pixel helpers

    private static func a11yReferencePixel(_ color: Color) -> [UInt8]? {
        renderPixelSnapshot(color, width: 2, height: 2)?.pixel(x: 0, y: 0)
    }

    private static func a11yMatches(_ pixel: [UInt8], _ reference: [UInt8], tolerance: Int = 6) -> Bool {
        guard pixel.count == 4, reference.count == 4 else { return false }
        return zip(pixel, reference).allSatisfy { abs(Int($0) - Int($1)) <= tolerance }
    }

    /// Pixels in `rows` that differ from rendered paper: drawn content.
    private static func a11yNonPaperCount(_ snapshot: PixelSnapshot, rows: Range<Int>) -> Int {
        guard let paper = a11yReferencePixel(Brutal.paper) else { return 0 }
        var count = 0
        for y in rows where y < snapshot.height {
            for x in 0..<snapshot.width where !a11yMatches(snapshot.pixel(x: x, y: y), paper) {
                count += 1
            }
        }
        return count
    }
}
#endif
