import Foundation
@preconcurrency import UserNotifications

@MainActor
protocol DeliveryNotifying: AnyObject {
    func post(_ notice: DeliveryNotice)
}

/// Missing feature 3: local notifications for dictations that failed or did
/// not land, with a COPY action. Permission is requested the first time a
/// notice is needed, not at launch. The COPY text stays in memory only and is
/// never put in the notification payload.
///
/// UNUserNotificationCenter aborts in unbundled processes (swift run, the
/// self-tests), so every call checks `isAvailable` first.
@MainActor
final class DeliveryNotifier: NSObject, DeliveryNotifying {
    static let categoryIdentifier = "app.yappyapp.delivery"
    static let copyActionIdentifier = "app.yappyapp.delivery.copy"
    static let noTextCategoryIdentifier = "app.yappyapp.delivery.plain"
    static let retainedCopyLimit = 10
    // LEARN-FROM-FIXES: "YappYapp learned a word" with an UNDO action.
    static let learnedCategoryIdentifier = "app.yappyapp.learned"
    static let undoLearnedActionIdentifier = "app.yappyapp.learned.undo"

    static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && !CommandLine.arguments.contains("--self-test")
    }

    /// Called with the remembered text when the user picks COPY.
    var onCopy: ((String, Bool) -> Void)?
    /// Called with the learn's notice id when the user picks UNDO.
    var onUndoLearned: ((UUID) -> Void)?

    private var categoriesRegistered = false
    private var copyTexts: [String: (text: String, sensitive: Bool)] = [:]
    private var copyOrder: [String] = []
    private var learnedNotices: [String: UUID] = [:]

    func post(_ notice: DeliveryNotice) {
        guard Self.isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        registerCategoriesIfNeeded(center)

        let identifier = UUID().uuidString
        if let text = notice.copyText {
            remember(text, sensitive: notice.copyIsSensitive, for: identifier)
        }

        let title = notice.title
        let body = notice.body
        let category = notice.copyText == nil ? Self.noTextCategoryIdentifier : Self.categoryIdentifier

        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            content.categoryIdentifier = category
            center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
        }
    }

    /// LEARN-FROM-FIXES: one banner per learned word, with UNDO. Only the
    /// notice id is remembered, never the field text.
    func postLearned(noticeID: UUID, title: String, body: String) {
        guard Self.isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        registerCategoriesIfNeeded(center)
        let identifier = UUID().uuidString
        let category = Self.learnedCategoryIdentifier
        learnedNotices[identifier] = noticeID
        if learnedNotices.count > Self.retainedCopyLimit, let oldest = learnedNotices.keys.first(where: { $0 != identifier }) {
            learnedNotices.removeValue(forKey: oldest)
        }
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.categoryIdentifier = category
            center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
        }
    }

    /// Text remembered for a notification's COPY action, oldest dropped first.
    func rememberedText(for identifier: String) -> String? {
        copyTexts[identifier]?.text
    }

    func remember(_ text: String, sensitive: Bool, for identifier: String) {
        copyTexts[identifier] = (text, sensitive)
        copyOrder.append(identifier)
        while copyOrder.count > Self.retainedCopyLimit {
            copyTexts.removeValue(forKey: copyOrder.removeFirst())
        }
    }

    func handleAction(_ actionIdentifier: String, notificationIdentifier: String) {
        if actionIdentifier == Self.undoLearnedActionIdentifier {
            if let noticeID = learnedNotices.removeValue(forKey: notificationIdentifier) {
                onUndoLearned?(noticeID)
            }
            return
        }
        guard actionIdentifier == Self.copyActionIdentifier,
              let entry = copyTexts[notificationIdentifier] else { return }
        onCopy?(entry.text, entry.sensitive)
    }

    private func registerCategoriesIfNeeded(_ center: UNUserNotificationCenter) {
        guard !categoriesRegistered else { return }
        categoriesRegistered = true
        let copy = UNNotificationAction(identifier: Self.copyActionIdentifier, title: L10n.tr("Copy"), options: [])
        let undo = UNNotificationAction(identifier: Self.undoLearnedActionIdentifier, title: LearnFromFixesCopy.notificationUndo, options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.categoryIdentifier, actions: [copy], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.learnedCategoryIdentifier, actions: [undo], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.noTextCategoryIdentifier, actions: [], intentIdentifiers: [])
        ])
    }
}

extension DeliveryNotifier: @preconcurrency UNUserNotificationCenterDelegate {
    /// Banners must show even while YappYapp is frontmost, which macOS
    /// otherwise suppresses for the foreground app.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        handleAction(response.actionIdentifier, notificationIdentifier: response.notification.request.identifier)
        completionHandler()
    }
}
