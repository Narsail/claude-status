import AppKit
import Foundation
import UserNotifications

/// Wraps `UNUserNotificationCenter` to alert the user when a Claude Code
/// session needs their input.
///
/// Authorization is requested lazily — the first time we try to deliver a
/// notification we ensure we have (or have asked for) authorization. Tapping a
/// notification fires the existing `claude-status://session/<id>` deep link so
/// the AppDelegate's URL handler can focus the session's host app.
@MainActor
final class NotificationManager: NSObject {

    static let shared = NotificationManager()

    /// User-facing toggle. Mirrored to UserDefaults so it survives relaunches.
    static let enabledDefaultsKey = "notificationsEnabled"
    /// Default is on — the user explicitly opted into building this, so respect that.
    static let enabledDefault = true

    private static let waitingCategoryId = "session.waiting"
    private static let focusActionId = "focus"
    nonisolated static let sessionIdKey = "sessionId"

    /// Tracks our authorization status to avoid repeated requests.
    private var didRequestAuthorization = false

    /// Resolves a session ID to the deep-link URL it should open when tapped.
    /// Wired by AppDelegate so this class stays UI-free.
    var deepLinkURLForSessionId: ((String) -> URL?)?

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        registerCategories()
    }

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledDefaultsKey) == nil
            ? Self.enabledDefault
            : UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey)
    }

    /// Requests notification authorization once. Safe to call repeatedly.
    func requestAuthorizationIfNeeded() {
        guard !didRequestAuthorization else { return }
        didRequestAuthorization = true
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]
        ) { granted, error in
            if let error {
                NSLog("Claude Status: notification auth error: %@", error.localizedDescription)
            } else {
                NSLog("Claude Status: notification auth granted=%@", granted ? "yes" : "no")
            }
        }
    }

    /// Delivers a one-shot test notification so the user can confirm the system
    /// is configured correctly without having to wait for a real Waiting state.
    func sendTestNotification() {
        requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = "Claude Status — test"
        content.body = "If you see this, notifications are working."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "test.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                NSLog("Claude Status: test notification add failed: %@", error.localizedDescription)
            }
        }
    }

    /// Handles a state transition from `SessionMonitor`. Fires a notification
    /// when a session newly enters the Waiting state.
    func handle(transition: SessionTransition) {
        guard isEnabled else { return }
        guard transition.to == .waiting, transition.from != .waiting else { return }
        deliverWaitingNotification(for: transition.session)
    }

    // MARK: - Delivery

    private func deliverWaitingNotification(for session: ClaudeSession) {
        requestAuthorizationIfNeeded()

        let content = UNMutableNotificationContent()
        let displayName = session.sessionName ?? session.projectName
        content.title = "\(displayName) needs your input"
        content.subtitle = session.source.label
        if !session.activity.isEmpty {
            content.body = session.activity
        }
        content.sound = .default
        content.categoryIdentifier = Self.waitingCategoryId
        content.userInfo = [Self.sessionIdKey: session.sessionId]
        // Coalesce repeats for the same session — newer waiting state overrides older.
        content.threadIdentifier = session.sessionId

        let request = UNNotificationRequest(
            identifier: "waiting.\(session.sessionId)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                NSLog("Claude Status: waiting notification add failed: %@", error.localizedDescription)
            }
        }
    }

    // MARK: - Categories

    private func registerCategories() {
        let focusAction = UNNotificationAction(
            identifier: Self.focusActionId,
            title: "Focus Session",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: Self.waitingCategoryId,
            actions: [focusAction],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }
}

extension NotificationManager: UNUserNotificationCenterDelegate {

    /// Show notifications even when our app is "foregrounded" (status bar item).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// User tapped the notification (or hit the Focus action). Open the deep
    /// link so AppDelegate's URL handler focuses the session's host app.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let sessionId = userInfo[NotificationManager.sessionIdKey] as? String
        completionHandler()
        guard let sessionId else { return }
        Task { @MainActor in
            if let url = NotificationManager.shared.deepLinkURLForSessionId?(sessionId) {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
