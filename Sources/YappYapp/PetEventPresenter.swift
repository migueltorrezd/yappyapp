import Foundation

enum PetEventPresenter {
    static func statusMessages(for events: [PetEvent], activePet: String) -> [String] {
        events.map { statusMessage(for: $0, activePet: activePet) }
    }

    static func statusMessage(for event: PetEvent, activePet: String) -> String {
        switch event {
        case .milestone(let threshold):
            return L10n.tr("Milestone: %@ words dictated all time. Confetti earned.", "\(threshold)")
        case .questCompleted:
            return L10n.tr("Daily quest complete. Your pet earns double XP today.")
        case .levelUp(let level):
            let name = PetKind(rawValue: activePet)?.label ?? L10n.tr("Your pet")
            return L10n.tr("%@ reached level %@.", name, "\(level)")
        case .unlocked(let kind):
            return L10n.tr("New pet unlocked: %@. Find its egg in the Pet tab.", kind.label)
        case .hatched(let kind):
            return L10n.tr("The egg hatched. Say hi to your %@.", kind.label)
        case .streakSaved:
            return L10n.tr("You missed a day, but your pet covered for you. Streak saved.")
        }
    }
}
