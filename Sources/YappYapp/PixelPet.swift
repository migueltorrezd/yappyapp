import SwiftUI

// Pixel pets that live along the bottom edge of the popover: they sleep when
// the app is idle, stay awake for a while after a dictation, walk while you
// dictate (faster when you speak louder), sit while Whisper thinks, and jump
// with hearts and confetti when the transcript lands.

enum PetKind: String, CaseIterable, Identifiable {
    case none
    case cat
    case dog
    case ghost
    case penguin
    case fox
    case frog
    case crab
    case robot
    case dino
    case duck
    case snail
    case otter
    case dragon
    case unicorn
    case clawd

    var id: String { rawValue }

    /// The three Pokémon-style starters offered on first launch.
    static let starters: [PetKind] = [.cat, .dog, .crab]

    var label: String {
        switch self {
        case .none: L10n.tr("None")
        case .cat: L10n.tr("Cat")
        case .dog: L10n.tr("Dog")
        case .ghost: L10n.tr("Ghost")
        case .penguin: L10n.tr("Penguin")
        case .fox: L10n.tr("Fox")
        case .frog: L10n.tr("Frog")
        case .crab: L10n.tr("Crab")
        case .robot: L10n.tr("Robot")
        case .dino: L10n.tr("Dino")
        case .duck: L10n.tr("Duck")
        case .snail: L10n.tr("Snail")
        case .otter: L10n.tr("Otter")
        case .dragon: L10n.tr("Dragon")
        case .unicorn: L10n.tr("Unicorn")
        case .clawd: "Clawd"
        }
    }

    /// Pokémon rules: everything except your starter must be earned.
    var requiresUnlock: Bool {
        self != .none
    }

    /// YA-32: derived from the same requirement table isUnlocked uses.
    var unlockRequirementText: String? {
        unlockRequirement?.text
    }
}
enum PetFrame: CaseIterable {
    case walkA, walkB, sit, sleep
}

enum PetGait {
    case walk
    case float
    case hop
}
