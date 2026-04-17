//
//  NotificationService.swift
//  Unquarantine
//
//  Created by Benjamin Hübner on 21.03.26.
//

import UserNotifications
import os

private let logger = Logger(subsystem: "com.benjaminhuebner.Unquarantine", category: "Notifications")

/// Sends local notifications when quarantine removal completes in headless mode
/// (Services or Finder Extension). Not used for in-app drag & drop or file menu.
enum NotificationService {

    // MARK: - Authorization

    static func requestAuthorization() async {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
            logger.info("Notification authorization: \(granted ? "granted" : "denied")")
        } catch let error as UNError where error.code == .notificationsNotAllowed {
            // Expected when app is launched programmatically (Services, headless) before
            // the user has ever opened the app directly from /Applications.
            // Works correctly on first normal user launch.
            logger.debug("Notifications not yet allowed — will be requested on next user launch")
        } catch {
            logger.warning("Notification authorization failed: \(error)")
        }
    }

    // MARK: - Posting

    static func postResult(items: [FileItem]) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()

        guard settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional else {
            logger.info("Notifications not authorized, skipping")
            return
        }

        let (title, body) = buildContent(for: items)

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "com.benjaminhuebner.Unquarantine.result",
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

    static func buildContent(for items: [FileItem]) -> (title: String, body: String) {
        let successCount = items.count(where: \.status.isSuccessful)
        let hasErrors = items.contains(where: \.status.hasErrors)
        let total = items.count

        if !hasErrors {
            let name = items[0].name
            let body = total == 1
                ? String(localized: "\(name) is ready to use.",
                         comment: "Notification body: single file success")
                : String(localized: "\(total) items are ready to use.",
                         comment: "Notification body: multiple files success")
            return (String(localized: "Quarantine Removed", comment: "Notification title: success"), body)
        }

        if successCount == 0 {
            let name = items[0].name
            let body = total == 1
                ? String(localized: "Could not remove quarantine from \(name).",
                         comment: "Notification body: single file failure")
                : String(localized: "Could not remove quarantine from \(total) items.",
                         comment: "Notification body: multiple files failure")
            return (String(localized: "Quarantine Removal Failed", comment: "Notification title: failure"), body)
        }

        return (
            String(localized: "Quarantine Partially Removed", comment: "Notification title: partial success"),
            String(localized: "\(successCount) of \(total) items cleaned. Some items had errors.",
                   comment: "Notification body: partial success")
        )
    }
}
