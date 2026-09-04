import Cocoa
import FlutterMacOS
import UserNotifications

enum DesktopCallNotification {
  static let category = "VOIPCLOUD_INCOMING_CALL"
  static let answerAction = "VOIPCLOUD_ANSWER_CALL"
  static let declineAction = "VOIPCLOUD_DECLINE_CALL"
  static let callIdKey = "call_id"
  static let answerRequested = Notification.Name("VoIPCloudDesktopAnswerRequested")
  static let declineRequested = Notification.Name("VoIPCloudDesktopDeclineRequested")
}

@main
class AppDelegate: FlutterAppDelegate, UNUserNotificationCenterDelegate {
  override func applicationDidFinishLaunching(_ notification: Notification) {
    super.applicationDidFinishLaunching(notification)

    let center = UNUserNotificationCenter.current()
    center.delegate = self
    let answer = UNNotificationAction(
      identifier: DesktopCallNotification.answerAction,
      title: "Answer",
      options: [.foreground]
    )
    let decline = UNNotificationAction(
      identifier: DesktopCallNotification.declineAction,
      title: "Decline",
      options: [.destructive]
    )
    center.setNotificationCategories([
      UNNotificationCategory(
        identifier: DesktopCallNotification.category,
        actions: [answer, decline],
        intentIdentifiers: [],
        options: [.customDismissAction]
      )
    ])
    center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
      if let error {
        NSLog("VoIPCloud/macOS notification authorization failed: %@", error.localizedDescription)
      } else {
        NSLog("VoIPCloud/macOS notification authorization granted=%@", granted ? "true" : "false")
      }
    }
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    // Desktop SIP has no mobile-style process wake. Keep the Flutter engine and
    // Linphone core alive after the user closes the window so registrations and
    // incoming calls continue until the user explicitly quits VoipCloud.
    return false
  }

  override func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows flag: Bool
  ) -> Bool {
    if !flag {
      showMainWindow()
    }
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    if #available(macOS 11.0, *) {
      completionHandler([.banner, .sound])
    } else {
      completionHandler([.alert, .sound])
    }
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let callId = response.notification.request.content.userInfo[
      DesktopCallNotification.callIdKey
    ] as? String

    switch response.actionIdentifier {
    case DesktopCallNotification.answerAction:
      showMainWindow()
      NotificationCenter.default.post(
        name: DesktopCallNotification.answerRequested,
        object: nil,
        userInfo: [DesktopCallNotification.callIdKey: callId ?? ""]
      )
    case DesktopCallNotification.declineAction:
      NotificationCenter.default.post(
        name: DesktopCallNotification.declineRequested,
        object: nil,
        userInfo: [DesktopCallNotification.callIdKey: callId ?? ""]
      )
    default:
      showMainWindow()
    }
    completionHandler()
  }

  private func showMainWindow() {
    DispatchQueue.main.async {
      NSApp.activate(ignoringOtherApps: true)
      NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
    }
  }
}
