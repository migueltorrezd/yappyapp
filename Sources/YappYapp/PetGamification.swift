import CoreGraphics
import Foundation

/// YA-31: one "Pet and quests" switch. Off means a plain dictation app: no
/// quests, no pet XP or messages, no jingles, no confetti, no walking pet and
/// no recap prompt. The plain counters (today, streak, totals) keep counting.
enum PetGamification {
    /// The pet that may walk on screen, or none while the switch is off.
    static func overlayPet(enabled: Bool, active: PetKind) -> PetKind {
        enabled ? active : .none
    }

    /// Reaction intensity after a dictation: 0 = silent, 1 = normal jump,
    /// 2 = big double jump, 3 = milestone storm.
    static func celebrationIntensity(enabled: Bool, hasEvents: Bool, wordCount: Int) -> Int {
        guard enabled else { return 0 }
        if hasEvents { return 3 }
        if wordCount <= 3 { return 0 }
        if wordCount >= 100 { return 2 }
        return 1
    }

    /// Status lines and whether the jingle plays for a batch of pet events.
    static func announcement(
        for events: [PetEvent],
        enabled: Bool,
        activePet: String,
        playSounds: Bool
    ) -> (messages: [String], playJingle: Bool) {
        guard enabled, !events.isEmpty else { return ([], false) }
        return (PetEventPresenter.statusMessages(for: events, activePet: activePet), playSounds)
    }
}

/// YA-37: the walking pet sits over the bottom of the popover. Every tab
/// reserves this much space so the pet never covers its last controls or
/// footnotes, and the overlay itself takes no clicks.
enum PetOverlayLayout {
    static let overlayHeight: CGFloat = 110

    /// The tallest sprite is 13 rows at 2pt, plus a hat, so a resting pet
    /// stays under 48pt from the window's bottom edge. The popover already
    /// pads 18pt, so tabs reserve the remaining 30pt.
    static let reservedBottom: CGFloat = 30

    static func bottomReserve(for pet: PetKind) -> CGFloat {
        pet == .none ? 0 : reservedBottom
    }
}

extension YappYappState {
    /// The pet allowed on screen right now (YA-31).
    var overlayPet: PetKind {
        PetGamification.overlayPet(enabled: config.petEnabled, active: activePet)
    }
}
