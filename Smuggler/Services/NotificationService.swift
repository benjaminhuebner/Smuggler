import UserNotifications
import os

nonisolated private let logger = Logger(subsystem: "com.benjaminhuebner.Smuggler", category: "Notifications")

// Headless mode (Services / Finder Extension) only — in-app flows show
// results in the window instead of notifying.
nonisolated enum NotificationService {
    // MARK: - Authorization

    static func requestAuthorization() async {
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

    static func postResult(items: [FileItem]) async {
        let (title, body) = buildContent(for: items)
        await post(title: title, body: body)
    }

    // No row can carry this outcome: the paths never reached the app, or none of them
    // was still there. Without it the request would end in silence.
    static func postRequestFailure() async {
        await post(
            title: String(localized: "Quarantine Removal Failed", comment: "Notification title: failure"),
            body: String(
                localized: "The selected items could not be found or read. Try again from Finder.",
                comment: "Notification body: the sender's item list never arrived, or none of its items exists anymore")
        )
    }

    private static func post(title: String, body: String) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()

        guard
            settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
        else {
            logger.info("Notifications not authorized, skipping")
            return
        }

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

    static func buildContent(for items: [FileItem]) -> (title: String, body: String) {
        guard !items.isEmpty else {
            return (String(localized: "Quarantine Removed", comment: "Notification title: success"), "")
        }
        // "Freed" means something was actually taken off: counting a file that was
        // never quarantined would tell a headless user work happened that didn't.
        let freedCount = items.freedCount
        let alreadyFreeCount = items.alreadyFreeCount
        let errorCount = items.failedCount
        let attemptedCount = items.attemptedCount

        // A canceled row never finished, so "nothing needed removing" cannot speak
        // for it: that mix falls through to the stop, which claims nothing either way.
        if freedCount == 0, errorCount == 0, alreadyFreeCount > 0, items.cancelledCount == 0 {
            let body =
                alreadyFreeCount == 1
                ? String(
                    localized:
                        "\(items.first(where: { $0.status == .alreadyClean })?.name ?? "") was not in quarantine.",
                    comment: "Notification body: the single item had no quarantine to remove")
                : String(
                    localized: "\(alreadyFreeCount) items were not in quarantine.",
                    comment: "Notification body: no item had quarantine to remove")
            return (
                String(localized: "Nothing to Remove", comment: "Notification title: nothing had quarantine"), body
            )
        }

        if freedCount == 0 {
            guard let firstFailed = items.first(where: \.status.hasErrors) else {
                // No claim about the disk: a folder stopped mid-walk may already be
                // partly freed, its own quarantine first.
                return (
                    String(
                        localized: "Canceled",
                        comment: "Notification title: processing was stopped before every item finished"),
                    String(
                        localized: "Processing was stopped before it finished.",
                        comment:
                            "Notification body: nothing freed or failed, some canceled; must not claim nothing changed")
                )
            }
            let body =
                errorCount == 1
                ? String(
                    localized: "Could not remove quarantine from \(firstFailed.name).",
                    comment: "Notification body: the one named item that failed")
                : String(
                    localized: "Could not remove quarantine from \(errorCount) items.",
                    comment: "Notification body: the number of items that failed")
            return (String(localized: "Quarantine Removal Failed", comment: "Notification title: failure"), body)
        }

        if errorCount == 0 {
            let body: String
            if alreadyFreeCount > 0 {
                body = String(
                    localized: "\(freedCount) freed, \(alreadyFreeCount) were not in quarantine.",
                    comment: "Notification body: some freed, the rest had no quarantine")
            } else if freedCount == 1 {
                body = String(
                    localized:
                        "\(items.first(where: \.status.didFreeSomething)?.name ?? "") is ready to use.",
                    comment: "Notification body: the one named item that was freed")
            } else {
                body = String(
                    localized: "\(freedCount) items are ready to use.",
                    comment: "Notification body: the number of items freed")
            }
            return (String(localized: "Quarantine Removed", comment: "Notification title: success"), body)
        }

        // One folder freed only in part counts as freed and as failed at once, and a
        // count of it would read as "1 of 1 freed" right before saying some weren't.
        let partialBody =
            attemptedCount == 1
            ? String(
                localized:
                    "Some items in \(items.first(where: \.status.hasErrors)?.name ?? "") could not be processed.",
                comment: "Notification body: the one folder handed over was freed only in part")
            : String(
                localized: "\(freedCount) of \(attemptedCount) items freed. Some could not be processed.",
                comment: "Notification body: partial success, the number of items freed of all that were tried")
        return (
            String(localized: "Quarantine Partially Removed", comment: "Notification title: partial success"),
            partialBody
        )
    }
}
