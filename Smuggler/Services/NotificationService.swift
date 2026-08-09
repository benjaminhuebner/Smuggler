import UserNotifications
import os

nonisolated private let logger = Logger(subsystem: "com.benjaminhuebner.Smuggler", category: "Notifications")

// Headless mode (Services / Finder Extension) only — in-app flows show
// results in the window instead of notifying.
enum NotificationService {
    // MARK: - Authorization

    nonisolated static func requestAuthorization() async {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
            logger.info("Notification authorization: \(granted ? "granted" : "denied")")
        } catch let error as UNError where error.code == .notificationsNotAllowed {
            // Expected when the app is launched programmatically (Services, headless)
            // before the user has ever opened it directly from /Applications.
            logger.debug("Notifications not yet allowed — will be requested on next user launch")
        } catch {
            logger.warning("Notification authorization failed: \(error)")
        }
    }

    // MARK: - Posting

    nonisolated static func postResult(items: [FileItem]) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()

        guard
            settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
        else {
            logger.info("Notifications not authorized, skipping")
            return
        }

        let (title, body) = buildContent(for: items)

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "com.benjaminhuebner.Smuggler.result",
            content: content,
            trigger: nil
        )

        do {
            try await center.add(request)
        } catch {
            logger.error("Failed to post notification: \(error)")
        }
    }

    // MARK: - Content Building (pure, testable)

    nonisolated static func buildContent(for items: [FileItem]) -> (title: String, body: String) {
        guard !items.isEmpty else {
            return (String(localized: "Quarantine Removed", comment: "Notification title: success"), "")
        }
        // Cancelled rows count toward nothing: a batch the user stopped themselves
        // must not read as one where the remaining items failed.
        let successCount = items.count(where: \.status.isSuccessful)
        let errorCount = items.count(where: \.status.hasErrors)
        let attemptedCount = items.count { $0.status.isSuccessful || $0.status.hasErrors }

        if successCount == 0 {
            guard let firstFailed = items.first(where: \.status.hasErrors) else {
                return (
                    String(localized: "Cancelled", comment: "Notification title: nothing processed"),
                    String(
                        localized: "No quarantine was removed.",
                        comment: "Notification body: cancelled, nothing removed")
                )
            }
            let body =
                errorCount == 1
                ? String(
                    localized: "Could not remove quarantine from \(firstFailed.name).",
                    comment: "Notification body: single file failure")
                : String(
                    localized: "Could not remove quarantine from \(errorCount) items.",
                    comment: "Notification body: multiple files failure")
            return (String(localized: "Quarantine Removal Failed", comment: "Notification title: failure"), body)
        }

        if errorCount == 0, let firstSuccess = items.first(where: \.status.isSuccessful) {
            let body =
                successCount == 1
                ? String(
                    localized: "\(firstSuccess.name) is ready to use.",
                    comment: "Notification body: single file success")
                : String(
                    localized: "\(successCount) items are ready to use.",
                    comment: "Notification body: multiple files success")
            return (String(localized: "Quarantine Removed", comment: "Notification title: success"), body)
        }

        return (
            String(localized: "Quarantine Partially Removed", comment: "Notification title: partial success"),
            String(
                localized: "\(successCount) of \(attemptedCount) items cleaned. Some items had errors.",
                comment: "Notification body: partial success")
        )
    }
}
