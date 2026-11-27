import UserNotifications

/// Notification Center messages for when Face Unlock needs the password or Touch ID.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private static let category = "authentication"
    private static let confirm = "confirm"
    private static let scheduled = "expiry"
    private let center = UNUserNotificationCenter.current()
    var onConfirm: (@MainActor () -> Void)?
    /// False when the notch should present this instead of a banner.
    var showsBanner: (@MainActor () -> Bool)?

    func activate() {
        center.delegate = self
        let action = UNNotificationAction(identifier: Self.confirm, title: "Use Touch ID", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.category, actions: [action], intentIdentifiers: []),
        ])
    }

    func requestPermission() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func isAllowed() async -> Bool { await center.notificationSettings().authorizationStatus == .authorized }

    private func content(_ body: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Face Unlock Paused"
        content.body = body
        content.sound = .default
        content.categoryIdentifier = Self.category
        return content
    }

    /// Fires at `date` even if the Mac has been idle; replaces any earlier schedule.
    func schedule(at date: Date) {
        let delay = date.timeIntervalSinceNow
        guard delay > 1 else { return }
        center.add(UNNotificationRequest(
            identifier: Self.scheduled, content: content(UnlockPolicy.Reason.timedOut.message),
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)))
    }

    func cancelScheduled() { center.removePendingNotificationRequests(withIdentifiers: [Self.scheduled]) }

    func post(_ reason: UnlockPolicy.Reason) {
        center.add(UNNotificationRequest(identifier: "now", content: content(reason.message), trigger: nil))
    }

    /// Told after you're back, if someone else tried while you were away.
    func reportAttempts(_ count: Int) {
        let content = UNMutableNotificationContent()
        content.title = count == 1 ? "1 Unrecognized Attempt" : "\(count) Unrecognized Attempts"
        content.body = "Someone FaceUnlock didn’t recognize was at your Mac while it was locked."
        content.sound = .default
        center.add(UNNotificationRequest(identifier: "attempts", content: content, trigger: nil))
    }

    func clear() { center.removeAllDeliveredNotifications() }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        await MainActor.run { showsBanner?() ?? true } ? [.banner, .list, .sound] : [.list]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if response.actionIdentifier == Self.confirm || response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            await MainActor.run { onConfirm?() }
        }
    }
}
