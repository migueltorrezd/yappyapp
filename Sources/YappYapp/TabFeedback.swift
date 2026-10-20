import Foundation

// YA-38: feedback lands on the tab where the action happened, and errors
// stick. A routine success ("Setup saved.") never hides an earlier error
// unless it reports that the same failing thing now works.

struct TabFeedback: Equatable, Identifiable {
    enum Tone: Equatable {
        case success
        case info
        case error
    }

    let id: UUID
    let text: String
    let tone: Tone
    /// What the message is about ("save", "login-item", "download.<id>").
    /// A success only clears an error with the same topic.
    let topic: String

    init(_ text: String, tone: Tone, topic: String, id: UUID = UUID()) {
        self.id = id
        self.text = text
        self.tone = tone
        self.topic = topic
    }

    static func success(_ text: String, topic: String) -> TabFeedback {
        TabFeedback(text, tone: .success, topic: topic)
    }

    static func info(_ text: String, topic: String) -> TabFeedback {
        TabFeedback(text, tone: .info, topic: topic)
    }

    static func error(_ text: String, topic: String) -> TabFeedback {
        TabFeedback(text, tone: .error, topic: topic)
    }

    var isError: Bool { tone == .error }

    /// Successes and notes fade on their own; errors wait for the user.
    var autoDismissAfter: TimeInterval? {
        isError ? nil : 4.0
    }
}

enum TabFeedbackPolicy {
    /// What the tab should show after `incoming` is posted on top of
    /// `existing`.
    static func merge(existing: TabFeedback?, incoming: TabFeedback) -> TabFeedback {
        guard let existing, existing.isError else { return incoming }
        if incoming.isError || incoming.topic == existing.topic {
            return incoming
        }
        return existing
    }

    static func post(
        _ feedback: TabFeedback,
        to tab: BrutalTab,
        in current: [BrutalTab: TabFeedback]
    ) -> [BrutalTab: TabFeedback] {
        var updated = current
        updated[tab] = merge(existing: current[tab], incoming: feedback)
        return updated
    }

    /// Clears an auto-dismissing entry only if it is still the one that was
    /// posted, so a newer message is never wiped by an older timer.
    static func expire(
        _ id: UUID,
        on tab: BrutalTab,
        in current: [BrutalTab: TabFeedback]
    ) -> [BrutalTab: TabFeedback] {
        guard current[tab]?.id == id, current[tab]?.isError == false else { return current }
        var updated = current
        updated[tab] = nil
        return updated
    }

    /// The user closed the message by hand.
    static func dismiss(
        on tab: BrutalTab,
        in current: [BrutalTab: TabFeedback]
    ) -> [BrutalTab: TabFeedback] {
        var updated = current
        updated[tab] = nil
        return updated
    }
}

// YA-38: the MIC status line is shared by every action. A routine success
// must not replace an error the user has not seen through yet.
enum StatusLinePolicy {
    static func shouldReplace(currentPhase: CapturePhase, withRoutineSuccess: Bool) -> Bool {
        guard withRoutineSuccess else { return true }
        if case .error = currentPhase { return false }
        return true
    }
}

extension YappYappState {
    /// Posts `feedback` on `tab`, keeping sticky errors, and schedules the
    /// fade for successes. Main thread only, like every other state write.
    @MainActor
    func postFeedback(_ feedback: TabFeedback, on tab: BrutalTab) {
        tabFeedback = TabFeedbackPolicy.post(feedback, to: tab, in: tabFeedback)
        guard let delay = feedback.autoDismissAfter, tabFeedback[tab]?.id == feedback.id else { return }
        let id = feedback.id
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.tabFeedback = TabFeedbackPolicy.expire(id, on: tab, in: self.tabFeedback)
            }
        }
    }

    @MainActor
    func dismissFeedback(on tab: BrutalTab) {
        tabFeedback = TabFeedbackPolicy.dismiss(on: tab, in: tabFeedback)
    }
}
