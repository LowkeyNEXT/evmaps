//
//  KiaConnectReauthNotifier.swift
//  KiaMaps
//
//  Local prompts for Kia Connect sessions that need user verification.
//

import Foundation

#if canImport(UserNotifications)
import UserNotifications
#endif

enum KiaConnectReauthNotifier {
    static func notify(reason: String) async {
        #if canImport(UserNotifications)
        let center = UNUserNotificationCenter.current()

        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            guard granted else { return }

            let content = UNMutableNotificationContent()
            content.title = "Kia Connect needs verification"
            content.body = reason
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: "kiaConnect.reauthNeeded",
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            )
            try await center.add(request)
        } catch {
            logError("Failed to schedule Kia Connect reauth notification: \(error)", category: .general)
        }
        #endif
    }
}
