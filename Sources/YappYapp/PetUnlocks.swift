import Foundation

/// What a locked pet is waiting for. Every journey metric counts from the
/// moment the starter was chosen, never from lifetime history (YA-32), so the
/// copy says so and the Pet tab shows real progress such as 120/500.
enum PetUnlockMetric: Equatable {
    case journeyWords
    case journeyDictations
    case journeyBestStreak
    case journeyQuests
    case anyPetLevel
}

struct PetUnlockRequirement: Equatable {
    let metric: PetUnlockMetric
    let target: Int

    var text: String {
        let amount = PetUnlockRequirement.grouped(target)
        switch metric {
        case .journeyWords: return L10n.tr("%@ words since your first pet", amount)
        case .journeyDictations: return L10n.tr("%@ dictations since your first pet", amount)
        case .journeyBestStreak: return L10n.tr("%@ day streak since your first pet", amount)
        case .journeyQuests: return L10n.tr("%@ daily quests since your first pet", amount)
        case .anyPetLevel: return L10n.tr("Any pet at level %@", amount)
        }
    }

    func current(in stats: PetStats) -> Int {
        switch metric {
        case .journeyWords: stats.journeyWords
        case .journeyDictations: stats.journeyDictations
        case .journeyBestStreak: stats.journeyBestStreak
        case .journeyQuests: stats.journeyQuests
        case .anyPetLevel: stats.maxPetLevel
        }
    }

    func isMet(in stats: PetStats) -> Bool {
        current(in: stats) >= target
    }

    /// "120/500", clamped at the target.
    func progressText(in stats: PetStats) -> String {
        let shown = min(max(0, current(in: stats)), target)
        return "\(PetUnlockRequirement.grouped(shown))/\(PetUnlockRequirement.grouped(target))"
    }

    /// "10,000": fixed comma grouping, matching the rest of the Pet tab copy.
    static func grouped(_ value: Int) -> String {
        let digits = String(abs(value))
        var result = ""
        for (index, character) in digits.enumerated() {
            if index > 0, (digits.count - index) % 3 == 0 {
                result.append(",")
            }
            result.append(character)
        }
        return value < 0 ? "-" + result : result
    }
}

extension PetKind {
    var unlockRequirement: PetUnlockRequirement? {
        switch self {
        case .none: nil
        case .cat, .dog, .crab: PetUnlockRequirement(metric: .anyPetLevel, target: 6)
        case .ghost: PetUnlockRequirement(metric: .journeyWords, target: 500)
        case .fox: PetUnlockRequirement(metric: .journeyDictations, target: 25)
        case .penguin: PetUnlockRequirement(metric: .journeyBestStreak, target: 3)
        case .robot: PetUnlockRequirement(metric: .journeyWords, target: 1_500)
        case .frog: PetUnlockRequirement(metric: .journeyQuests, target: 3)
        case .duck: PetUnlockRequirement(metric: .journeyDictations, target: 100)
        case .dino: PetUnlockRequirement(metric: .journeyWords, target: 2_500)
        case .snail: PetUnlockRequirement(metric: .journeyBestStreak, target: 5)
        case .otter: PetUnlockRequirement(metric: .journeyQuests, target: 6)
        case .dragon: PetUnlockRequirement(metric: .journeyWords, target: 10_000)
        case .unicorn: PetUnlockRequirement(metric: .anyPetLevel, target: 10)
        case .clawd: PetUnlockRequirement(metric: .journeyWords, target: 5_000)
        }
    }
}
