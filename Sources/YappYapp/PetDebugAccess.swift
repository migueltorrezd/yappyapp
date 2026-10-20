import Foundation

/// Non-destructive pet/wardrobe override for UI and workflow debugging.
/// Persisted progression is never rewritten; callers present this derived copy
/// only while the explicit environment flag is enabled.
enum PetDebugAccess {
    static let environmentKey = "YAPPYAPP_DEBUG_UNLOCKS"

    /// YA-69: debug builds only. A release build ignores the variable, so a
    /// shipped app can never present unearned pets.
    static var isEnabled: Bool {
        isEnabled(environment: ProcessInfo.processInfo.environment, debugBuild: isDebugBuild)
    }

    static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    static func isEnabled(environment: [String: String], debugBuild: Bool) -> Bool {
        guard debugBuild, let rawValue = environment[environmentKey] else {
            return false
        }
        return ["1", "true", "yes", "on"].contains(rawValue.lowercased())
    }

    static func presented(_ persisted: PetStats, enabled: Bool = isEnabled) -> PetStats {
        guard enabled else { return persisted }

        var debug = persisted
        if debug.starter.isEmpty {
            debug.starter = PetKind.cat.rawValue
        }

        // Unlock every milestone path without inflating the visible lifetime
        // counters. These journey baselines exist only in the presented copy.
        debug.journeyStartWords = min(debug.journeyStartWords, debug.totalWords - 10_000)
        debug.journeyStartDictations = min(debug.journeyStartDictations, debug.totalDictations - 100)
        debug.journeyStartQuests = min(debug.journeyStartQuests, debug.questsCompletedTotal - 6)
        debug.journeyBestStreak = max(debug.journeyBestStreak, 5)

        let allAccessoryWords = (PetAccessory.halo.unlockLevel - 1) * 250
        for pet in PetKind.allCases where pet != .none {
            debug.wordsByPet[pet.rawValue] = max(debug.wordsByPet[pet.rawValue] ?? 0, allAccessoryWords)

            // Every debug pet is already hatched. A negative start is valid in
            // this in-memory copy when lifetime words are below the hatch goal.
            let hatchedStart = debug.totalWords - PetStats.hatchTarget
            debug.eggStartWords[pet.rawValue] = min(
                debug.eggStartWords[pet.rawValue] ?? hatchedStart,
                hatchedStart
            )
        }

        return debug
    }
}
