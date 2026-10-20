import Foundation

struct FeatureTip: Identifiable, Equatable {
    let id: String
    let title: String
    let body: String
}

enum FeatureTips {
    // L10N: computed so the tips follow the app language.
    static var items: [FeatureTip] {
        [
        // UX-WRITING: problem first, then where to fix it. No model or
        // engine names; settings are named as SETUP shows them.
        FeatureTip(
            id: "cleanup",
            title: L10n.tr("CLEANUP"),
            body: L10n.tr("Want tidier text? Pick Clean, Email, List or Notes under Cleanup in Setup. It runs on this Mac.")
        ),
        FeatureTip(
            id: "words",
            title: L10n.tr("YOUR WORDS"),
            body: L10n.tr("A name keeps coming out wrong? Add it in Words and YappYapp spells it your way.")
        ),
        FeatureTip(
            id: "instant-start",
            title: L10n.tr("INSTANT START"),
            body: L10n.tr("First word getting cut off? Turn on Instant start in Setup > Speed. The orange mic dot stays on.")
        ),
        FeatureTip(
            id: "shortcut",
            title: L10n.tr("SHORTCUT"),
            body: L10n.tr("Option Space works in any app. No need to open YappYapp first.")
        ),
        FeatureTip(
            id: "pets",
            title: L10n.tr("PET UNLOCKS"),
            body: L10n.tr("Dictate more words to hatch pets, unlock accessories, and grow your streak.")
        )
        ]
    }

    static func randomIndex() -> Int {
        guard !items.isEmpty else { return 0 }
        return Int.random(in: 0..<items.count)
    }

    /// YA-31: with Pet and quests off, the pet tip never shows.
    static func tip(at index: Int, petEnabled: Bool = true) -> FeatureTip {
        let pool = petEnabled ? items : items.filter { $0.id != "pets" }
        guard !pool.isEmpty else {
            return FeatureTip(id: "empty", title: L10n.tr("TIPS"), body: "")
        }
        let safeIndex = ((index % pool.count) + pool.count) % pool.count
        return pool[safeIndex]
    }

    static func nextIndex(after index: Int) -> Int {
        guard !items.isEmpty else { return 0 }
        return (index + 1) % items.count
    }
}
