import Foundation
import ServiceManagement

// LOGIN-ITEM-APPROVAL (YA-60): SMAppService.register() can succeed while macOS
// still holds the item for approval. Report that honestly and offer the way to
// System Settings instead of claiming YappYapp will start at login.

enum LoginItemStatus: Equatable, Sendable {
    case enabled
    case notRegistered
    case requiresApproval
    case notFound

    init(_ status: SMAppService.Status) {
        switch status {
        case .enabled:
            self = .enabled
        case .requiresApproval:
            self = .requiresApproval
        case .notFound:
            self = .notFound
        case .notRegistered:
            self = .notRegistered
        @unknown default:
            self = .notRegistered
        }
    }
}

struct LaunchAtLoginOutcome: Equatable, Sendable {
    let statusText: String?
    let isEnabled: Bool
    let needsApproval: Bool
}

enum LaunchAtLoginPresenter {
    static var needsApprovalLabel: String { L10n.tr("Allow it in System Settings.") }
    static var openLoginItemsTitle: String { L10n.tr("OPEN LOGIN ITEMS") }
    static var needsApprovalStatus: String { L10n.tr("Almost there. Allow YappYapp in System Settings > General > Login Items.") }
    static var enabledStatus: String { L10n.tr("YappYapp will start automatically at login.") }
    static var disabledStatus: String { L10n.tr("YappYapp will no longer start at login.") }
    static var notAddedStatus: String { L10n.tr("macOS didn't add YappYapp. Try again, or add it in System Settings > General > Login Items.") }

    /// After the user flips START AT LOGIN. `errorDescription` is the
    /// register/unregister error, if any.
    static func outcome(
        requestedEnabled: Bool,
        status: LoginItemStatus,
        errorDescription: String?
    ) -> LaunchAtLoginOutcome {
        let needsApproval = status == .requiresApproval
        let isEnabled = status == .enabled

        let text: String
        if requestedEnabled && needsApproval {
            text = needsApprovalStatus
        } else if let errorDescription {
            text = L10n.tr("Couldn't change Start at Login. %@", errorDescription)
        } else if requestedEnabled {
            text = isEnabled ? enabledStatus : notAddedStatus
        } else {
            text = disabledStatus
        }

        return LaunchAtLoginOutcome(statusText: text, isEnabled: isEnabled, needsApproval: needsApproval)
    }

    /// YA-38: the outcome as SETUP tab feedback. Approval needed is a nudge,
    /// a failed or ignored change is an error that stays until dismissed.
    static func feedback(
        for outcome: LaunchAtLoginOutcome,
        requestedEnabled: Bool,
        errorDescription: String?
    ) -> TabFeedback? {
        guard let text = outcome.statusText else { return nil }
        if errorDescription != nil || (requestedEnabled && !outcome.isEnabled && !outcome.needsApproval) {
            return .error(text, topic: "login-item")
        }
        if outcome.needsApproval {
            return TabFeedback(text, tone: .info, topic: "login-item")
        }
        return .success(text, topic: "login-item")
    }

    /// Passive refresh (launch, readiness poll): no status line.
    static func refreshed(status: LoginItemStatus) -> LaunchAtLoginOutcome {
        LaunchAtLoginOutcome(
            statusText: nil,
            isEnabled: status == .enabled,
            needsApproval: status == .requiresApproval
        )
    }
}

enum LaunchAtLogin {
    static var currentStatus: LoginItemStatus {
        LoginItemStatus(SMAppService.mainApp.status)
    }

    /// Opens System Settings > General > Login Items.
    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
