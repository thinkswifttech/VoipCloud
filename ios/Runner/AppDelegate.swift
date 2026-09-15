import AVFoundation
import AVKit
import Flutter
import CallKit
import Contacts
import Foundation
import Intents
import PushKit
import UIKit
import UniformTypeIdentifiers
import UserNotifications

private let voipCallTraceStart = ProcessInfo.processInfo.systemUptime

private func nativeCallCorrelation(_ value: String?) -> String {
  guard let value,
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
    return "none"
  }
  var hash: UInt32 = 2_166_136_261
  for byte in value.lowercased().utf8 {
    hash = (hash ^ UInt32(byte)) &* 16_777_619
  }
  return String(format: "%08x", hash)
}

private func nativeCallTrace(
  _ event: String,
  callId: String? = nil,
  details: String = ""
) {
  NSLog(
    "VoIPCloud/CallTrace/native t=%.3f event=%@ corr=%@ %@",
    ProcessInfo.processInfo.systemUptime - voipCallTraceStart,
    event,
    nativeCallCorrelation(callId),
    details
  )
}

#if canImport(linphonesw)
import linphonesw
#endif

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var linphoneBridge: LinphoneFlutterBridge?
  private var proximityBridge: ProximityScreenBridge?
  private var pushTokenBridge: VoipPushTokenBridge?
  private var downloadsFileBridge: DownloadsFileBridge?
  private var externalCommunicationBridge: ExternalCommunicationIntentBridge?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    requestMicrophonePermission()
    requestNotificationAuthorization(application)
    VoipPushRegistry.shared.registerForVoipPushes()
    LinphoneFlutterBridge.prepareForVoipWakes()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func applicationWillResignActive(_ application: UIApplication) {
    LinphoneFlutterBridge.shared?.handleWillResignActive()
    super.applicationWillResignActive(application)
  }

  override func applicationDidEnterBackground(_ application: UIApplication) {
    LinphoneFlutterBridge.shared?.handleEnterBackground()
    super.applicationDidEnterBackground(application)
  }

  override func applicationWillEnterForeground(_ application: UIApplication) {
    LinphoneFlutterBridge.shared?.handleEnterForeground()
    super.applicationWillEnterForeground(application)
  }

  private func requestMicrophonePermission() {
    AVAudioSession.sharedInstance().requestRecordPermission { granted in
      NSLog("Softphone/Microphone authorization granted=%@", granted ? "true" : "false")
    }
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let messenger = engineBridge.applicationRegistrar.messenger()
    linphoneBridge = LinphoneFlutterBridge(binaryMessenger: messenger)
    proximityBridge = ProximityScreenBridge(binaryMessenger: messenger)
    pushTokenBridge = VoipPushTokenBridge(binaryMessenger: messenger)
    downloadsFileBridge = DownloadsFileBridge(binaryMessenger: messenger)
    externalCommunicationBridge = ExternalCommunicationIntentBridge.shared
    externalCommunicationBridge?.attach(binaryMessenger: messenger)
    engineBridge.pluginRegistry
      .registrar(forPlugin: "VoipCloudAudioRoutePicker")?
      .register(
        SoftphoneAudioRoutePlatformViewFactory(),
        withId: "voipcloud/audio_route_picker"
      )
    NSLog("Softphone registered native bridges with implicit Flutter engine")
  }

  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    if ExternalCommunicationIntentBridge.shared.handle(url: url) {
      return true
    }
    return super.application(app, open: url, options: options)
  }

  override func application(
    _ application: UIApplication,
    continue userActivity: NSUserActivity,
    restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void
  ) -> Bool {
    if ExternalCommunicationIntentBridge.shared.handle(
      userActivity: userActivity
    ) {
      return true
    }
    return super.application(
      application,
      continue: userActivity,
      restorationHandler: restorationHandler
    )
  }

  private func requestNotificationAuthorization(_ application: UIApplication) {
    UNUserNotificationCenter.current().requestAuthorization(
      options: [.alert, .sound, .badge]
    ) { granted, error in
      if let error {
        NSLog("Softphone/Notifications authorization request failed: %@", error.localizedDescription)
        return
      }
      NSLog("Softphone/Notifications authorization granted=%@", granted ? "true" : "false")
      DispatchQueue.main.async {
        application.registerForRemoteNotifications()
      }
    }
  }
}

final class ExternalCommunicationIntentBridge {
  static let shared = ExternalCommunicationIntentBridge()

  private let channelName = "voipcloud/external_communication_intents"
  private var channel: FlutterMethodChannel?
  private var pendingIntent: [String: String]?

  private init() {}

  func attach(binaryMessenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: binaryMessenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(nil)
        return
      }
      switch call.method {
      case "consumePendingIntent":
        let pending = self.pendingIntent
        self.pendingIntent = nil
        result(pending)
      case "openSystemMessageFallback":
        let arguments = call.arguments as? [String: Any]
        let destination = arguments?["destination"] as? String ?? ""
        self.openSystemMessageFallback(destination: destination, result: result)
      case "openDefaultAppsSettings":
        // The app-specific Settings page includes its Default App controls on
        // supported iOS versions. Unlike the global Default Apps URL constant,
        // this URL is available on every deployment target we support.
        guard let url = URL(string: UIApplication.openSettingsURLString) else {
          result(false)
          return
        }
        UIApplication.shared.open(url, options: [:]) { opened in
          result(opened)
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    self.channel = channel
  }

  @discardableResult
  func handle(url: URL) -> Bool {
    let scheme = url.scheme?.lowercased() ?? ""
    let action: String
    switch scheme {
    case "tel":
      action = "call"
    case "im":
      action = "message"
    default:
      return false
    }

    guard let destination = Self.validatedDestination(from: url) else {
      NSLog("VoIPCloud/ExternalIntent rejected malformed %@ URL", scheme)
      return false
    }

    return publish(action: action, destination: destination)
  }

  /// Handles the CallKit/SiriKit continuation used by system calling
  /// surfaces. In particular, the Default Calling App handoff can arrive as
  /// an NSUserActivity instead of an open-URL callback.
  @discardableResult
  func handle(userActivity: NSUserActivity) -> Bool {
    guard let rawDestination = Self.startCallHandle(from: userActivity),
          let destination = Self.validatedDestination(
            fromSystemHandle: rawDestination
          )
    else {
      return false
    }
    return publish(action: "call", destination: destination)
  }

  /// Extracts the destination from the SiriKit interaction carried by a call
  /// continuation. Apple's default-calling documentation uses a
  /// `userActivity.startCallHandle` accessor that older Xcode SDK overlays do
  /// not expose. Keep the compatibility extraction here so those SDKs compile
  /// while newer iOS runtimes can still provide the native accessor.
  static func startCallHandle(from userActivity: NSUserActivity) -> String? {
    // iOS 18.2's Default Calling App handoff exposes `startCallHandle` on the
    // activity supplied by CallKit. The accessor is absent from older Xcode
    // SDK overlays even though it is present on supported iOS runtimes. Ask
    // Objective-C dynamically so builds made with those SDKs still receive
    // the number without referencing an unavailable Swift member.
    let selector = NSSelectorFromString("startCallHandle")
    if userActivity.responds(to: selector),
       let result = userActivity.perform(selector)?.takeUnretainedValue(),
       let value = stringValue(fromDefaultCallingHandle: result) {
      return value
    }

    if let intent = userActivity.interaction?.intent as? INStartCallIntent {
      if let value = firstCallDestination(in: intent.contacts) {
        return value
      }
    }

    // CallKit recents and older Siri integrations can still deliver the
    // pre-iOS 13 intent classes even when INStartCallIntent is registered.
    if let intent = userActivity.interaction?.intent as? INStartAudioCallIntent {
      if let value = firstCallDestination(in: intent.contacts) {
        return value
      }
    }
    if let intent = userActivity.interaction?.intent as? INStartVideoCallIntent {
      if let value = firstCallDestination(in: intent.contacts) {
        return value
      }
    }

    // Retain narrow compatibility fallbacks for producers that serialize the
    // documented handle into userInfo or another standard activity carrier.
    // Every value still passes the same telephone-character validation before
    // it can be published to Flutter.
    for key in ["startCallHandle", "phoneNumber", "callHandle"] {
      if let value = userActivity.userInfo?[key] as? String,
         validatedDestination(fromSystemHandle: value) != nil {
        return value
      }
    }
    if let value = userActivity.targetContentIdentifier,
       validatedDestination(fromSystemHandle: value) != nil {
      return value
    }
    if let url = userActivity.webpageURL,
       url.scheme?.lowercased() == "tel",
       let value = validatedDestination(from: url) {
      return value
    }

    return nil
  }

  private static func stringValue(fromDefaultCallingHandle value: Any) -> String? {
    if let string = value as? String {
      return string
    }
    if let url = value as? URL, url.scheme?.lowercased() == "tel" {
      return url.absoluteString
    }
    if let handle = value as? CXHandle {
      return handle.value
    }
    return nil
  }

  private static func firstCallDestination(in contacts: [INPerson]?) -> String? {
    guard let contacts else { return nil }
    for person in contacts {
      var candidates: [String?] = [person.personHandle?.value]
      candidates.append(contentsOf: (person.aliases ?? []).map(\.value))
      candidates.append(contentsOf: [
        person.customIdentifier,
        person.displayName,
        person.spokenPhrase,
      ])
      if let value = candidates.compactMap({ $0 }).first(where: {
        validatedDestination(fromSystemHandle: $0) != nil
      }) {
        return value
      }
    }
    return nil
  }

  private func publish(action: String, destination: String) -> Bool {
    let payload = [
      "id": UUID().uuidString,
      "action": action,
      "destination": destination,
    ]
    pendingIntent = payload
    channel?.invokeMethod("externalCommunicationIntent", arguments: payload)
    NSLog("VoIPCloud/ExternalIntent accepted action=%@", action)
    return true
  }

  private func openSystemMessageFallback(
    destination: String,
    result: @escaping FlutterResult
  ) {
    guard Self.isSafeDestination(destination),
          let encoded = destination.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
          ),
          let url = URL(string: "sms:\(encoded)")
    else {
      result(FlutterError(
        code: "INVALID_DESTINATION",
        message: "The messaging destination is invalid.",
        details: nil
      ))
      return
    }
    UIApplication.shared.open(url, options: [:]) { opened in
      result(opened)
    }
  }

  /// Extracts a safe dial destination from both opaque (`tel:123`) and
  /// hierarchical (`tel://123`) URLs. iOS may use either representation when
  /// handing a Default Calling App action to the application.
  static func validatedDestination(from url: URL) -> String? {
    let absolute = url.absoluteString
    guard let separator = absolute.firstIndex(of: ":") else { return nil }
    var raw = String(absolute[absolute.index(after: separator)...])
      .split(separator: "?", maxSplits: 1)
      .first
      .map(String.init) ?? ""

    // A hierarchical tel/im URL starts with `//`. Those separators are URL
    // syntax, not part of the phone number, and would otherwise cause the
    // safety check below to reject an otherwise valid iOS calling intent.
    while raw.hasPrefix("/") {
      raw.removeFirst()
    }

    guard let destination = raw.removingPercentEncoding?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    else { return nil }
    return isSafeDestination(destination) ? destination : nil
  }

  /// Validates a phone number supplied by `NSUserActivity.startCallHandle`.
  /// Older CallKit/SiriKit producers normally provide a plain handle, while
  /// other producers may preserve its `tel:` URL representation.
  static func validatedDestination(fromSystemHandle rawValue: String) -> String? {
    let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.lowercased().hasPrefix("tel:"),
       let url = URL(string: value) {
      return validatedDestination(from: url)
    }
    guard let destination = value.removingPercentEncoding?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    else { return nil }
    return isSafeDestination(destination) ? destination : nil
  }

  private static func isSafeDestination(_ destination: String) -> Bool {
    guard !destination.isEmpty, destination.count <= 128 else { return false }
    let allowed = CharacterSet(charactersIn: "0123456789+*#().- ")
    return destination.unicodeScalars.allSatisfy(allowed.contains)
  }
}

/// Hosts Apple's supported output-route picker without subclassing or
/// traversing its private view hierarchy. Flutter draws the app's audio icon;
/// the transparent AVRoutePickerView above it remains the native tap target.
private final class SoftphoneAudioRoutePlatformView: NSObject, FlutterPlatformView {
  private let routePicker: AVRoutePickerView

  init(frame: CGRect, arguments: Any?) {
    routePicker = AVRoutePickerView(frame: frame)
    super.init()
    routePicker.prioritizesVideoDevices = false
    routePicker.tintColor = .clear
    routePicker.activeTintColor = .clear
    routePicker.backgroundColor = .clear
    routePicker.isOpaque = false
    routePicker.accessibilityLabel = "Audio outputs"
    routePicker.accessibilityHint =
      "Shows available iPhone, speaker, Bluetooth, AirPlay, and CarPlay routes"
  }

  func view() -> UIView { routePicker }
}

private final class SoftphoneAudioRoutePlatformViewFactory: NSObject,
  FlutterPlatformViewFactory {
  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    SoftphoneAudioRoutePlatformView(frame: frame, arguments: args)
  }
}

final class LinphoneFlutterBridge {
  private static weak var sharedInstance: LinphoneFlutterBridge?
  private static let registrationEvents = LinphoneEventStreamHandler(name: "registration")
  private static let callEvents = LinphoneEventStreamHandler(name: "calls")
  private static let messageEvents = LinphoneEventStreamHandler(name: "messages")
  private static let sipLogEvents = LinphoneEventStreamHandler(name: "logs")
  private static let presenceEvents = LinphoneEventStreamHandler(name: "presence")

  static var shared: LinphoneFlutterBridge? {
    sharedInstance
  }

  static func prepareForVoipWakes() {
    #if canImport(linphonesw)
    LinphoneControllerFactory.shared(
      registrationEvents: registrationEvents,
      callEvents: callEvents,
      messageEvents: messageEvents,
      sipLogEvents: sipLogEvents,
      presenceEvents: presenceEvents
    ).prepareForVoipWakes()
    #endif
  }

  static func wakeFromPushPayload(_ payload: [AnyHashable: Any]) {
    #if canImport(linphonesw)
    LinphoneControllerFactory.shared(
      registrationEvents: registrationEvents,
      callEvents: callEvents,
      messageEvents: messageEvents,
      sipLogEvents: sipLogEvents,
      presenceEvents: presenceEvents
    ).wakeFromPush(payload: payload)
    #endif
  }

  private let methodChannelName = "voipcloud/linphone"
  private let registrationEventsName = "voipcloud/linphone/registration"
  private let callEventsName = "voipcloud/linphone/calls"
  private let messageEventsName = "voipcloud/linphone/messages"
  private let sipLogEventsName = "voipcloud/linphone/logs"
  private let presenceEventsName = "voipcloud/linphone/presence"

  private let controller: LinphoneController

  init(binaryMessenger: FlutterBinaryMessenger) {
    controller = LinphoneControllerFactory.shared(
      registrationEvents: Self.registrationEvents,
      callEvents: Self.callEvents,
      messageEvents: Self.messageEvents,
      sipLogEvents: Self.sipLogEvents,
      presenceEvents: Self.presenceEvents
    )

    FlutterMethodChannel(
      name: methodChannelName,
      binaryMessenger: binaryMessenger
    ).setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterError(
          code: "LINPHONE_BRIDGE_UNAVAILABLE",
          message: "Linphone bridge is unavailable.",
          details: nil
        ))
        return
      }
      self.controller.handle(call: call, result: result)
    }

    FlutterEventChannel(
      name: registrationEventsName,
      binaryMessenger: binaryMessenger
    ).setStreamHandler(Self.registrationEvents)
    FlutterEventChannel(
      name: callEventsName,
      binaryMessenger: binaryMessenger
    ).setStreamHandler(Self.callEvents)
    FlutterEventChannel(
      name: messageEventsName,
      binaryMessenger: binaryMessenger
    ).setStreamHandler(Self.messageEvents)
    FlutterEventChannel(
      name: sipLogEventsName,
      binaryMessenger: binaryMessenger
    ).setStreamHandler(Self.sipLogEvents)
    FlutterEventChannel(
      name: presenceEventsName,
      binaryMessenger: binaryMessenger
    ).setStreamHandler(Self.presenceEvents)

    Self.sharedInstance = self
  }

  func handleWillResignActive() {
    controller.handleWillResignActive()
  }

  func handleEnterBackground() {
    controller.handleEnterBackground()
  }

  func handleEnterForeground() {
    controller.handleEnterForeground()
  }

}

final class ProximityScreenBridge {
  init(binaryMessenger: FlutterBinaryMessenger) {
    FlutterMethodChannel(
      name: "voipcloud/proximity",
      binaryMessenger: binaryMessenger
    ).setMethodCallHandler { call, result in
      switch call.method {
      case "setEnabled":
        let args = call.arguments as? [String: Any] ?? [:]
        UIDevice.current.isProximityMonitoringEnabled = args["enabled"] as? Bool ?? false
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}

final class DownloadsFileBridge: NSObject, UIDocumentPickerDelegate {
  private var pendingPickResult: FlutterResult?

  init(binaryMessenger: FlutterBinaryMessenger) {
    super.init()
    FlutterMethodChannel(
      name: "voipcloud/files",
      binaryMessenger: binaryMessenger
    ).setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(
          FlutterError(
            code: "FILES_UNAVAILABLE",
            message: "File bridge is unavailable.",
            details: nil
          )
        )
        return
      }
      switch call.method {
      case "saveToDownloads":
        do {
          let args = call.arguments as? [String: Any] ?? [:]
          let fileName = (args["fileName"] as? String)?.trimmingCharacters(
            in: .whitespacesAndNewlines
          ) ?? ""
          guard !fileName.isEmpty,
                let bytes = args["bytes"] as? FlutterStandardTypedData
          else {
            result(
              FlutterError(
                code: "INVALID_ARGS",
                message: "fileName and bytes are required.",
                details: nil
              )
            )
            return
          }
          let saved = try Self.saveToDownloads(
            fileName: fileName,
            data: bytes.data
          )
          result(saved)
        } catch {
          result(
            FlutterError(
              code: "SAVE_FAILED",
              message: error.localizedDescription,
              details: nil
            )
          )
        }
      case "pickCsv":
        self.pickCsv(result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func pickCsv(result: @escaping FlutterResult) {
    if pendingPickResult != nil {
      result(
        FlutterError(
          code: "PICK_IN_PROGRESS",
          message: "A file picker is already open.",
          details: nil
        )
      )
      return
    }
    guard let presenter = Self.topViewController() else {
      result(
        FlutterError(
          code: "NO_PRESENTER",
          message: "Could not open the file picker.",
          details: nil
        )
      )
      return
    }

    pendingPickResult = result
    let contentTypes: [UTType] = [
      .commaSeparatedText,
      .plainText,
      .text,
      .data,
      .item,
    ]
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes)
    picker.delegate = self
    picker.allowsMultipleSelection = false
    picker.modalPresentationStyle = .formSheet
    presenter.present(picker, animated: true)
  }

  func documentPicker(
    _ controller: UIDocumentPickerViewController,
    didPickDocumentsAt urls: [URL]
  ) {
    let pending = pendingPickResult
    pendingPickResult = nil
    guard let pending else { return }
    guard let url = urls.first else {
      pending(nil)
      return
    }

    let accessed = url.startAccessingSecurityScopedResource()
    defer {
      if accessed {
        url.stopAccessingSecurityScopedResource()
      }
    }
    do {
      let data = try Data(contentsOf: url)
      pending(FlutterStandardTypedData(bytes: data))
    } catch {
      pending(
        FlutterError(
          code: "READ_FAILED",
          message: error.localizedDescription,
          details: nil
        )
      )
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    let pending = pendingPickResult
    pendingPickResult = nil
    pending?(nil)
  }

  private static func topViewController(
    base: UIViewController? = UIApplication.shared.connectedScenes
      .compactMap { ($0 as? UIWindowScene)?.keyWindow }
      .first?
      .rootViewController
  ) -> UIViewController? {
    if let nav = base as? UINavigationController {
      return topViewController(base: nav.visibleViewController)
    }
    if let tab = base as? UITabBarController {
      return topViewController(base: tab.selectedViewController)
    }
    if let presented = base?.presentedViewController {
      return topViewController(base: presented)
    }
    return base
  }

  private static func saveToDownloads(fileName: String, data: Data) throws -> String {
    let fileManager = FileManager.default
    guard let directory = fileManager.urls(
      for: .documentDirectory,
      in: .userDomainMask
    ).first else {
      throw NSError(
        domain: "SoftphoneFiles",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Documents folder is unavailable."]
      )
    }
    try fileManager.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )

    var target = directory.appendingPathComponent(fileName)
    if fileManager.fileExists(atPath: target.path) {
      let stamp = ISO8601DateFormatter().string(from: Date())
        .replacingOccurrences(of: ":", with: "")
      let nsName = fileName as NSString
      let base = nsName.deletingPathExtension
      let ext = nsName.pathExtension
      let renamed = ext.isEmpty ? "\(base)_\(stamp)" : "\(base)_\(stamp).\(ext)"
      target = directory.appendingPathComponent(renamed)
    }
    try data.write(to: target, options: .atomic)
    return "Files/VoipCloud/\(target.lastPathComponent)"
  }
}

final class VoipPushTokenBridge {
  private let channel: FlutterMethodChannel

  init(binaryMessenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "voipcloud/push",
      binaryMessenger: binaryMessenger
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "getVoipPushToken":
        VoipPushRegistry.shared.getVoipPushToken(result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    VoipPushRegistry.shared.registerForVoipPushes()
  }
}

final class VoipPushRegistry: NSObject, PKPushRegistryDelegate {
  static let shared = VoipPushRegistry()

  private var registry: PKPushRegistry?
  private var voipToken: String?
  private var pendingResult: FlutterResult?

  private override init() {
    super.init()
  }

  func registerForVoipPushes() {
    if registry != nil { return }
    NSLog("Softphone/PushKit registering for VoIP pushes")
    let newRegistry = PKPushRegistry(queue: DispatchQueue.main)
    newRegistry.delegate = self
    newRegistry.desiredPushTypes = [.voIP]
    registry = newRegistry
  }

  func getVoipPushToken(result: @escaping FlutterResult) {
    if let token = voipToken {
      result(pushPayload(token: token))
      return
    }
    pendingResult = result
    registerForVoipPushes()
  }

  func currentPushPayload() -> [String: String]? {
    guard let token = voipToken else { return nil }
    return pushPayload(token: token)
  }

  func pushRegistry(
    _ registry: PKPushRegistry,
    didUpdate pushCredentials: PKPushCredentials,
    for type: PKPushType
  ) {
    guard type == .voIP else { return }
    let token = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
    voipToken = token
    let payload = pushPayload(token: token)
    let environment = apsEnvironment()
    let provider = payload["provider"] ?? "unknown"
    let param = payload["param"] ?? "unknown"
    NSLog(
      "Softphone/PushKit VoIP token updated apsEnvironment=%@ provider=%@ param=%@ bundle=%@ team=%@ token=%@",
      environment,
      provider,
      param,
      payload["bundleId"] ?? "",
      payload["teamId"] ?? "",
      redactedToken(token)
    )
    pendingResult?(payload)
    pendingResult = nil
    SipCredentialStore.mergePushToken(payload)
    UIApplication.shared.registerForRemoteNotifications()
    NotificationCenter.default.post(
      name: .softphoneVoipPushTokenUpdated,
      object: nil,
      userInfo: payload
    )
  }

  func pushRegistry(
    _ registry: PKPushRegistry,
    didInvalidatePushTokenFor type: PKPushType
  ) {
    if type == .voIP {
      voipToken = nil
      NSLog("Softphone/PushKit VoIP token invalidated")
    }
  }

  func pushRegistry(
    _ registry: PKPushRegistry,
    didReceiveIncomingPushWith payload: PKPushPayload,
    for type: PKPushType,
    completion: @escaping () -> Void
  ) {
    guard type == .voIP else {
      completion()
      return
    }
    let details = payload.dictionaryPayload
    NSLog(
      "Softphone/PushKit received VoIP push keys=%@",
      details.keys.map { String(describing: $0) }.joined(separator: ",")
    )
    #if canImport(linphonesw)
    guard SipCredentialStore.load() != nil else {
      // PushKit calls must still be reported to CallKit. End the placeholder
      // immediately, however, because this token belongs to a logged-out SIP
      // identity and there is no account that may receive the call.
      SoftphoneCallKitController.shared.reportLoggedOutPushCall(
        payload: details,
        completion: completion
      )
      return
    }
    if SipCredentialStore.isDndEnabled() {
      SoftphoneCallKitController.shared.reportDndPushCall(
        payload: details,
        completion: completion
      )
      LinphoneFlutterBridge.wakeFromPushPayload(details)
      return
    }
    SoftphoneCallKitController.shared.reportIncomingPushCall(payload: details) { error in
      if let error {
        NSLog(
          "Softphone/CallKit failed to report incoming push call: %@",
          error.localizedDescription
        )
      } else {
        NSLog("Softphone/CallKit processed incoming push call")
      }
      completion()
    }
    LinphoneFlutterBridge.wakeFromPushPayload(details)
    #else
    completion()
    #endif
  }

  private func pushPayload(token: String) -> [String: String] {
    let bundleId = Bundle.main.bundleIdentifier ?? "com.thinkswift.softphoneapp"
    let teamId = currentTeamId()
    let param = teamId.isEmpty ? "\(bundleId).voip" : "\(teamId).\(bundleId).voip"
    return [
      "token": token,
      "provider": pushProviderName(),
      "param": param,
      "bundleId": bundleId,
      "teamId": teamId
    ]
  }

  private func pushProviderName() -> String {
    return apsEnvironment().lowercased() == "development" ? "apns.dev" : "apns"
  }

  private func apsEnvironment() -> String {
    if let profilePath = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision"),
       let profileData = try? Data(contentsOf: URL(fileURLWithPath: profilePath)),
       let profileText = String(data: profileData, encoding: .isoLatin1) {
      if profileText.contains("<key>aps-environment</key>") {
        if profileText.contains("<string>development</string>") {
          return "development"
        }
        if profileText.contains("<string>production</string>") {
          return "production"
        }
      }
    }

    #if DEBUG
    return "development"
    #else
    return "production"
    #endif
  }

  private func redactedToken(_ token: String) -> String {
    if token.count <= 12 { return "<redacted>" }
    return "\(token.prefix(6))...\(token.suffix(6))"
  }

  private func currentTeamId() -> String {
    let candidates = [
      Bundle.main.object(forInfoDictionaryKey: "TSAppIdentifierPrefix") as? String,
      Bundle.main.object(forInfoDictionaryKey: "TSDevelopmentTeam") as? String
    ]

    for candidate in candidates.compactMap({ $0 }) {
      let value = candidate
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: "."))
      if !value.isEmpty && !value.contains("$(") {
        return value
      }
    }

    return ""
  }
}

private enum SipCredentialStore {
  private static let payloadKey = "account_payload"
  private static let sipInstanceUuidKey = "sip_instance_uuid"
  private static let dndEnabledKey = "device_dnd_enabled"

  static func sipInstanceUuid() -> String {
    if let existing = UserDefaults.standard.string(forKey: sipInstanceUuidKey),
       UUID(uuidString: existing) != nil {
      return existing.lowercased()
    }
    let generated = UUID().uuidString.lowercased()
    UserDefaults.standard.set(generated, forKey: sipInstanceUuidKey)
    return generated
  }

  static func save(_ args: [String: Any]) {
    var payload: [String: String] = [:]
    for (key, value) in args {
      if let string = value as? String {
        payload[key] = string
      }
    }
    guard !payload.isEmpty,
          let data = try? JSONSerialization.data(withJSONObject: payload)
    else {
      return
    }
    UserDefaults.standard.set(data, forKey: payloadKey)
  }

  static func load() -> [String: Any]? {
    guard let data = UserDefaults.standard.data(forKey: payloadKey),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          !json.isEmpty
    else {
      return nil
    }
    return json
  }

  static func clear() {
    UserDefaults.standard.removeObject(forKey: payloadKey)
    UserDefaults.standard.removeObject(forKey: dndEnabledKey)
  }

  static func setDndEnabled(_ enabled: Bool) {
    UserDefaults.standard.set(enabled, forKey: dndEnabledKey)
  }

  static func isDndEnabled() -> Bool {
    UserDefaults.standard.bool(forKey: dndEnabledKey)
  }

  static func mergePushToken(_ payload: [String: String]) {
    guard var saved = load() else { return }
    if let token = payload["token"], !token.isEmpty {
      saved["pushToken"] = token
    }
    if let provider = payload["provider"], !provider.isEmpty {
      saved["pushProvider"] = provider
    }
    if let param = payload["param"], !param.isEmpty {
      saved["pushParam"] = param
    }
    if let bundleId = payload["bundleId"], !bundleId.isEmpty {
      saved["pushBundleId"] = bundleId
    }
    if let teamId = payload["teamId"], !teamId.isEmpty {
      saved["pushTeamId"] = teamId
    }
    save(saved)
  }
}

private final class LinphoneEventStreamHandler: NSObject, FlutterStreamHandler {
  private let name: String
  private var eventSink: FlutterEventSink?
  private var lastEvent: [String: Any?]?

  init(name: String) {
    self.name = name
    super.init()
  }

  func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    eventSink = events
    NSLog("Softphone/EventChannel %@ listener attached", name)
    if let lastEvent {
      NSLog("Softphone/EventChannel %@ replaying latest event", name)
      events(lastEvent)
    }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    NSLog("Softphone/EventChannel %@ listener cancelled", name)
    eventSink = nil
    return nil
  }

  func send(_ event: [String: Any?]) {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.lastEvent = event
      guard let eventSink = self.eventSink else {
        NSLog("Softphone/EventChannel %@ has no listener; cached latest event", self.name)
        return
      }
      eventSink(event)
    }
  }
}

private protocol LinphoneController {
  func handle(call: FlutterMethodCall, result: @escaping FlutterResult)
  func prepareForVoipWakes()
  func handleWillResignActive()
  func wakeFromPush(payload: [AnyHashable: Any])
  func handleEnterBackground()
  func handleEnterForeground()
}

private enum LinphoneControllerFactory {
  #if canImport(linphonesw)
  private static var nativeSingleton: NativeLinphoneController?
  #endif

  static func shared(
    registrationEvents: LinphoneEventStreamHandler,
    callEvents: LinphoneEventStreamHandler,
    messageEvents: LinphoneEventStreamHandler,
    sipLogEvents: LinphoneEventStreamHandler,
    presenceEvents: LinphoneEventStreamHandler
  ) -> LinphoneController {
    #if canImport(linphonesw)
    if let nativeSingleton {
      return nativeSingleton
    }
    let controller = NativeLinphoneController(
      registrationEvents: registrationEvents,
      callEvents: callEvents,
      messageEvents: messageEvents,
      sipLogEvents: sipLogEvents,
      presenceEvents: presenceEvents
    )
    nativeSingleton = controller
    return controller
    #else
    return UnavailableLinphoneController()
    #endif
  }

  static func make(
    registrationEvents: LinphoneEventStreamHandler,
    callEvents: LinphoneEventStreamHandler,
    messageEvents: LinphoneEventStreamHandler,
    sipLogEvents: LinphoneEventStreamHandler,
    presenceEvents: LinphoneEventStreamHandler
  ) -> LinphoneController {
    shared(
      registrationEvents: registrationEvents,
      callEvents: callEvents,
      messageEvents: messageEvents,
      sipLogEvents: sipLogEvents,
      presenceEvents: presenceEvents
    )
  }
}

private final class IOSCallerIdentityStore {
  static let shared = IOSCallerIdentityStore()
  private static let maximumEntries = 2_000

  private let lock = NSLock()
  private var directory: [String: String]

  private init() {
    directory = Self.loadDirectory()
  }

  func cachedName(for number: String) -> String? {
    lock.lock()
    defer { lock.unlock() }
    return Self.identityKeys(number).compactMap { directory[$0] }.first
  }

  func updateDirectory(arguments: [String: Any]) {
    let entries = arguments["entries"] as? [[String: Any]] ?? []
    var updated: [String: String] = [:]
    for entry in entries.prefix(Self.maximumEntries) {
      let name = ((entry["name"] ?? entry["displayName"]) as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard !name.isEmpty else { continue }
      let numbers = (entry["numbers"] as? [Any])?.compactMap {
        ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
      } ?? [entry["number"], entry["extension"]].compactMap {
        ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
      }
      for number in numbers where !number.isEmpty {
        for key in Self.identityKeys(number) where updated[key] == nil {
          updated[key] = name
        }
      }
    }
    lock.lock()
    directory = updated
    lock.unlock()
    Self.persist(updated)
  }

  func resolveContactName(for number: String, completion: @escaping (String?) -> Void) {
    guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else {
      completion(nil)
      return
    }
    DispatchQueue.global(qos: .userInitiated).async {
      let keys: [CNKeyDescriptor] = [
        CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
        CNContactOrganizationNameKey as CNKeyDescriptor,
      ]
      let predicate = CNContact.predicateForContacts(
        matching: CNPhoneNumber(stringValue: number)
      )
      let contacts = (try? CNContactStore().unifiedContacts(
        matching: predicate,
        keysToFetch: keys
      )) ?? []
      let name = contacts.lazy.compactMap { contact -> String? in
        let fullName = CNContactFormatter.string(from: contact, style: .fullName)?
          .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !fullName.isEmpty { return fullName }
        let organization = contact.organizationName
          .trimmingCharacters(in: .whitespacesAndNewlines)
        return organization.isEmpty ? nil : organization
      }.first
      DispatchQueue.main.async { completion(name) }
    }
  }

  func clear() {
    lock.lock()
    directory.removeAll()
    lock.unlock()
    try? FileManager.default.removeItem(at: Self.fileUrl)
  }

  private static var fileUrl: URL {
    let base = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first!
    return base.appendingPathComponent("voipcloud-caller-directory-v1.json")
  }

  private static func loadDirectory() -> [String: String] {
    guard let data = try? Data(contentsOf: fileUrl),
          let object = try? JSONSerialization.jsonObject(with: data),
          let value = object as? [String: String]
    else { return [:] }
    return value
  }

  private static func persist(_ value: [String: String]) {
    do {
      let url = fileUrl
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      let data = try JSONSerialization.data(withJSONObject: value)
      try data.write(
        to: url,
        options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
      )
    } catch {
      NSLog("Softphone/Identity failed to persist protected directory cache: %@", error.localizedDescription)
    }
  }

  private static func identityKeys(_ rawValue: String) -> [String] {
    var normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    if normalized.hasPrefix("<") && normalized.hasSuffix(">") {
      normalized = String(normalized.dropFirst().dropLast())
    }
    if normalized.lowercased().hasPrefix("sip:") ||
        normalized.lowercased().hasPrefix("sips:") {
      normalized = String(normalized.dropFirst(
        normalized.lowercased().hasPrefix("sips:") ? 5 : 4
      ))
      normalized = normalized.split(separator: "@", maxSplits: 1)
        .first.map(String.init) ?? normalized
    }
    let trimmed = (normalized.removingPercentEncoding ?? normalized).lowercased()
    guard !trimmed.isEmpty else { return [] }
    let digits = trimmed.filter { $0.isNumber }
    var keys = ["exact:\(trimmed)"]
    if !digits.isEmpty { keys.append("digits:\(digits)") }
    if digits.count >= 10 { keys.append("nanp:\(digits.suffix(10))") }
    return keys
  }
}

private final class UnavailableLinphoneController: LinphoneController {
  func prepareForVoipWakes() {}
  func handleWillResignActive() {}
  func wakeFromPush(payload: [AnyHashable: Any]) {}
  func handleEnterBackground() {}
  func handleEnterForeground() {}

  func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "initialize",
         "configureAccount",
         "register",
         "unregister",
         "purgeAccount",
         "makeCall",
         "dialFeatureCode",
         "acceptCall",
         "rejectCall",
         "endCall",
         "mute",
         "hold",
         "resume",
         "setSpeaker",
         "setBluetooth",
         "ensureBluetoothPermission",
         "getAudioRoutes",
         "setAudioRoute",
         "sendDtmf",
         "transferCall",
         "sendMessage",
         "setSipLoggingEnabled",
         "appendSipLogLine",
         "readSipLogFile",
         "clearSipLogFile",
         "dispose":
      result(FlutterError(
        code: "LINPHONE_NOT_LINKED",
        message: "iOS liblinphone bridge is not linked in this build.",
        details: nil
      ))
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

#if canImport(linphonesw)
private final class SoftphoneCallKitController: NSObject, CXProviderDelegate {
  static let shared = SoftphoneCallKitController()

  private let provider: CXProvider
  private let callController = CXCallController()
  private weak var core: Core?
  private var findCallByLinphoneId: ((String) -> Call?)?
  private var linphoneIdForCall: ((Call) -> String)?

  private var callKitUuidByLinphoneId: [String: UUID] = [:]
  private var linphoneIdByCallKitUuid: [UUID: String] = [:]
  private var callKitUuidByCallObject: [ObjectIdentifier: UUID] = [:]
  private var pushOnlyCallKitUuids: Set<UUID> = []
  private var pushCallIdByUuid: [UUID: String] = [:]
  private var rejectedPushCallIds: Set<String> = []
  private var pendingAnswerCallUuids = Set<UUID>()
  private var answerAcceptanceStarted: Set<UUID> = []
  private var pendingResumeAttempts: [ObjectIdentifier: Int] = [:]
  private var rejectNextIncomingSipCall = false
  private struct PendingOutgoingCall {
    let startSipCall: () throws -> Call
    let completion: (Result<Call, Error>) -> Void
  }
  private var pendingOutgoingCalls: [UUID: PendingOutgoingCall] = [:]
  private var audioSessionActivated = false
  /// True when we activated Linphone audio for an outgoing call without CallKit.
  private var outgoingAudioSessionManaged = false

  private override init() {
    let configuration = CXProviderConfiguration()
    configuration.supportsVideo = false
    configuration.maximumCallsPerCallGroup = 1
    configuration.maximumCallGroups = 1
    configuration.supportedHandleTypes = [.generic, .phoneNumber]
    // VoIPCloud already has an authoritative in-app call history. Avoid a
    // second persistent list in Phone while retaining the active CallKit call.
    configuration.includesCallsInRecents = false
    provider = CXProvider(configuration: configuration)
    super.init()
    provider.setDelegate(self, queue: nil)
  }

  func attach(
    core: Core,
    findCallByLinphoneId: @escaping (String) -> Call?,
    linphoneIdForCall: @escaping (Call) -> String
  ) {
    self.core = core
    self.findCallByLinphoneId = findCallByLinphoneId
    self.linphoneIdForCall = linphoneIdForCall
    core.callkitEnabled = true
    NSLog("Softphone/CallKit attached to Linphone core")
  }

  func setSuppressCallKitUi(_ suppress: Bool) {
    NSLog(
      "Softphone/CallKit app presentation is foreground=%@; system call remains active",
      suppress ? "yes" : "no"
    )
  }

  func reportIncomingPushCall(
    payload: [AnyHashable: Any],
    completion: @escaping (Error?) -> Void
  ) {
    // VoIP pushes must always report CallKit, including cold-start wakes before
    // Flutter has established its own lifecycle state.
    // APNs delivery is at-least-once and Flexisip can emit more than one wake-up
    // for the same SIP transaction. Keep a single placeholder while the SIP call
    // is pending, and do not create another placeholder after it has been linked.
    let incomingCallId = pushCallId(from: payload)
    nativeCallTrace(
      "push_received",
      callId: incomingCallId,
      details: "hasCallId=\(incomingCallId == nil ? "false" : "true")"
    )
    let hasPresentedCall = !pushOnlyCallKitUuids.isEmpty || !callKitUuidByLinphoneId.isEmpty
    if let incomingCallId,
       pushCallIdByUuid.values.contains(incomingCallId) ||
       callKitUuidByLinphoneId[incomingCallId] != nil {
      NSLog("Softphone/CallKit suppressed duplicate incoming push call")
      completion(nil)
      return
    }
    if hasPresentedCall {
      guard let incomingCallId else {
        // The deployed payload contract always includes Call-ID. An ambiguous
        // legacy wake cannot safely be distinguished from a duplicate and must
        // never reject the INVITE belonging to the already-presented call.
        NSLog("Softphone/CallKit suppressed ambiguous legacy push during active call")
        completion(nil)
        return
      }
      reportBusyIncomingPushCall(
        payload: payload,
        callId: incomingCallId,
        completion: completion
      )
      return
    }

    let caller = callerValue(from: payload)
    let trustedDisplayName = displayName(from: payload)
    let resolvedDisplayName = callerNamePreservingDialPrefix(
      IOSCallerIdentityStore.shared.cachedName(for: caller) ?? trustedDisplayName,
      remoteHandle: caller,
      sourceDisplayName: trustedDisplayName
    )
    let uuid = UUID()
    pushOnlyCallKitUuids.insert(uuid)
    if let incomingCallId {
      pushCallIdByUuid[uuid] = incomingCallId
    }
    reportIncomingCall(
      uuid: uuid,
      remoteHandle: caller,
      displayName: resolvedDisplayName,
      linphoneId: nil,
      completion: { [weak self] error in
        completion(error)
        guard error == nil else {
          self?.pushOnlyCallKitUuids.remove(uuid)
          self?.pushCallIdByUuid.removeValue(forKey: uuid)
          return
        }
        self?.resolveContactName(
          uuid: uuid,
          remoteHandle: caller,
          sourceDisplayName: trustedDisplayName
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
          guard let self,
                self.pushOnlyCallKitUuids.remove(uuid) != nil else { return }
          self.failPendingAnswer(uuid: uuid)
          self.pushCallIdByUuid.removeValue(forKey: uuid)
          self.reportCallEnded(uuid: uuid, reason: .unanswered)
          NSLog("Softphone/CallKit expired unmatched incoming push placeholder")
        }
      }
    )
  }

  /// Every genuine PushKit VoIP invitation must be reported to CallKit. Since
  /// VoIPCloud supports one call, report a second distinct Call-ID and close it
  /// immediately as busy instead of silently consuming its VoIP push.
  private func reportBusyIncomingPushCall(
    payload: [AnyHashable: Any],
    callId: String,
    completion: @escaping (Error?) -> Void
  ) {
    let caller = callerValue(from: payload)
    let resolvedDisplayName = callerNamePreservingDialPrefix(
      IOSCallerIdentityStore.shared.cachedName(for: caller) ?? displayName(from: payload),
      remoteHandle: caller,
      sourceDisplayName: displayName(from: payload)
    )
    let uuid = UUID()
    rejectedPushCallIds.insert(callId)
    DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
      self?.rejectedPushCallIds.remove(callId)
    }
    reportIncomingCall(
      uuid: uuid,
      remoteHandle: caller,
      displayName: resolvedDisplayName,
      linphoneId: nil,
      completion: { [weak self] error in
        if error == nil {
          self?.reportCallEnded(uuid: uuid, reason: .declinedElsewhere)
          NSLog("Softphone/CallKit reported and declined concurrent incoming call")
        } else {
          NSLog(
            "Softphone/CallKit concurrent incoming call was disallowed: %@",
            error?.localizedDescription ?? "unknown"
          )
        }
        completion(error)
      }
    )
  }

  func reportLoggedOutPushCall(
    payload: [AnyHashable: Any],
    completion: @escaping () -> Void
  ) {
    NSLog("Softphone/CallKit discarding stale push for logged-out SIP account")
    reportIncomingPushCall(payload: payload) { [weak self] error in
      guard error == nil, let self else {
        completion()
        return
      }
      let staleUuids = self.pushOnlyCallKitUuids
      self.pushOnlyCallKitUuids.removeAll()
      for uuid in staleUuids {
        self.failPendingAnswer(uuid: uuid)
        self.pushCallIdByUuid.removeValue(forKey: uuid)
        self.reportCallEnded(uuid: uuid, reason: .unanswered)
      }
      completion()
    }
  }

  func reportDndPushCall(
    payload: [AnyHashable: Any],
    completion: @escaping () -> Void
  ) {
    let incomingCallId = pushCallId(from: payload)
    if let incomingCallId {
      if rejectedPushCallIds.contains(incomingCallId) {
        NSLog("Softphone/CallKit suppressed duplicate device-DND push")
        completion()
        return
      }
      rejectedPushCallIds.insert(incomingCallId)
      DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
        self?.rejectedPushCallIds.remove(incomingCallId)
      }
    } else {
      rejectNextIncomingSipCall = true
      DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
        self?.rejectNextIncomingSipCall = false
      }
    }
    NSLog("Softphone/CallKit suppressing incoming push for device DND")
    let caller = callerValue(from: payload)
    let trustedDisplayName = displayName(from: payload)
    let resolvedDisplayName = callerNamePreservingDialPrefix(
      IOSCallerIdentityStore.shared.cachedName(for: caller) ?? trustedDisplayName,
      remoteHandle: caller,
      sourceDisplayName: trustedDisplayName
    )
    let uuid = UUID()
    reportIncomingCall(
      uuid: uuid,
      remoteHandle: caller,
      displayName: resolvedDisplayName,
      linphoneId: nil,
      completion: { [weak self] error in
        if error == nil {
          self?.reportCallEnded(uuid: uuid, reason: .unanswered)
        } else {
          NSLog(
            "Softphone/CallKit device-DND call report failed: %@",
            error?.localizedDescription ?? "unknown"
          )
        }
        completion()
      }
    )
  }

  func handleCallStateChanged(call: Call, state: Call.State) {
    guard let linphoneIdForCall else { return }
    let linphoneId = linphoneIdForCall(call)
    nativeCallTrace(
      "sip_state",
      callId: linphoneId,
      details: "direction=\(call.dir == .Incoming ? "incoming" : "outgoing") state=\(state)"
    )
    if let uuid = callKitUuidByCallObject[ObjectIdentifier(call)],
       callKitUuidByLinphoneId[linphoneId] != uuid {
      // The SDK initially exposes an outgoing call before callLog.callId is
      // populated. Promote the CallKit association from that temporary ID to
      // the authoritative SIP Call-ID without creating a second call/session.
      linkCallKit(uuid: uuid, linphoneId: linphoneId, call: call)
      NSLog("Softphone/CallKit promoted call identity to SIP Call-ID")
    }

    switch state {
    case .PushIncomingReceived:
      if rejectedPushCallIds.contains(linphoneId) || rejectNextIncomingSipCall {
        end(call: call)
        endCallKitCall(linphoneId: linphoneId)
        return
      }
      NSLog("Softphone/CallKit PushIncomingReceived id=%@", linphoneId)
      presentIncomingCall(call: call, linphoneId: linphoneId)
      drivePendingAnswerIfNeeded(linphoneId: linphoneId)
    case .IncomingReceived, .IncomingEarlyMedia:
      // If CallKit already reported a push placeholder, the real SIP call must
      // still be linked to it so caller details and a pending lock-screen answer
      // apply to the authoritative SIP call.
      if rejectedPushCallIds.remove(linphoneId) != nil || rejectNextIncomingSipCall {
        rejectNextIncomingSipCall = false
        end(call: call)
        endCallKitCall(linphoneId: linphoneId)
        return
      }
      presentIncomingCall(call: call, linphoneId: linphoneId)
      drivePendingAnswerIfNeeded(linphoneId: linphoneId)
    case .OutgoingInit, .OutgoingProgress, .OutgoingRinging, .OutgoingEarlyMedia,
         .Connected, .StreamsRunning:
      if state == .Connected || state == .StreamsRunning {
        pendingResumeAttempts.removeValue(forKey: ObjectIdentifier(call))
      }
      if call.dir != .Incoming,
         let uuid = callKitUuidByLinphoneId[linphoneId] {
        if state == .Connected || state == .StreamsRunning {
          provider.reportOutgoingCall(with: uuid, connectedAt: Date())
        }
      } else if call.dir != .Incoming && pendingOutgoingCalls.isEmpty {
        // Feature codes intentionally remain short-lived app-only calls.
        ensureAudioSessionActiveForOutgoingCall()
      }
      if call.dir == .Incoming && (state == .Connected || state == .StreamsRunning) {
        completePendingAnswerIfConnected(linphoneId: linphoneId)
      }
    case .Paused:
      driveQueuedResumeIfNeeded(call: call)
    case .End, .Released, .Error:
      pendingResumeAttempts.removeValue(forKey: ObjectIdentifier(call))
      failPendingAnswer(linphoneId: linphoneId)
      endCallKitCall(linphoneId: linphoneId)
      if call.dir != .Incoming {
        releaseOutgoingAudioSessionIfNeeded()
      }
    default:
      break
    }
  }

  func configureAudioSessionForCall() {
    core?.configureAudioSession()
    do {
      // CallKit remains responsible for activation. Setting the category and
      // mode here merely declares the bidirectional VoIP policy that CallKit
      // will activate in provider(_:didActivate:).
      try AVAudioSession.sharedInstance().setCategory(
        .playAndRecord,
        mode: .voiceChat,
        options: [.allowBluetooth]
      )
    } catch {
      NSLog(
        "Softphone/CallKit failed to configure audio category: %@",
        error.localizedDescription
      )
    }
  }

  /// Starts an app-originated call through CallKit before creating the SIP
  /// INVITE. This lets iOS arbitrate cellular calls, Bluetooth and CarPlay, and
  /// guarantees Linphone only starts media after CallKit activates the session.
  func requestStartOutgoingCall(
    remoteHandle: String,
    startSipCall: @escaping () throws -> Call,
    completion: @escaping (Result<Call, Error>) -> Void
  ) {
    let uuid = UUID()
    nativeCallTrace(
      "outgoing_transaction_requested",
      callId: uuid.uuidString
    )
    pendingOutgoingCalls[uuid] = PendingOutgoingCall(
      startSipCall: startSipCall,
      completion: completion
    )
    let action = CXStartCallAction(
      call: uuid,
      handle: callKitHandle(for: remoteHandle)
    )
    action.isVideo = false
    callController.request(CXTransaction(action: action)) { [weak self] error in
      guard let error else { return }
      DispatchQueue.main.async {
        nativeCallTrace(
          "outgoing_transaction_rejected",
          callId: uuid.uuidString,
          details: "code=\((error as NSError).code)"
        )
        guard let pending = self?.pendingOutgoingCalls.removeValue(forKey: uuid) else {
          return
        }
        pending.completion(.failure(error))
      }
    }
  }

  @discardableResult
  func requestEndFromApp(
    call: Call,
    completion: @escaping (Error?) -> Void
  ) -> Bool {
    guard let uuid = callKitUuid(for: call) else { return false }
    request(action: CXEndCallAction(call: uuid), completion: completion)
    return true
  }

  @discardableResult
  func requestMuteFromApp(
    call: Call,
    muted: Bool,
    completion: @escaping (Error?) -> Void
  ) -> Bool {
    guard let uuid = callKitUuid(for: call) else { return false }
    request(
      action: CXSetMutedCallAction(call: uuid, muted: muted),
      completion: completion
    )
    return true
  }

  @discardableResult
  func requestHeldFromApp(
    call: Call,
    held: Bool,
    completion: @escaping (Error?) -> Void
  ) -> Bool {
    guard let uuid = callKitUuid(for: call) else { return false }
    request(
      action: CXSetHeldCallAction(call: uuid, onHold: held),
      completion: completion
    )
    return true
  }

  private func callKitUuid(for call: Call) -> UUID? {
    guard let linphoneIdForCall else { return nil }
    return callKitUuidByCallObject[ObjectIdentifier(call)]
      ?? callKitUuidByLinphoneId[linphoneIdForCall(call)]
  }

  func isCallManaged(_ call: Call) -> Bool {
    guard let uuid = callKitUuid(for: call) else { return false }
    return callController.callObserver.calls.contains {
      $0.uuid == uuid && !$0.hasEnded
    }
  }

  private func request(
    action: CXCallAction,
    completion: @escaping (Error?) -> Void
  ) {
    nativeCallTrace(
      "callkit_transaction_requested",
      callId: action.callUUID.uuidString,
      details: "action=\(String(describing: type(of: action)))"
    )
    callController.request(CXTransaction(action: action)) { error in
      DispatchQueue.main.async {
        let errorCode = error.map { ($0 as NSError).code } ?? 0
        nativeCallTrace(
          error == nil ? "callkit_transaction_accepted" : "callkit_transaction_rejected",
          callId: action.callUUID.uuidString,
          details: "action=\(String(describing: type(of: action))) code=\(errorCode)"
        )
        completion(error)
      }
    }
  }

  /// Answers a PushKit/CallKit call from the Flutter incoming-call screen.
  /// Going through CXCallController keeps the system incoming-call banner in
  /// sync; accepting Linphone directly leaves CallKit showing "Incoming call".
  @discardableResult
  func requestAnswerFromApp(
    call: Call,
    completion: @escaping (Error?) -> Void
  ) -> Bool {
    guard let linphoneIdForCall else { return false }
    let linphoneId = linphoneIdForCall(call)

    let matchingPushUuid = pushCallIdByUuid.first(where: {
      $0.value == linphoneId
    })?.key ?? pushOnlyCallKitUuids.first(where: {
      pushCallIdByUuid[$0] == nil
    })
    if callKitUuidByLinphoneId[linphoneId] == nil,
       let pushUuid = matchingPushUuid {
      pushOnlyCallKitUuids.remove(pushUuid)
      pushCallIdByUuid.removeValue(forKey: pushUuid)
      linkCallKit(uuid: pushUuid, linphoneId: linphoneId, call: call)
      updateIncomingCall(
        uuid: pushUuid,
        remoteHandle: call.remoteAddress?.username ?? "Incoming call",
        displayName: callerDisplayLabel(
          call.remoteAddress,
          fallback: call.remoteAddress?.username ?? "Incoming call"
        )
      )
    }

    guard let uuid = callKitUuidByLinphoneId[linphoneId] else { return false }
    let transaction = CXTransaction(action: CXAnswerCallAction(call: uuid))
    callController.request(transaction) { error in
      DispatchQueue.main.async {
        completion(error)
      }
    }
    return true
  }

  /// Removes a CallKit call that iOS can no longer present or answer. The
  /// Flutter call screen can then accept the still-ringing Linphone call
  /// directly without leaving a stale system incoming-call UI behind.
  func prepareDirectAnswerAfterCallKitFailure(call: Call) {
    guard let linphoneIdForCall else {
      configureAudioSessionForCall()
      return
    }

    let linphoneId = linphoneIdForCall(call)
    if let uuid = callKitUuidByLinphoneId.removeValue(forKey: linphoneId) {
      linphoneIdByCallKitUuid.removeValue(forKey: uuid)
      failPendingAnswer(uuid: uuid)
      pushOnlyCallKitUuids.remove(uuid)
      callKitUuidByCallObject = callKitUuidByCallObject.filter { $0.value != uuid }
      reportCallEnded(uuid: uuid, reason: .answeredElsewhere)
    }
    configureAudioSessionForCall()
  }

  /// Feature-code calls intentionally bypass CallKit, so `didActivate` never
  /// runs and their early media needs a short-lived Linphone audio session.
  func ensureAudioSessionActiveForOutgoingCall() {
    configureAudioSessionForCall()
    guard let core = core else { return }
    guard !audioSessionActivated else { return }
    if !outgoingAudioSessionManaged {
      core.activateAudioSession(activated: true)
      outgoingAudioSessionManaged = true
      NSLog("Softphone/CallKit activated audio session for outgoing call")
    }
  }

  private func releaseOutgoingAudioSessionIfNeeded() {
    guard outgoingAudioSessionManaged, !audioSessionActivated else { return }
    guard let core = core else {
      outgoingAudioSessionManaged = false
      return
    }
    if let current = core.currentCall, isActiveCallState(current.state) {
      return
    }
    core.activateAudioSession(activated: false)
    outgoingAudioSessionManaged = false
    NSLog("Softphone/CallKit released outgoing audio session")
  }

  private func isActiveCallState(_ state: Call.State) -> Bool {
    switch state {
    case .End, .Released, .Error:
      return false
    default:
      return true
    }
  }

  func providerDidReset(_ provider: CXProvider) {
    let pendingStarts = Array(pendingOutgoingCalls.values)
    pendingOutgoingCalls.removeAll()
    let resetError = NSError(
      domain: "SoftphoneCallKit",
      code: 1001,
      userInfo: [NSLocalizedDescriptionKey: "The system calling service was reset."]
    )
    pendingStarts.forEach { $0.completion(.failure(resetError)) }
    for call in core?.calls ?? [] {
      end(call: call)
    }
    core?.activateAudioSession(activated: false)
    callKitUuidByLinphoneId.removeAll()
    linphoneIdByCallKitUuid.removeAll()
    callKitUuidByCallObject.removeAll()
    pushOnlyCallKitUuids.removeAll()
    pushCallIdByUuid.removeAll()
    rejectedPushCallIds.removeAll()
    pendingAnswerCallUuids.removeAll()
    answerAcceptanceStarted.removeAll()
    pendingResumeAttempts.removeAll()
    rejectNextIncomingSipCall = false
    audioSessionActivated = false
    outgoingAudioSessionManaged = false
    NSLog("Softphone/CallKit provider reset; terminated all SIP calls")
  }

  func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
    NSLog(
      "Softphone/CallKit action timed out type=%@",
      String(describing: type(of: action))
    )
    if let startAction = action as? CXStartCallAction,
       let pending = pendingOutgoingCalls.removeValue(forKey: startAction.callUUID) {
      let error = NSError(
        domain: "SoftphoneCallKit",
        code: 1002,
        userInfo: [NSLocalizedDescriptionKey: "The system call action timed out."]
      )
      pending.completion(.failure(error))
    }
    action.fail()
  }

  func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
    NSLog("Softphone/CallKit audio session activated")
    nativeCallTrace(
      "audio_session_activated",
      details: "route=\(audioSession.currentRoute.outputs.first?.portType.rawValue ?? "none")"
    )
    outgoingAudioSessionManaged = false
    if !audioSessionActivated {
      audioSessionActivated = true
      core?.activateAudioSession(activated: true)
    }
    acceptAllPendingAnswers()
  }

  func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
    NSLog("Softphone/CallKit audio session deactivated")
    nativeCallTrace("audio_session_deactivated")
    guard audioSessionActivated else {
      NSLog("Softphone/CallKit ignoring duplicate audio-session deactivation")
      outgoingAudioSessionManaged = false
      return
    }
    audioSessionActivated = false
    outgoingAudioSessionManaged = false
    core?.activateAudioSession(activated: false)
  }

  func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
    nativeCallTrace("answer_action_perform", callId: action.callUUID.uuidString)
    configureAudioSessionForCall()
    pendingAnswerCallUuids.insert(action.callUUID)
    drivePendingAnswerIfNeeded(callKitUuid: action.callUUID)
    if !pendingAnswerCallUuids.contains(action.callUUID) {
      var alreadyConnected = false
      if let linphoneId = linphoneIdByCallKitUuid[action.callUUID],
         let call = findCallByLinphoneId?(linphoneId) {
        alreadyConnected = call.state == .Connected || call.state == .StreamsRunning
      }
      guard alreadyConnected else {
        action.fail()
        return
      }
    }
    // Completing the action allows CallKit to activate the provider audio
    // session. SIP accept has already started (or remains queued until the
    // matching INVITE arrives), so signaling never waits on audio activation.
    action.fulfill()
    nativeCallTrace(
      "answer_action_fulfilled",
      callId: action.callUUID.uuidString,
      details: "sipAcceptStarted=\(answerAcceptanceStarted.contains(action.callUUID))"
    )
    DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self, weak action] in
      guard let self, let action,
            self.pendingAnswerCallUuids.contains(action.callUUID) else { return }
      self.failPendingAnswer(uuid: action.callUUID)
      if let linphoneId = self.linphoneIdByCallKitUuid[action.callUUID],
         let call = self.findCallByLinphoneId?(linphoneId) {
        self.end(call: call)
      }
      self.reportCallEnded(uuid: action.callUUID, reason: .failed)
      NSLog("Softphone/CallKit incoming answer timed out before SIP connected")
    }
  }

  func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
    nativeCallTrace("end_action_perform", callId: action.callUUID.uuidString)
    failPendingAnswer(uuid: action.callUUID)
    if let linphoneId = linphoneIdByCallKitUuid[action.callUUID],
       let call = findCallByLinphoneId?(linphoneId) {
      end(call: call)
    } else if pushOnlyCallKitUuids.remove(action.callUUID) != nil {
      // The user rejected the PushKit placeholder before the SIP INVITE was
      // observable. Close immediately and reject the authoritative INVITE when
      // it arrives instead of presenting a second incoming-call screen.
      if let callId = pushCallIdByUuid.removeValue(forKey: action.callUUID) {
        rejectedPushCallIds.insert(callId)
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
          self?.rejectedPushCallIds.remove(callId)
        }
      } else {
        rejectNextIncomingSipCall = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
          self?.rejectNextIncomingSipCall = false
        }
      }
    }
    action.fulfill()
  }

  func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
    nativeCallTrace("start_action_perform", callId: action.callUUID.uuidString)
    guard let pending = pendingOutgoingCalls[action.callUUID],
          let linphoneIdForCall
    else {
      action.fail()
      return
    }
    configureAudioSessionForCall()
    do {
      let call = try pending.startSipCall()
      let linphoneId = linphoneIdForCall(call)
      linkCallKit(uuid: action.callUUID, linphoneId: linphoneId, call: call)
      pendingOutgoingCalls.removeValue(forKey: action.callUUID)
      provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
      action.fulfill(withDateStarted: Date())
      nativeCallTrace(
        "start_action_fulfilled",
        callId: linphoneId,
        details: "callKitCorr=\(nativeCallCorrelation(action.callUUID.uuidString))"
      )
      pending.completion(.success(call))
    } catch {
      pendingOutgoingCalls.removeValue(forKey: action.callUUID)
      action.fail()
      pending.completion(.failure(error))
    }
  }

  func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
    nativeCallTrace(
      "mute_action_perform",
      callId: action.callUUID.uuidString,
      details: "muted=\(action.isMuted)"
    )
    core?.micEnabled = !action.isMuted
    action.fulfill()
  }

  func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
    nativeCallTrace(
      "hold_action_perform",
      callId: action.callUUID.uuidString,
      details: "held=\(action.isOnHold)"
    )
    guard let linphoneId = linphoneIdByCallKitUuid[action.callUUID],
          let call = findCallByLinphoneId?(linphoneId)
    else {
      NSLog(
        "Softphone/CallKit %@ action failed because the linked SIP call was unavailable",
        action.isOnHold ? "hold" : "resume"
      )
      action.fail()
      return
    }
    do {
      try setLinphoneCall(call, held: action.isOnHold)
      action.fulfill()
    } catch {
      NSLog(
        "Softphone/CallKit %@ action failed state=%@ error=%@",
        action.isOnHold ? "hold" : "resume",
        String(describing: call.state),
        error.localizedDescription
      )
      action.fail()
    }
  }

  private func setLinphoneCall(_ call: Call, held: Bool) throws {
    let state = call.state
    let key = ObjectIdentifier(call)
    if held {
      // A newer hold request supersedes any resume that was queued while the
      // previous hold re-INVITE was still being negotiated.
      pendingResumeAttempts.removeValue(forKey: key)
    }
    if held && (state == .Paused || state == .Pausing || state == .PausedByRemote) {
      NSLog("Softphone/CallKit hold already satisfied state=%@", String(describing: state))
      return
    }
    if !held && (state == .StreamsRunning || state == .Connected) {
      NSLog("Softphone/CallKit resume already satisfied state=%@", String(describing: state))
      return
    }

    do {
      if held {
        try call.pause()
      } else {
        if state == .Pausing {
          queueResumeAfterPause(call: call)
          return
        }
        try call.resume()
      }
      NSLog(
        "Softphone/CallKit %@ requested state=%@",
        held ? "hold" : "resume",
        String(describing: state)
      )
    } catch {
      NSLog(
        "Softphone/CallKit %@ failed state=%@ error=%@; trying SDP update",
        held ? "hold" : "resume",
        String(describing: state),
        error.localizedDescription
      )
      guard let core else { throw error }
      let params = try core.createCallParams(call: call)
      params.videoEnabled = false
      params.audioDirection = held ? .SendOnly : .SendRecv
      try call.update(params: params)
      NSLog(
        "Softphone/CallKit %@ SDP fallback requested",
        held ? "sendonly" : "sendrecv"
      )
    }
  }

  /// Applies the same serialized Linphone hold/resume behavior when CallKit is
  /// unavailable. This keeps the fallback path from reintroducing the race
  /// fixed in the managed CallKit path.
  func setLinphoneCallHeldDirectly(_ call: Call, held: Bool) throws {
    try setLinphoneCall(call, held: held)
  }

  private func queueResumeAfterPause(call: Call) {
    let key = ObjectIdentifier(call)
    guard pendingResumeAttempts[key] == nil else { return }
    pendingResumeAttempts[key] = 0
    NSLog("Softphone/CallKit queued resume until hold negotiation completes")
    nativeCallTrace(
      "resume_queued_during_pausing",
      callId: linphoneIdForCall?(call)
    )
    scheduleQueuedResumeCheck(call: call)
  }

  private func scheduleQueuedResumeCheck(call: Call) {
    let key = ObjectIdentifier(call)
    guard let attempt = pendingResumeAttempts[key] else { return }
    guard attempt < 25 else {
      forceResumeWithSdpUpdate(call: call)
      return
    }
    pendingResumeAttempts[key] = attempt + 1
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self, weak call] in
      guard let self, let call else { return }
      self.driveQueuedResumeIfNeeded(call: call)
    }
  }

  private func driveQueuedResumeIfNeeded(call: Call) {
    let key = ObjectIdentifier(call)
    guard pendingResumeAttempts[key] != nil else { return }
    switch call.state {
    case .Connected, .StreamsRunning:
      pendingResumeAttempts.removeValue(forKey: key)
    case .Paused:
      do {
        try call.resume()
        pendingResumeAttempts.removeValue(forKey: key)
        NSLog("Softphone/CallKit executed queued resume after pause completed")
        nativeCallTrace(
          "queued_resume_executed",
          callId: linphoneIdForCall?(call)
        )
      } catch {
        NSLog(
          "Softphone/CallKit queued resume failed error=%@; trying SDP recovery",
          error.localizedDescription
        )
        forceResumeWithSdpUpdate(call: call)
      }
    case .Pausing:
      scheduleQueuedResumeCheck(call: call)
    case .End, .Released, .Error:
      pendingResumeAttempts.removeValue(forKey: key)
    default:
      scheduleQueuedResumeCheck(call: call)
    }
  }

  private func forceResumeWithSdpUpdate(call: Call) {
    let key = ObjectIdentifier(call)
    pendingResumeAttempts.removeValue(forKey: key)
    guard let core else { return }
    do {
      let params = try core.createCallParams(call: call)
      params.videoEnabled = false
      params.audioDirection = .SendRecv
      try call.update(params: params)
      NSLog("Softphone/CallKit forced queued resume with sendrecv SDP update")
      nativeCallTrace(
        "queued_resume_sdp_recovery",
        callId: linphoneIdForCall?(call)
      )
    } catch {
      NSLog(
        "Softphone/CallKit queued resume SDP recovery failed error=%@",
        error.localizedDescription
      )
    }
  }

  private func presentIncomingCall(call: Call, linphoneId: String) {
    let remoteHandle = call.remoteAddress?.username
      ?? call.remoteAddress?.asStringUriOnly()
      ?? "Incoming call"
    let sipDisplayName = call.remoteAddress?.displayName
    let displayName = callerNamePreservingDialPrefix(
      IOSCallerIdentityStore.shared.cachedName(for: remoteHandle)
        ?? callerDisplayLabel(call.remoteAddress, fallback: remoteHandle),
      remoteHandle: remoteHandle,
      sourceDisplayName: sipDisplayName
    )

    if let existingUuid = callKitUuidByLinphoneId[linphoneId] {
      updateIncomingCall(
        uuid: existingUuid,
        remoteHandle: remoteHandle,
        displayName: displayName
      )
      resolveContactName(
        uuid: existingUuid,
        remoteHandle: remoteHandle,
        sourceDisplayName: sipDisplayName
      )
      return
    }

    let matchingPushUuid = pushCallIdByUuid.first(where: {
      $0.value == linphoneId
    })?.key ?? pushOnlyCallKitUuids.first(where: {
      pushCallIdByUuid[$0] == nil
    })
    if let pushUuid = matchingPushUuid {
      pushOnlyCallKitUuids.remove(pushUuid)
      pushCallIdByUuid.removeValue(forKey: pushUuid)
      linkCallKit(uuid: pushUuid, linphoneId: linphoneId, call: call)
      updateIncomingCall(
        uuid: pushUuid,
        remoteHandle: remoteHandle,
        displayName: displayName
      )
      resolveContactName(
        uuid: pushUuid,
        remoteHandle: remoteHandle,
        sourceDisplayName: sipDisplayName
      )
      return
    }

    let uuid = UUID()
    linkCallKit(uuid: uuid, linphoneId: linphoneId, call: call)
    reportIncomingCall(
      uuid: uuid,
      remoteHandle: remoteHandle,
      displayName: displayName,
      linphoneId: linphoneId,
      completion: { error in
        if let error {
          NSLog(
            "Softphone/CallKit failed to report incoming call: %@",
            error.localizedDescription
          )
        } else {
          NSLog("Softphone/CallKit reported incoming call id=%@", linphoneId)
          self.resolveContactName(
            uuid: uuid,
            remoteHandle: remoteHandle,
            sourceDisplayName: sipDisplayName
          )
        }
      }
    )
  }

  private func updateIncomingCall(
    uuid: UUID,
    remoteHandle: String,
    displayName: String?
  ) {
    let update = CXCallUpdate()
    update.remoteHandle = callKitHandle(for: remoteHandle)
    if let displayName = meaningfulCallerName(
      displayName,
      remoteHandle: remoteHandle
    ) {
      update.localizedCallerName = displayName
    }
    update.hasVideo = false
    provider.reportCall(with: uuid, updated: update)
  }

  private func resolveContactName(
    uuid: UUID,
    remoteHandle: String,
    sourceDisplayName: String? = nil
  ) {
    IOSCallerIdentityStore.shared.resolveContactName(for: callKitHandleValue(from: remoteHandle)) {
      [weak self] name in
      guard let self, let name, !name.isEmpty else { return }
      guard self.pushOnlyCallKitUuids.contains(uuid) ||
              self.linphoneIdByCallKitUuid[uuid] != nil else { return }
      self.updateIncomingCall(
        uuid: uuid,
        remoteHandle: remoteHandle,
        displayName: callerNamePreservingDialPrefix(
          name,
          remoteHandle: remoteHandle,
          sourceDisplayName: sourceDisplayName
        )
      )
    }
  }

  private func reportIncomingCall(
    uuid: UUID,
    remoteHandle: String,
    displayName: String?,
    linphoneId: String?,
    completion: @escaping (Error?) -> Void
  ) {
    let update = CXCallUpdate()
    update.remoteHandle = callKitHandle(for: remoteHandle)
    if let displayName = meaningfulCallerName(
      displayName,
      remoteHandle: remoteHandle
    ) {
      update.localizedCallerName = displayName
    }
    update.hasVideo = false
    if let linphoneId {
      linkCallKit(uuid: uuid, linphoneId: linphoneId)
    }
    provider.reportNewIncomingCall(with: uuid, update: update, completion: completion)
  }

  private func drivePendingAnswerIfNeeded(linphoneId: String) {
    guard let uuid = callKitUuidByLinphoneId[linphoneId] else { return }
    drivePendingAnswerIfNeeded(callKitUuid: uuid)
  }

  private func drivePendingAnswerIfNeeded(callKitUuid: UUID) {
    guard pendingAnswerCallUuids.contains(callKitUuid),
          let linphoneId = linphoneIdByCallKitUuid[callKitUuid],
          let call = findCallByLinphoneId?(linphoneId)
    else {
      return
    }
    if call.state == .Connected || call.state == .StreamsRunning {
      completePendingAnswerIfConnected(linphoneId: linphoneId)
      return
    }
    guard call.state == .PushIncomingReceived ||
            call.state == .IncomingReceived ||
            call.state == .IncomingEarlyMedia,
          answerAcceptanceStarted.insert(callKitUuid).inserted else {
      return
    }
    do {
      try call.accept()
      NSLog("Softphone/CallKit accepted incoming SIP call; awaiting connection")
    } catch {
      failPendingAnswer(uuid: callKitUuid)
      reportCallEnded(uuid: callKitUuid, reason: .failed)
      NSLog("Softphone/CallKit failed to accept incoming call: %@", error.localizedDescription)
    }
  }

  private func acceptAllPendingAnswers() {
    for uuid in Array(pendingAnswerCallUuids) {
      drivePendingAnswerIfNeeded(callKitUuid: uuid)
    }
  }

  private func completePendingAnswerIfConnected(linphoneId: String) {
    guard let uuid = callKitUuidByLinphoneId[linphoneId],
          pendingAnswerCallUuids.remove(uuid) != nil else { return }
    answerAcceptanceStarted.remove(uuid)
    nativeCallTrace(
      "incoming_sip_answer_connected",
      callId: linphoneId,
      details: "callKitCorr=\(nativeCallCorrelation(uuid.uuidString))"
    )
    NSLog("Softphone/CallKit incoming SIP answer connected")
  }

  private func failPendingAnswer(linphoneId: String) {
    guard let uuid = callKitUuidByLinphoneId[linphoneId] else { return }
    failPendingAnswer(uuid: uuid)
  }

  private func failPendingAnswer(uuid: UUID) {
    answerAcceptanceStarted.remove(uuid)
    if pendingAnswerCallUuids.remove(uuid) != nil {
      nativeCallTrace("answer_action_failed", callId: uuid.uuidString)
    }
  }

  private func end(call: Call) {
    do {
      if call.state == .IncomingReceived || call.state == .IncomingEarlyMedia {
        try call.decline(reason: .Declined)
      } else {
        try call.terminate()
      }
    } catch {
      NSLog("Softphone/CallKit failed to end call: %@", error.localizedDescription)
    }
  }

  private func endCallKitCall(linphoneId: String) {
    if let uuid = callKitUuidByLinphoneId.removeValue(forKey: linphoneId) {
      linphoneIdByCallKitUuid.removeValue(forKey: uuid)
      failPendingAnswer(uuid: uuid)
      pushOnlyCallKitUuids.remove(uuid)
      pushCallIdByUuid.removeValue(forKey: uuid)
      callKitUuidByCallObject = callKitUuidByCallObject.filter { $0.value != uuid }
      reportCallEnded(uuid: uuid, reason: .remoteEnded)
    }

    // Defensive cleanup for placeholders created by duplicate pushes before the
    // real Linphone call was linked. These must not keep ringing after CANCEL.
    let orphanUuids = pushOnlyCallKitUuids
    pushOnlyCallKitUuids.removeAll()
    for orphanUuid in orphanUuids {
      failPendingAnswer(uuid: orphanUuid)
      pushCallIdByUuid.removeValue(forKey: orphanUuid)
      reportCallEnded(uuid: orphanUuid, reason: .remoteEnded)
    }
  }

  private func reportCallEnded(uuid: UUID, reason: CXCallEndedReason) {
    provider.reportCall(with: uuid, endedAt: Date(), reason: reason)
  }

  private func linkCallKit(uuid: UUID, linphoneId: String, call: Call? = nil) {
    if let previousUuid = callKitUuidByLinphoneId[linphoneId], previousUuid != uuid {
      linphoneIdByCallKitUuid.removeValue(forKey: previousUuid)
    }
    if let previousLinphoneId = linphoneIdByCallKitUuid[uuid], previousLinphoneId != linphoneId {
      callKitUuidByLinphoneId.removeValue(forKey: previousLinphoneId)
    }
    callKitUuidByLinphoneId[linphoneId] = uuid
    linphoneIdByCallKitUuid[uuid] = linphoneId
    if let call {
      callKitUuidByCallObject[ObjectIdentifier(call)] = uuid
    }
    nativeCallTrace(
      "callkit_sip_linked",
      callId: linphoneId,
      details: "callKitCorr=\(nativeCallCorrelation(uuid.uuidString)) hasCall=\(call == nil ? "false" : "true")"
    )
  }

  private func callerValue(from payload: [AnyHashable: Any]) -> String {
    // Prefer an E.164 caller number supplied by the push gateway. A phone-number
    // CXHandle lets iOS resolve the native incoming-call name from Contacts.
    for key in [
      "caller_number",
      "caller-number",
      "callerNumber",
      "voipcloud.caller_number",
      "voipcloud.caller-number",
      "voipcloud.callerNumber",
      "from",
      "from-uri",
      "from_uri",
      "caller",
      "caller_id",
      "aps.alert.title"
    ] {
      if let value = value(for: key, in: payload), !value.isEmpty {
        return value
      }
    }
    return "Incoming call"
  }

  private func displayName(from payload: [AnyHashable: Any]) -> String? {
    for key in [
      "caller_name",
      "from_name",
      "from-name",
      "display_name",
      "display-name",
      "displayName",
      "voipcloud.caller_name",
      "voipcloud.display_name",
      "aps.alert.subtitle"
    ] {
      if let value = value(for: key, in: payload), !value.isEmpty {
        return value
      }
    }
    return nil
  }

  private func pushCallId(from payload: [AnyHashable: Any]) -> String? {
    for key in ["call_id", "call-id", "callId", "voipcloud.call_id"] {
      if let value = value(for: key, in: payload), !value.isEmpty {
        return value
      }
    }
    return nil
  }

  private func callKitHandle(for rawValue: String) -> CXHandle {
    let value = callKitHandleValue(from: rawValue)
    let allowed = CharacterSet(charactersIn: "+0123456789 ()-.\u{00a0}")
    let isTelephone = !value.isEmpty
      && value.unicodeScalars.allSatisfy { allowed.contains($0) }
      && value.unicodeScalars.contains {
        CharacterSet.decimalDigits.contains($0)
      }
    let type: CXHandle.HandleType = isTelephone ? .phoneNumber : .generic
    return CXHandle(type: type, value: value)
  }

  private func callKitHandleValue(from rawValue: String) -> String {
    var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.hasPrefix("<") && value.hasSuffix(">") {
      value = String(value.dropFirst().dropLast())
    }
    if value.lowercased().hasPrefix("sip:") || value.lowercased().hasPrefix("sips:") {
      value = String(value.dropFirst(value.lowercased().hasPrefix("sips:") ? 5 : 4))
      value = value.split(separator: "@", maxSplits: 1).first.map(String.init) ?? value
    }
    return (value.removingPercentEncoding ?? value)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func meaningfulCallerName(
    _ displayName: String?,
    remoteHandle: String
  ) -> String? {
    guard let displayName else { return nil }
    let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let handle = callKitHandleValue(from: remoteHandle)
    return trimmed.caseInsensitiveCompare(handle) == .orderedSame ? nil : trimmed
  }

  private func value(for keyPath: String, in payload: [AnyHashable: Any]) -> String? {
    let parts = keyPath.split(separator: ".").map(String.init)
    var current: Any? = payload
    for part in parts {
      guard let dictionary = current as? [AnyHashable: Any] else { return nil }
      current = dictionary[part]
    }
    if let string = current as? String {
      return string.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if let number = current as? NSNumber {
      return number.stringValue
    }
    return nil
  }
}

private final class NativeLinphoneController: LinphoneController {
  private static let mobileRegistrationExpiresSeconds = 604_800

  private let registrationEvents: LinphoneEventStreamHandler
  private let callEvents: LinphoneEventStreamHandler
  private let messageEvents: LinphoneEventStreamHandler
  private let sipLogEvents: LinphoneEventStreamHandler
  private let presenceEvents: LinphoneEventStreamHandler

  private var core: Core?
  private var account: Account?
  private var isReplacingAccount = false
  private var explicitUnregisterRequested = false
  private var delegate: CoreDelegateStub?
  private var calls: [String: Call] = [:]
  private var presenceSubscriptions: [ObjectIdentifier: (Event, String, String)] = [:]
  private var featureCodeCalls = Set<ObjectIdentifier>()
  private var featureCodeTerminateScheduled = Set<ObjectIdentifier>()
  private var featureCodePreviousMicEnabled: Bool?
  private var pendingFeatureCodeDial = false
  private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid
  private var isAppInBackground = false
  private var pushTokenObserver: NSObjectProtocol?
  private var audioSessionRouteObserver: NSObjectProtocol?
  private var audioRouteCallId: String?
  private var requestedAudioRoute = "earpiece"
  private var requestedAudioEndpointId: String?
  private var lastAudioDeviceEventFingerprint: String?
  private var lastReconciledAudioEndpointsFingerprint: String?
  private var callStartedAtByObject: [ObjectIdentifier: Date] = [:]
  private var callStartedAtById: [String: Date] = [:]
  private var lastCallEventFingerprintById: [String: String] = [:]
  private var terminalCallIds = Set<String>()
  private var sipLoggingEnabled = false
  private let sipLogFileLock = NSLock()
  private let maxSipLogBytes = 1_500_000

  init(
    registrationEvents: LinphoneEventStreamHandler,
    callEvents: LinphoneEventStreamHandler,
    messageEvents: LinphoneEventStreamHandler,
    sipLogEvents: LinphoneEventStreamHandler,
    presenceEvents: LinphoneEventStreamHandler
  ) {
    self.registrationEvents = registrationEvents
    self.callEvents = callEvents
    self.messageEvents = messageEvents
    self.sipLogEvents = sipLogEvents
    self.presenceEvents = presenceEvents
    pushTokenObserver = NotificationCenter.default.addObserver(
      forName: .softphoneVoipPushTokenUpdated,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      self?.refreshRegistrationAfterPushTokenUpdate(
        payload: notification.userInfo ?? [:]
      )
    }
    audioSessionRouteObserver = NotificationCenter.default.addObserver(
      forName: AVAudioSession.routeChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard let self else { return }
      let reasonValue = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?
        .uintValue
      let reason = reasonValue.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
      switch reason {
      case .newDeviceAvailable, .oldDeviceUnavailable:
        self.reconcileAudioDevices(reason: "avs-\(String(describing: reason))")
      default:
        break
      }
    }
  }

  deinit {
    if let pushTokenObserver {
      NotificationCenter.default.removeObserver(pushTokenObserver)
    }
    if let audioSessionRouteObserver {
      NotificationCenter.default.removeObserver(audioSessionRouteObserver)
    }
    endBackgroundTaskIfNeeded()
  }

  func prepareForVoipWakes() {
    do {
      try initialize()
      restoreSavedAccountIfNeeded()
      NSLog("Softphone/Linphone prepared native core for VoIP wakes")
    } catch {
      NSLog(
        "Softphone/Linphone failed to prepare native core for VoIP wakes: %@",
        error.localizedDescription
      )
    }
  }

  func handleWillResignActive() {
    SoftphoneCallKitController.shared.setSuppressCallKitUi(false)
  }

  func handleEnterBackground() {
    guard !isAppInBackground else { return }
    isAppInBackground = true
    SoftphoneCallKitController.shared.setSuppressCallKitUi(false)
    NSLog("Softphone/Linphone app entering background")
    core?.enterBackground()
  }

  func handleEnterForeground() {
    guard isAppInBackground else { return }
    isAppInBackground = false
    SoftphoneCallKitController.shared.setSuppressCallKitUi(true)
    NSLog("Softphone/Linphone app entering foreground")
    endBackgroundTaskIfNeeded()
    core?.enterForeground()
    syncCurrentCall(reason: "enter-foreground")
  }

  private func refreshRegistration(reason: String) {
    guard let currentAccount = account ?? core?.defaultAccount else { return }
    currentAccount.refreshRegister()
    NSLog("Softphone/Linphone refreshed registration reason=%@", reason)
  }

  private func refreshRegistrationAfterPushTokenUpdate(payload: [AnyHashable: Any]) {
    guard let currentCore = core,
          let currentAccount = account ?? currentCore.defaultAccount,
          let params = currentAccount.params
    else {
      return
    }

    let token = (payload["token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let provider = (payload["provider"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !token.isEmpty, !provider.isEmpty else { return }

    let param =
      (payload["param"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
      ?? ""
    guard let contactParameters = pushContactUriParameters(
      provider: provider,
      token: token,
      param: param
    ) else {
      NSLog("Softphone/Linphone cannot refresh push registration because push parameters are invalid")
      return
    }
    var pushPayload: [String: String] = [
      "token": token,
      "provider": provider
    ]
    if let param = (payload["param"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
       !param.isEmpty {
      pushPayload["param"] = param
    }
    if let bundleId = (payload["bundleId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
       !bundleId.isEmpty {
      pushPayload["bundleId"] = bundleId
    }
    if let teamId = (payload["teamId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
       !teamId.isEmpty {
      pushPayload["teamId"] = teamId
    }
    SipCredentialStore.mergePushToken(pushPayload)
    guard params.contactUriParameters != contactParameters else {
      NSLog("Softphone/Linphone PushKit token already present on SIP account")
      return
    }
    guard let updatedParams = params.clone() else {
      NSLog("Softphone/Linphone cannot clone account params for push-token update")
      return
    }
    // PushKit is managed by VoipPushRegistry. Add the RFC 8599 parameters
    // directly instead of enabling liblinphone's second PushKit registry.
    updatedParams.pushNotificationAllowed = false
    updatedParams.remotePushNotificationAllowed = false
    updatedParams.contactUriParameters = contactParameters
    currentAccount.params = updatedParams
    refreshRegistration(reason: "push-token-updated")
  }

  private func beginBackgroundTaskIfNeeded() {
    guard backgroundTaskId == .invalid else { return }
    backgroundTaskId = UIApplication.shared.beginBackgroundTask(withName: "SoftphoneSipRefresh") {
      [weak self] in
      self?.endBackgroundTaskIfNeeded()
    }
  }

  private func endBackgroundTaskIfNeeded() {
    guard backgroundTaskId != .invalid else { return }
    UIApplication.shared.endBackgroundTask(backgroundTaskId)
    backgroundTaskId = .invalid
  }

  func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    if [
      "makeCall", "acceptCall", "rejectCall", "endCall", "mute", "hold",
      "resume", "setAudioRoute", "setSpeaker", "setBluetooth", "syncCurrentCall"
    ].contains(call.method) {
      let arguments = call.arguments as? [String: Any]
      let identity = arguments?["callId"] as? String
        ?? arguments?["destination"] as? String
      nativeCallTrace(
        "flutter_method_received",
        callId: identity,
        details: "method=\(call.method)"
      )
    }
    do {
      switch call.method {
      case "initialize":
        try initialize()
        result(nil)
      case "configureAccount":
        try configureAccount(args: call.arguments as? [String: Any] ?? [:])
        result(nil)
      case "register":
        restoreSavedAccountIfNeeded()
        account = account ?? core?.defaultAccount
        if let currentAccount = account,
           currentAccount.params?.registerEnabled == true,
           currentAccount.state == .Progress {
          NSLog("Softphone/Linphone register request joined registration in progress")
          emitRegistration(
            state: .Progress,
            message: "Registration in progress"
          )
          // Adding a newly provisioned account starts REGISTER automatically.
          // If that first transaction stalls, a later Flutter retry used to
          // keep joining the same Progress state forever. Give the transaction
          // a short chance to finish, then force one refresh only if this is
          // still the active, enabled account and it is still in Progress.
          DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self,
                  let activeAccount = self.account ?? self.core?.defaultAccount,
                  ObjectIdentifier(activeAccount) == ObjectIdentifier(currentAccount),
                  activeAccount.params?.registerEnabled == true,
                  activeAccount.state == .Progress,
                  !self.hasActiveCall() else {
              return
            }
            activeAccount.refreshRegister()
            NSLog("Softphone/Linphone recovered stalled initial SIP registration")
          }
          result(nil)
          return
        }
        if account?.params?.registerEnabled != true {
          try updateRegistration(enabled: true)
        }
        if let currentAccount = account {
          currentAccount.refreshRegister()
          NSLog(
            "Softphone/Linphone explicit registration refresh state=%@",
            String(describing: currentAccount.state)
          )
        }
        result(nil)
      case "syncCurrentCall":
        syncCurrentCall(reason: "dart-sync")
        result(nil)
      case "hasActiveCall":
        result(hasActiveCall())
      case "enterBackground":
        handleEnterBackground()
        result(nil)
      case "enterForeground":
        handleEnterForeground()
        result(nil)
      case "updateDirectoryCache":
        IOSCallerIdentityStore.shared.updateDirectory(
          arguments: call.arguments as? [String: Any] ?? [:]
        )
        result(nil)
      case "setNativeDnd":
        let arguments = call.arguments as? [String: Any]
        SipCredentialStore.setDndEnabled(arguments?["enabled"] as? Bool ?? false)
        result(nil)
      case "unregister":
        stopPresenceSubscriptions()
        explicitUnregisterRequested = true
        account = account ?? core?.defaultAccount
        guard account != nil else {
          explicitUnregisterRequested = false
          registrationEvents.send(["status": "unregistered", "message": nil])
          result(nil)
          return
        }
        if account?.state == .Cleared {
          explicitUnregisterRequested = false
          registrationEvents.send(["status": "unregistered", "message": nil])
          result(nil)
          return
        }
        try updateRegistration(enabled: false)
        account?.refreshRegister()
        result(nil)
      case "purgeAccount":
        purgeAccount()
        result(nil)
      case "makeCall":
        try makeCall(
          destination: argument(call, "destination"),
          completion: { error in
            if let error {
              result(FlutterError(
                code: "CALL_START_FAILED",
                message: error.localizedDescription,
                details: nil
              ))
            } else {
              result(nil)
            }
          }
        )
      case "dialFeatureCode":
        result(try dialFeatureCode(code: argument(call, "code")))
      case "acceptCall":
        guard let incomingCall = findCall(id: argument(call, "callId")),
              isIncomingRinging(incomingCall)
        else {
          throw NSError(
            domain: "SoftphoneLinphone",
            code: 1003,
            userInfo: [NSLocalizedDescriptionKey: "This incoming call has already ended."]
          )
        }
        if SoftphoneCallKitController.shared.requestAnswerFromApp(
          call: incomingCall,
          completion: { error in
            if let error {
              NSLog(
                "Softphone/CallKit answer transaction failed; using direct Linphone answer: %@",
                error.localizedDescription
              )
              guard self.isIncomingRinging(incomingCall) else {
                result(FlutterError(
                  code: "CALL_ALREADY_ENDED",
                  message: "This incoming call has already ended.",
                  details: nil
                ))
                return
              }
              SoftphoneCallKitController.shared
                .prepareDirectAnswerAfterCallKitFailure(call: incomingCall)
              do {
                try incomingCall.accept()
                result(nil)
              } catch {
                result(FlutterError(
                  code: "CALL_ACCEPT_FAILED",
                  message: error.localizedDescription,
                  details: nil
                ))
              }
              return
            }
            result(nil)
          }
        ) {
          return
        }
        SoftphoneCallKitController.shared.configureAudioSessionForCall()
        try incomingCall.accept()
        result(nil)
      case "rejectCall":
        if let activeCall = findCall(id: argument(call, "callId")),
           SoftphoneCallKitController.shared.requestEndFromApp(
             call: activeCall,
             completion: { error in
               if let error {
                 if SoftphoneCallKitController.shared.isCallManaged(activeCall) {
                   self.returnCallControlError(
                     result: result,
                     code: "CALL_REJECT_FAILED",
                     error: error
                   )
                   return
                 }
                 do {
                   if activeCall.state == .IncomingReceived ||
                      activeCall.state == .IncomingEarlyMedia {
                     try activeCall.decline(reason: .Declined)
                   } else {
                     try activeCall.terminate()
                   }
                   NSLog(
                     "Softphone/CallKit reject transaction failed; direct SIP fallback requested: %@",
                     error.localizedDescription
                   )
                   result(nil)
                 } catch {
                   self.returnCallControlError(
                     result: result,
                     code: "CALL_REJECT_FAILED",
                     error: error
                   )
                 }
               } else {
                 result(nil)
               }
             }
           ) {
          return
        }
        try findCall(id: argument(call, "callId"))?.decline(reason: .Declined)
        result(nil)
      case "endCall":
        if let activeCall = findCall(id: argument(call, "callId")),
           SoftphoneCallKitController.shared.requestEndFromApp(
             call: activeCall,
             completion: { error in
               if let error {
                 if SoftphoneCallKitController.shared.isCallManaged(activeCall) {
                   self.returnCallControlError(
                     result: result,
                     code: "CALL_END_FAILED",
                     error: error
                   )
                   return
                 }
                 do {
                   try activeCall.terminate()
                   NSLog(
                     "Softphone/CallKit end transaction failed; direct SIP fallback requested: %@",
                     error.localizedDescription
                   )
                   result(nil)
                 } catch {
                   self.returnCallControlError(
                     result: result,
                     code: "CALL_END_FAILED",
                     error: error
                   )
                 }
               } else {
                 result(nil)
               }
             }
           ) {
          return
        }
        try findCall(id: argument(call, "callId"))?.terminate()
        result(nil)
      case "mute":
        let muted = boolArgument(call, "enabled")
        if let activeCall = findCurrentCall(),
           SoftphoneCallKitController.shared.requestMuteFromApp(
             call: activeCall,
             muted: muted,
             completion: { error in
               if let error {
                 if SoftphoneCallKitController.shared.isCallManaged(activeCall) {
                   self.returnCallControlError(
                     result: result,
                     code: "CALL_MUTE_FAILED",
                     error: error
                   )
                   return
                 }
                 self.core?.micEnabled = !muted
                 NSLog(
                   "Softphone/CallKit mute transaction failed; direct SIP fallback applied: %@",
                   error.localizedDescription
                 )
                 result(nil)
               } else {
                 result(nil)
               }
             }
           ) {
          return
        }
        core?.micEnabled = !muted
        result(nil)
      case "hold":
        if let activeCall = findCall(id: argument(call, "callId")),
           SoftphoneCallKitController.shared.requestHeldFromApp(
             call: activeCall,
             held: true,
             completion: { error in
               if let error {
                 if SoftphoneCallKitController.shared.isCallManaged(activeCall) {
                   self.returnCallControlError(
                     result: result,
                     code: "CALL_HOLD_FAILED",
                     error: error
                   )
                   return
                 }
                 do {
                   try self.holdCall(id: self.callId(activeCall))
                   NSLog(
                     "Softphone/CallKit hold transaction failed; direct SIP fallback requested: %@",
                     error.localizedDescription
                   )
                   result(nil)
                 } catch {
                   self.returnCallControlError(
                     result: result,
                     code: "CALL_HOLD_FAILED",
                     error: error
                   )
                 }
               } else {
                 result(nil)
               }
             }
           ) {
          return
        }
        try holdCall(id: argument(call, "callId"))
        result(nil)
      case "resume":
        if let activeCall = findCall(id: argument(call, "callId")),
           SoftphoneCallKitController.shared.requestHeldFromApp(
             call: activeCall,
             held: false,
             completion: { error in
               if let error {
                 if SoftphoneCallKitController.shared.isCallManaged(activeCall) {
                   self.returnCallControlError(
                     result: result,
                     code: "CALL_RESUME_FAILED",
                     error: error
                   )
                   return
                 }
                 do {
                   try self.resumeCall(id: self.callId(activeCall))
                   NSLog(
                     "Softphone/CallKit resume transaction failed; direct SIP fallback requested: %@",
                     error.localizedDescription
                   )
                   result(nil)
                 } catch {
                   self.returnCallControlError(
                     result: result,
                     code: "CALL_RESUME_FAILED",
                     error: error
                   )
                 }
               } else {
                 result(nil)
               }
             }
           ) {
          return
        }
        try resumeCall(id: argument(call, "callId"))
        result(nil)
      case "setSpeaker":
        _ = try setAudioRoute(
          route: boolArgument(call, "enabled") ? "speaker" : "earpiece"
        )
        result(nil)
      case "setBluetooth":
        _ = try setAudioRoute(
          route: boolArgument(call, "enabled") ? "bluetooth" : "earpiece"
        )
        result(nil)
      case "ensureBluetoothPermission":
        result(true)
      case "getAudioRoutes":
        result(getAudioRoutes())
      case "setAudioRoute":
        let args = call.arguments as? [String: Any]
        result(try setAudioRoute(
          route: argument(call, "route"),
          endpointId: args?["endpointId"] as? String
        ))
      case "sendDtmf":
        try findCurrentCall()?.sendDtmf(dtmf: firstDtmf(argument(call, "value")))
        result(nil)
      case "getCallQuality":
        result(try getCallQuality(callId: argument(call, "callId")))
      case "transferCall":
        try transferCall(
          callId: argument(call, "callId"),
          destination: argument(call, "destination")
        )
        result(nil)
      case "sendMessage":
        try sendMessage(
          destination: argument(call, "destination"),
          text: argument(call, "text")
        )
        result(nil)
      case "startPresenceSubscriptions":
        let args = call.arguments as? [String: Any] ?? [:]
        try startPresenceSubscriptions(
          extensions: args["extensions"] as? [String] ?? []
        )
        result(nil)
      case "stopPresenceSubscriptions":
        stopPresenceSubscriptions()
        result(nil)
      case "setSipLoggingEnabled":
        setSipLoggingEnabled(boolArgument(call, "enabled"))
        result(nil)
      case "appendSipLogLine":
        appendSipLogLine(argument(call, "line"))
        result(nil)
      case "readSipLogFile":
        result(readSipLogFile())
      case "clearSipLogFile":
        clearSipLogFile()
        result(nil)
      case "dispose":
        if hasActiveCall() {
          NSLog("Softphone/Linphone Skipping native core dispose while a call is active")
        } else {
          dispose()
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    } catch {
      nativeCallTrace(
        "flutter_method_failed",
        callId: (call.arguments as? [String: Any])?["callId"] as? String,
        details: "method=\(call.method) code=\((error as NSError).code)"
      )
      result(FlutterError(
        code: "LINPHONE_ERROR",
        message: error.localizedDescription,
        details: nil
      ))
    }
  }

  private func returnCallControlError(
    result: FlutterResult,
    code: String,
    error: Error
  ) {
    nativeCallTrace(
      "call_control_failed",
      details: "code=\(code) nativeCode=\((error as NSError).code)"
    )
    result(FlutterError(
      code: code,
      message: error.localizedDescription,
      details: nil
    ))
  }

  private func initialize() throws {
    guard core == nil else { return }
    let newCore = try Factory.Instance.createCore(
      configPath: nil,
      factoryConfigPath: nil,
      systemContext: nil
    )
    // A stable +sip.instance is mandatory for long-lived mobile contacts.
    // Without it, every process launch creates another seven-day Flexisip
    // binding for the same phone and incoming calls are forked back to the
    // device multiple times. Keep the rest of liblinphone's config ephemeral;
    // SIP credentials continue to be restored by the app-owned store.
    let sipInstanceUuid = SipCredentialStore.sipInstanceUuid()
    newCore.config?.setString(
      section: "misc",
      key: "uuid",
      value: sipInstanceUuid
    )
    NSLog(
      "Softphone/Linphone configured stable SIP instance correlation=%@",
      nativeCallCorrelation(sipInstanceUuid)
    )
    let appVersion =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      ?? "unknown"
    // Keep mobile registrations identifiable across platforms so Flexisip can
    // distinguish app traffic from the server-side B2BUA anchor.
    newCore.setUserAgent(name: "VoIPCloud-Mobile", version: appVersion)
    newCore.ipv6Enabled = true
    // PushKit is managed by VoipPushRegistry; avoid a second registry in the SDK.
    newCore.pushNotificationEnabled = false
    newCore.micEnabled = true
    // FreePBX/Asterisk: prefer sendonly hold SDP (not inactive).
    newCore.config?.setInt(section: "sip", key: "inactive_audio_on_pause", value: 0)
    newCore.avpfMode = .Disabled
    newCore.setTone(
      toneId: .CallEnd,
      audiofile: nil
    )

    let newDelegate = CoreDelegateStub(
        onCallStateChanged: { [weak self] _, call, state, message in
            guard let self else { return }
            let id = self.callId(call)
            let objectId = ObjectIdentifier(call)
            let staleIds = self.calls.compactMap { cachedId, cachedCall in
              ObjectIdentifier(cachedCall) == objectId && cachedId != id
                ? cachedId
                : nil
            }
            staleIds.forEach { self.calls.removeValue(forKey: $0) }
            self.calls[id] = call
            let featureKey = ObjectIdentifier(call)
            if self.pendingFeatureCodeDial {
              self.featureCodeCalls.insert(featureKey)
            }
            if self.featureCodeCalls.contains(featureKey) {
              self.maybeTerminateFeatureCodeCall(call: call, state: state)
              self.emitCall(
                call: call,
                state: state,
                featureCode: true,
                stateMessage: message
              )
              if self.isTerminalCallState(state) {
                self.clearFeatureCodeCall(call: call)
              }
              return
            }
            SoftphoneCallKitController.shared.handleCallStateChanged(call: call, state: state)
            self.prepareAudioRoute(call: call, state: state)
            self.emitCall(
              call: call,
              state: state,
              featureCode: false,
              stateMessage: message
            )
            self.releaseTerminalCallIfNeeded(call: call, state: state)
        }, onMessageReceived: { [weak self] _, _, message in
            self?.emitMessage(message: message, direction: "incoming", fallbackStatus: "delivered")
        }, onMessageSent: { [weak self] _, _, message in
            self?.emitMessage(message: message, direction: "outgoing", fallbackStatus: "sent")
        }, onSubscriptionStateChanged: { [weak self] _, event, state in
            self?.emitSubscriptionState(event: event, state: state)
        }, onNotifyReceived: { [weak self] _, event, notifiedEvent, body in
            self?.emitPresenceNotify(
                event: event,
                notifiedEvent: notifiedEvent,
                body: body
            )
        }, onAudioDeviceChanged: { [weak self] _, _ in
            guard let self, let call = self.findCurrentCall() else { return }
            let fingerprint = self.audioDeviceEventFingerprint()
            guard fingerprint != self.lastAudioDeviceEventFingerprint else { return }
            self.lastAudioDeviceEventFingerprint = fingerprint
            self.emitCall(call: call, state: call.state)
        }, onAudioDevicesListUpdated: { [weak self] _ in
            self?.reconcileAudioDevices(reason: "devices-updated")
        },
        onAccountRegistrationStateChanged: { [weak self] _, changedAccount, state, message in
            guard let self else { return }
            guard !self.isReplacingAccount else {
              NSLog("Softphone/Linphone ignored registration callback during account replacement")
              return
            }
            guard let activeAccount = self.account ?? self.core?.defaultAccount,
                  ObjectIdentifier(activeAccount) == ObjectIdentifier(changedAccount) else {
              NSLog("Softphone/Linphone ignored registration callback from stale account")
              return
            }
            if self.explicitUnregisterRequested && state == .Cleared {
              self.explicitUnregisterRequested = false
              NSLog("Softphone/Linphone explicit unregister completed")
              self.registrationEvents.send([
                "status": "unregistered",
                "message": message.isEmpty ? nil : message
              ])
              return
            }
            self.emitRegistration(state: state, message: message)
        }
    )

    newCore.addDelegate(delegate: newDelegate)
    try newCore.start()
    core = newCore
    delegate = newDelegate
    SoftphoneCallKitController.shared.attach(
      core: newCore,
      findCallByLinphoneId: { [weak self] id in
        self?.findCall(id: id)
      },
      linphoneIdForCall: { [weak self] call in
        self?.callId(call) ?? UUID().uuidString
      }
    )
    registrationEvents.send(["status": "unregistered", "message": nil])
  }

  private func configureAccount(args: [String: Any]) throws {
    if hasActiveCall() {
      NSLog("Softphone/Linphone skipping configureAccount while a call is active")
      return
    }
    try initialize()
    guard let currentCore = core else { return }

    var mergedArgs = args
    // Flutter can restore its session before PushKit has repeated the current
    // token callback. Preserve the last valid token for the same SIP identity
    // so the first REGISTER never replaces a push-capable contact with a
    // temporary tokenless one. PushKit's callback still refreshes rotations.
    if stringArg(mergedArgs, "pushToken").isEmpty,
       let saved = SipCredentialStore.load(),
       stringArg(saved, "sipUsername") == stringArg(mergedArgs, "sipUsername"),
       stringArg(saved, "domain") == stringArg(mergedArgs, "domain") {
      for key in [
        "pushProvider", "pushToken", "pushParam", "pushBundleId", "pushTeamId"
      ] {
        let value = stringArg(saved, key)
        if !value.isEmpty {
          mergedArgs[key] = value
        }
      }
    }
    if stringArg(mergedArgs, "pushToken").isEmpty,
       let tokenPayload = VoipPushRegistry.shared.currentPushPayload() {
      for (key, value) in tokenPayload {
        mergedArgs[key] = value
      }
    }

    let username = stringArg(mergedArgs, "sipUsername")
    let authUsernameValue = stringArg(mergedArgs, "authUsername")
    let authUsername = authUsernameValue.isEmpty ? username : authUsernameValue
    let password = stringArg(mergedArgs, "password")
    let ha1 = stringArg(mergedArgs, "ha1")
    let algorithm = stringArg(mergedArgs, "algorithm")
    let domain = stringArg(mergedArgs, "domain")
    let registrar = stringArg(mergedArgs, "registrar").isEmpty ? domain : stringArg(mergedArgs, "registrar")
    let realm = stringArg(mergedArgs, "realm").isEmpty ? domain : stringArg(mergedArgs, "realm")
    let authDomain = stringArg(mergedArgs, "authDomain").isEmpty ? realm : stringArg(mergedArgs, "authDomain")
    let outboundProxy = stringArg(mergedArgs, "outboundProxy")
    let stunServer = stringArg(mergedArgs, "stunServer")
    let turnServer = stringArg(mergedArgs, "turnServer")
    let pushProvider = stringArg(mergedArgs, "pushProvider")
    let pushToken = stringArg(mergedArgs, "pushToken")
    let pushParam = stringArg(mergedArgs, "pushParam")
    let pushBundleId = stringArg(mergedArgs, "pushBundleId")
    let pushTeamId = stringArg(mergedArgs, "pushTeamId")
    NSLog(
      "Softphone/Linphone configure account push provider=%@ hasToken=%@ param=%@ bundle=%@ team=%@",
      pushProvider.isEmpty ? "none" : pushProvider,
      pushToken.isEmpty ? "false" : "true",
      pushParam.isEmpty ? "none" : pushParam,
      pushBundleId.isEmpty ? "none" : pushBundleId,
      pushTeamId.isEmpty ? "none" : pushTeamId
    )

    // The native core restores the saved account before Flutter starts so an
    // incoming PushKit wake has a SIP account ready. Flutter subsequently
    // supplies the same account. Updating the restored object avoids an old
    // account unregister racing and removing the replacement push contact.
    if let currentAccount = account ?? currentCore.defaultAccount,
       let saved = SipCredentialStore.load(),
       isSameSipConfiguration(saved, mergedArgs),
       let params = currentAccount.params {
      let previousPushContact = params.contactUriParameters
      let desiredPushContact = pushContactUriParameters(
        provider: pushProvider,
        token: pushToken,
        param: pushParam
      )
      let pushContactChanged = previousPushContact != desiredPushContact
      let expiryChanged = params.expires != Self.mobileRegistrationExpiresSeconds
      try configureNatPolicy(
        core: currentCore,
        stunServer: stunServer,
        turnServer: turnServer
      )
      account = currentAccount
      currentCore.defaultAccount = currentAccount
      SipCredentialStore.save(mergedArgs)

      // Merely assigning Account.params interrupts an in-flight REGISTER.
      // Leave an unchanged restored account completely untouched and replay
      // its authoritative native state to Flutter instead.
      if !pushContactChanged && !expiryChanged {
        emitRegistration(
          state: currentAccount.state,
          message: currentAccount.state == .Ok
            ? "Registration already active"
            : "Using restored SIP account"
        )
        NSLog("Softphone/Linphone reused restored SIP account without mutation")
        return
      }

      guard let updatedParams = params.clone() else {
        throw NSError(
          domain: "SoftphoneLinphone",
          code: 1012,
          userInfo: [NSLocalizedDescriptionKey: "Unable to update SIP account parameters."]
        )
      }
      updatedParams.expires = Self.mobileRegistrationExpiresSeconds
      configurePushNotifications(
        params: updatedParams,
        core: currentCore,
        provider: pushProvider,
        token: pushToken,
        param: pushParam,
        bundleId: pushBundleId,
        teamId: pushTeamId
      )
      currentAccount.params = updatedParams
      if pushContactChanged || expiryChanged {
        currentAccount.refreshRegister()
        emitRegistration(
          state: .Progress,
          message: "Refreshing SIP registration"
        )
        NSLog(
          "Softphone/Linphone refreshed REGISTER pushChanged=%@ expiryChanged=%@",
          pushContactChanged ? "true" : "false",
          expiryChanged ? "true" : "false"
        )
      }
      return
    }

    isReplacingAccount = true
    defer { isReplacingAccount = false }

    account = nil
    currentCore.clearAccounts()
    currentCore.clearAllAuthInfo()
    try configureNatPolicy(core: currentCore, stunServer: stunServer, turnServer: turnServer)

    let passwordValue: String? = password.isEmpty ? nil : password
    let ha1Value: String? = ha1.isEmpty ? nil : ha1
    let algorithmValue: String? = algorithm.isEmpty ? nil : algorithm
    let authInfo = try Factory.Instance.createAuthInfo(
      username: authUsername,
      userid: username,
      passwd: passwordValue,
      ha1: ha1Value,
      realm: realm,
      domain: authDomain,
      algorithm: algorithmValue
    )
    currentCore.addAuthInfo(info: authInfo)
    #if DEBUG
    NSLog(
      "VoIPCloud/Linphone Added SIP auth info username=%@ userid=%@ realm=%@ authDomain=%@ hasPassword=%@ hasHa1=%@ algorithm=%@",
      authUsername,
      username,
      realm,
      authDomain,
      password.isEmpty ? "false" : "true",
      ha1.isEmpty ? "false" : "true",
      algorithm.isEmpty ? "default" : algorithm
    )
    #endif

    let identity = try Factory.Instance.createAddress(addr: "sip:\(username)@\(domain)")
    let displayName = stringArg(mergedArgs, "displayName")
    if !displayName.isEmpty {
      try identity.setDisplayname(newValue: displayName)
    }

    // Liblinphone sends REGISTER to serverAddress; routesAddresses only routes
    // calls. Point serverAddress at Flexisip so it receives the push contact.
    let serverAddress = try Factory.Instance.createAddress(
      addr: normalizeSipAddress(outboundProxy.isEmpty ? registrar : outboundProxy)
    )
    try serverAddress.setTransport(newValue: transportType(stringArg(mergedArgs, "transport")))

    let params = try currentCore.createAccountParams()
    try params.setIdentityaddress(newValue: identity)
    try params.setServeraddress(newValue: serverAddress)
    // Keep the PushKit contact available while iOS suspends the process. This
    // matches the Flexisip registrar's seven-day max-expires policy.
    params.expires = Self.mobileRegistrationExpiresSeconds
    params.outboundProxyEnabled = !outboundProxy.isEmpty
    params.registerEnabled = true
    configurePushNotifications(
      params: params,
      core: currentCore,
      provider: pushProvider,
      token: pushToken,
      param: pushParam,
      bundleId: pushBundleId,
      teamId: pushTeamId
    )

    let newAccount = try currentCore.createAccount(params: params)
    account = newAccount
    try currentCore.addAccount(account: newAccount)
    currentCore.defaultAccount = newAccount
    NSLog(
      "VoIPCloud/Linphone Account signaling configuredRegistrar=%@ server=%@ edgeProxy=%@ outboundProxyMode=%@",
      normalizeSipAddress(registrar),
      serverAddress.asStringUriOnly(),
      outboundProxy.isEmpty ? "false" : "true",
      params.outboundProxyEnabled ? "true" : "false"
    )
    #if DEBUG
    NSLog(
      "VoIPCloud/Linphone Configured SIP account identity=%@ registrar=%@ server=%@ edge=%@ routingMode=%@ stun=%@ turn=%@",
      identity.asStringUriOnly(),
      normalizeSipAddress(registrar),
      serverAddress.asStringUriOnly(),
      outboundProxy.isEmpty ? "none" : outboundProxy,
      outboundProxy.isEmpty ? "registrar-direct" : "edge-proxy",
      stunServer.isEmpty ? "none" : stunServer,
      turnServer.isEmpty ? "none" : turnServer
    )
    #endif
    SipCredentialStore.save(mergedArgs)
    registrationEvents.send(["status": "configuring", "message": "SIP account configured"])
  }

  private func restoreSavedAccountIfNeeded() {
    guard let currentCore = core else { return }
    if !currentCore.accountList.isEmpty {
      account = currentCore.defaultAccount ?? currentCore.accountList.first
      enforceMobileRegistrationExpiry()
      return
    }
    guard let saved = SipCredentialStore.load() else { return }
    NSLog("Softphone/Linphone restoring saved SIP account after process restart")
    do {
      try configureAccount(args: saved)
    } catch {
      NSLog(
        "Softphone/Linphone failed to restore saved SIP account: %@",
        error.localizedDescription
      )
    }
  }

  private func isSameSipConfiguration(
    _ saved: [String: Any],
    _ incoming: [String: Any]
  ) -> Bool {
    let keys = [
      "sipUsername", "authUsername", "password", "ha1", "algorithm",
      "domain", "registrar", "realm", "authDomain", "outboundProxy",
      "transport", "stunServer", "turnServer"
    ]
    return keys.allSatisfy { key in
      stringArg(saved, key).caseInsensitiveCompare(stringArg(incoming, key)) == .orderedSame
    }
  }

  private func enforceMobileRegistrationExpiry() {
    guard let currentAccount = account,
          let params = currentAccount.params,
          params.expires != Self.mobileRegistrationExpiresSeconds else {
      return
    }
    guard let updatedParams = params.clone() else { return }
    updatedParams.expires = Self.mobileRegistrationExpiresSeconds
    currentAccount.params = updatedParams
    currentAccount.refreshRegister()
    NSLog(
      "Softphone/Linphone migrated SIP registration expiry to %d seconds",
      Self.mobileRegistrationExpiresSeconds
    )
  }

  func wakeFromPush(payload: [AnyHashable: Any]) {
    do {
      beginBackgroundTaskIfNeeded()
      try initialize()
      core?.enterForeground()
      restoreSavedAccountIfNeeded()
      account = account ?? core?.defaultAccount
      // A foreground/live SIP call is already authoritative. Refreshing its
      // registration in response to the delayed wake push can make a fork-late
      // proxy deliver the same INVITE again, causing a second busy-rejected call.
      if hasActiveCall() {
        NSLog("Softphone/Linphone VoIP push matched an existing live call; skipping SIP wake")
        syncCurrentCall(reason: "voip-push-existing-call")
        endBackgroundTaskIfNeeded()
        return
      }
      // Prefer Liblinphone's targeted push wake when the payload identifies the
      // INVITE. Otherwise the guarded registration refresh below is the safe
      // fallback that lets Flexisip's fork-late route deliver the held call.
      // The Swift binding accepts an optional String, but the native
      // linphone_core_process_push_notification implementation dereferences
      // the value. Flexisip wake payloads do not currently include the SIP
      // Call-ID, so never pass nil through to the C API (strlen(NULL)). The
      // registration refresh below still releases the fork-late INVITE.
      if let callId = pushCallId(from: payload) {
        core?.processPushNotification(callId: callId)
      } else {
        NSLog(
          "Softphone/Linphone VoIP push has no SIP Call-ID; using registration wake"
        )
      }
      if let tokenPayload = VoipPushRegistry.shared.currentPushPayload() {
        refreshRegistrationAfterPushTokenUpdate(payload: tokenPayload)
      } else {
        refreshRegistration(reason: "voip-push")
      }
      registrationEvents.send([
        "status": "registering",
        "message": "VoIP push received; waking SIP core"
      ])
      #if DEBUG
      NSLog(
        "Softphone/Linphone woke core from VoIP push keys=%@",
        payload.keys.map { String(describing: $0) }.joined(separator: ",")
      )
      #endif
      syncCurrentCall(reason: "voip-push")
      DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
        self?.endBackgroundTaskIfNeeded()
      }
    } catch {
      NSLog("Softphone/Linphone failed to wake core from VoIP push: %@", error.localizedDescription)
      endBackgroundTaskIfNeeded()
    }
  }

  private func pushCallId(from payload: [AnyHashable: Any]) -> String? {
    for key in ["call-id", "call_id", "callId", "call-id-hash"] {
      if let value = payload[key] as? String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
      }
    }
    return nil
  }

  private func configurePushNotifications(
    params: AccountParams,
    core currentCore: Core,
    provider: String,
    token: String,
    param: String,
    bundleId: String,
    teamId: String
  ) {
    guard !provider.isEmpty, !token.isEmpty else {
      params.pushNotificationAllowed = false
      params.remotePushNotificationAllowed = false
      NSLog("Softphone/Linphone push disabled because provider/token is missing")
      return
    }

    guard let contactParameters = pushContactUriParameters(
      provider: provider,
      token: token,
      param: param
    ) else {
      params.pushNotificationAllowed = false
      params.remotePushNotificationAllowed = false
      NSLog("Softphone/Linphone push disabled because push parameters are invalid")
      return
    }
    params.pushNotificationAllowed = false
    params.remotePushNotificationAllowed = false
    params.contactUriParameters = contactParameters
    NSLog(
      "Softphone/Linphone manual push contact enabled provider=%@ param=%@ bundle=%@ team=%@",
      provider,
      param.isEmpty ? "none" : param,
      (bundleId.isEmpty ? (Bundle.main.bundleIdentifier ?? "com.thinkswift.softphoneapp") : bundleId),
      teamId.isEmpty ? "none" : teamId
    )
  }

  private func pushContactUriParameters(
    provider: String,
    token: String,
    param: String
  ) -> String? {
    let allowed = CharacterSet.alphanumerics.union(
      CharacterSet(charactersIn: "-._~")
    )
    guard !provider.isEmpty,
          !token.isEmpty,
          !param.isEmpty,
          let encodedProvider = provider.addingPercentEncoding(
            withAllowedCharacters: allowed
          ),
          let encodedToken = token.addingPercentEncoding(
            withAllowedCharacters: allowed
          ),
          let encodedParam = param.addingPercentEncoding(
            withAllowedCharacters: allowed
          )
    else {
      return nil
    }
    return [
      "pn-provider=\(encodedProvider)",
      "pn-prid=\(encodedToken)",
      "pn-param=\(encodedParam)",
      "pn-silent=1",
      "pn-timeout=0"
    ].joined(separator: ";")
  }

  private func configureNatPolicy(
    core currentCore: Core,
    stunServer: String,
    turnServer: String
  ) throws {
    let normalizedStun = normalizeRelayServer(stunServer)
    let normalizedTurn = normalizeRelayServer(turnServer)
    if normalizedStun.isEmpty && normalizedTurn.isEmpty {
      return
    }

    let policy = try currentCore.createNatPolicy()
    if !normalizedStun.isEmpty {
      policy.stunServer = normalizedStun
      policy.stunEnabled = true
      policy.iceEnabled = true
    }
    if !normalizedTurn.isEmpty {
      policy.stunServer = normalizedTurn
      policy.turnEnabled = true
      policy.udpTurnTransportEnabled = true
      policy.iceEnabled = true
    }
    currentCore.natPolicy = policy
  }

  private func updateRegistration(enabled: Bool) throws {
    guard let currentCore = core else {
      return
    }
    let accounts = currentCore.accountList
    for currentAccount in accounts {
      guard let params = currentAccount.params?.clone() else { continue }
      params.registerEnabled = enabled
      currentAccount.params = params
    }
    account = currentCore.defaultAccount ?? accounts.first
  }

  private func purgeAccount() {
    stopPresenceSubscriptions()
    explicitUnregisterRequested = false
    core?.clearAccounts()
    core?.clearAllAuthInfo()
    account = nil
    SipCredentialStore.clear()
    IOSCallerIdentityStore.shared.clear()
    NSLog("Softphone/Linphone purged logged-out SIP account")
  }

  private func makeCall(
    destination: String,
    completion: @escaping (Error?) -> Void
  ) throws {
    guard core != nil else {
      throw NSError(
        domain: "SoftphoneLinphone",
        code: 1002,
        userInfo: [NSLocalizedDescriptionKey: "The SIP engine is unavailable."]
      )
    }
    let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw NSError(
        domain: "SoftphoneLinphone",
        code: 1004,
        userInfo: [NSLocalizedDescriptionKey: "A call destination is required."]
      )
    }
    SoftphoneCallKitController.shared.requestStartOutgoingCall(
      remoteHandle: trimmed,
      startSipCall: { [weak self] in
        guard let self, let currentCore = self.core else {
          throw NSError(
            domain: "SoftphoneLinphone",
            code: 1002,
            userInfo: [NSLocalizedDescriptionKey: "The SIP engine is unavailable."]
          )
        }
        let address = try self.normalizeDestination(trimmed)
        let params = try currentCore.createCallParams(call: nil)
        params.videoEnabled = false
        guard let outgoingCall = currentCore.inviteAddressWithParams(
          addr: address,
          params: params
        ) ?? currentCore.inviteAddress(addr: address) else {
          throw NSError(
            domain: "SoftphoneLinphone",
            code: 1005,
            userInfo: [NSLocalizedDescriptionKey: "Unable to create the outgoing call."]
          )
        }
        self.calls[self.callId(outgoingCall)] = outgoingCall
        self.emitCall(call: outgoingCall, state: outgoingCall.state)
        return outgoingCall
      },
      completion: { outcome in
        switch outcome {
        case .success:
          completion(nil)
        case .failure(let error):
          completion(error)
        }
      }
    )
  }

  private func dialFeatureCode(code: String) throws -> String {
    let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw NSError(
        domain: "SoftphoneLinphone",
        code: 1010,
        userInfo: [NSLocalizedDescriptionKey: "Feature code is required."]
      )
    }
    guard let currentCore = core else {
      throw NSError(
        domain: "SoftphoneLinphone",
        code: 1002,
        userInfo: [NSLocalizedDescriptionKey: "The SIP engine is unavailable."]
      )
    }
    SoftphoneCallKitController.shared.ensureAudioSessionActiveForOutgoingCall()
    let address = try normalizeDestination(trimmed)
    let params = try currentCore.createCallParams(call: nil)
    params.videoEnabled = false
    if featureCodePreviousMicEnabled == nil {
      featureCodePreviousMicEnabled = currentCore.micEnabled
      currentCore.micEnabled = false
    }
    pendingFeatureCodeDial = true
    defer { pendingFeatureCodeDial = false }
    guard let call = currentCore.inviteAddressWithParams(addr: address, params: params)
      ?? currentCore.inviteAddress(addr: address)
    else {
      throw NSError(
        domain: "SoftphoneLinphone",
        code: 1011,
        userInfo: [NSLocalizedDescriptionKey: "Unable to dial feature code."]
      )
    }
    let id = callId(call)
    featureCodeCalls.insert(ObjectIdentifier(call))
    calls[id] = call
    NSLog("VoIPCloud/Linphone feature-code dial code=%@ id=%@", trimmed, id)
    emitCall(call: call, state: call.state, featureCode: true)
    return id
  }

  private func maybeTerminateFeatureCodeCall(call: Call, state: Call.State) {
    guard state == .Connected || state == .StreamsRunning else { return }
    let key = ObjectIdentifier(call)
    guard featureCodeTerminateScheduled.insert(key).inserted else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
      guard let self, self.featureCodeCalls.contains(key) else { return }
      guard !self.isTerminalCallState(call.state) else { return }
      NSLog("VoIPCloud/Linphone auto-terminating feature-code call id=%@", self.callId(call))
      try? call.terminate()
    }
  }

  private func clearFeatureCodeCall(call: Call) {
    let key = ObjectIdentifier(call)
    featureCodeCalls.remove(key)
    featureCodeTerminateScheduled.remove(key)
    if featureCodeCalls.isEmpty {
      if let previous = featureCodePreviousMicEnabled {
        core?.micEnabled = previous
      }
      featureCodePreviousMicEnabled = nil
    }
  }

  private func transferCall(callId: String, destination: String) throws {
    guard let activeCall = findCall(id: callId) else {
      throw NSError(
        domain: "SoftphoneLinphone",
        code: 1004,
        userInfo: [NSLocalizedDescriptionKey: "There is no active call to transfer."]
      )
    }
    let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw NSError(
        domain: "SoftphoneLinphone",
        code: 1005,
        userInfo: [NSLocalizedDescriptionKey: "Transfer destination is required."]
      )
    }
    let address = try normalizeDestination(trimmed)
    do {
      try activeCall.transferTo(referTo: address)
    } catch {
      throw NSError(
        domain: "SoftphoneLinphone",
        code: 1006,
        userInfo: [
          NSLocalizedDescriptionKey: "Call transfer failed.",
          NSUnderlyingErrorKey: error,
        ]
      )
    }
    NSLog(
      "Softphone/Linphone blind transfer id=%@ destination=%@",
      callId,
      address.asStringUriOnly()
    )
  }

  private func sendMessage(destination: String, text: String) throws {
    guard let currentCore = core else {
      throw NSError(
        domain: "SoftphoneLinphone",
        code: 1002,
        userInfo: [NSLocalizedDescriptionKey: "The SIP engine is unavailable."]
      )
    }
    let trimmedDestination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedDestination.isEmpty else {
      throw NSError(
        domain: "SoftphoneLinphone",
        code: 1003,
        userInfo: [NSLocalizedDescriptionKey: "Message destination is required."]
      )
    }
    guard !trimmedText.isEmpty else {
      throw NSError(
        domain: "SoftphoneLinphone",
        code: 1004,
        userInfo: [NSLocalizedDescriptionKey: "Message text is required."]
      )
    }

    let peer = try normalizeDestination(trimmedDestination)
    let params = try currentCore.createDefaultChatRoomParams()
    let chatRoom = try currentCore.createChatRoom(
      params: params,
      localAddr: account?.params?.identityAddress,
      participants: [peer]
    )
    let message = try chatRoom.createMessageFromUtf8(message: trimmedText)
    message.send()
    emitMessage(message: message, direction: "outgoing", fallbackStatus: "sent")
    NSLog(
      "Softphone/Linphone sent SIP message to=%@",
      peer.asStringUriOnly()
    )
  }

  private func getCallQuality(callId: String) throws -> [String: Any?] {
    guard let active = findCall(id: callId) ?? findCurrentCall() else {
      throw NSError(
        domain: "SoftphoneLinphone",
        code: 1007,
        userInfo: [NSLocalizedDescriptionKey: "There is no active call."]
      )
    }
    // RTP/RTCP structures do not exist until the media stream has started.
    // Guard in native code as well as Flutter because any future caller of the
    // platform method must not be able to dereference premature SDK stats.
    switch active.state {
    case .StreamsRunning, .Paused, .PausedByRemote:
      break
    default:
      nativeCallTrace(
        "quality_unavailable",
        callId: self.callId(active),
        details: "state=\(active.state)"
      )
      throw NSError(
        domain: "SoftphoneLinphone",
        code: 1008,
        userInfo: [
          NSLocalizedDescriptionKey: "Call quality is available after media starts."
        ]
      )
    }
    let stats = active.audioStats
    let current = Double(active.currentQuality)
    let average = Double(active.averageQuality)
    let roundTripMs = stats.map { Double($0.roundTripDelay) * 1000.0 }
    let codec = active.currentParams?.usedAudioPayloadType?.mimeType
    return [
      "callId": self.callId(active),
      "capturedAt": ISO8601DateFormatter().string(from: Date()),
      "currentQuality": current >= 0 ? current : nil,
      "averageQuality": average >= 0 ? average : nil,
      "roundTripMs": roundTripMs,
      "jitterBufferMs": stats.map { Double($0.jitterBufferSizeMs) },
      "receiverLossPercent": stats.map { Double($0.receiverLossRate) },
      "senderLossPercent": stats.map { Double($0.senderLossRate) },
      "localLossPercent": stats.map { Double($0.localLossRate) },
      "downloadKbps": stats.map { Double($0.downloadBandwidth) },
      "uploadKbps": stats.map { Double($0.uploadBandwidth) },
      "codec": codec,
      "durationSeconds": Int(active.duration),
      "audioRoute": audioRoute(for: active),
      "remoteUri": active.remoteAddress?.asStringUriOnly() ?? "",
    ]
  }

  private func reconcileAudioDevices(reason: String) {
    let session = AVAudioSession.sharedInstance()
    let endpoints = audioRouteEndpoints(session: session)
    let fingerprint = endpoints.map { endpoint in
      let id = endpoint["id"] as? String ?? ""
      let selected = endpoint["selected"] as? Bool == true ? "1" : "0"
      return "\(id):\(selected)"
    }.sorted().joined(separator: "|")
    guard fingerprint != lastReconciledAudioEndpointsFingerprint else { return }
    lastReconciledAudioEndpointsFingerprint = fingerprint
    if let requestedAudioEndpointId,
       !endpoints.contains(where: { $0["id"] as? String == requestedAudioEndpointId }) {
      self.requestedAudioEndpointId = nil
      requestedAudioRoute = systemAudioRoute() ?? "earpiece"
    }
    if let currentCall = findCurrentCall() {
      emitCall(call: currentCall, state: currentCall.state)
    }

    NSLog(
      "Softphone/Linphone audio devices reconciled reason=%@ route=%@ endpoints=%d",
      reason,
      requestedAudioRoute,
      endpoints.count
    )
  }

  private func setAudioRoute(route: String, endpointId: String? = nil) throws -> String {
    guard core != nil else {
      throw audioRouteError("The audio engine is unavailable.")
    }
    let normalizedRoute = normalizedAudioRoute(route)
    let session = AVAudioSession.sharedInstance()
    let selectedEndpointId = try applySystemAudioRoute(
      normalizedRoute,
      endpointId: endpointId,
      session: session
    )
    requestedAudioRoute = normalizedRoute
    requestedAudioEndpointId = selectedEndpointId
    let currentCall = findCurrentCall()

    if let currentCall {
      audioRouteCallId = callId(currentCall)
      scheduleAudioRouteConfirmation(callId: callId(currentCall))
      emitCall(call: currentCall, state: currentCall.state)
    }
    NSLog(
      "Softphone/Linphone audio route requested=%@ endpoint=%@",
      normalizedRoute,
      selectedEndpointId
    )
    nativeCallTrace(
      "audio_route_requested",
      callId: currentCall.map { callId($0) },
      details: "route=\(normalizedRoute) endpointCorr=\(nativeCallCorrelation(selectedEndpointId))"
    )
    return normalizedRoute
  }

  private func getAudioRoutes() -> [[String: Any]] {
    audioRouteEndpoints(session: AVAudioSession.sharedInstance())
  }

  private func audioRoute(for call: Call) -> String {
    systemAudioRoute() ?? requestedAudioRoute
  }

  private func prepareAudioRoute(call: Call, state: Call.State) {
    let id = callId(call)
    switch state {
    case .End, .Released, .Error:
      if audioRouteCallId == id {
        audioRouteCallId = nil
        requestedAudioRoute = preferredDefaultAudioRoute()
      }
      return
    default:
      break
    }

    if audioRouteCallId != id {
      audioRouteCallId = id
      requestedAudioRoute = preferredDefaultAudioRoute()
      requestedAudioEndpointId = currentSystemEndpointId()
    }
  }

  private func preferredDefaultAudioRoute() -> String {
    systemAudioRoute() ?? "earpiece"
  }

  private func applySystemAudioRoute(
    _ route: String,
    endpointId: String?,
    session: AVAudioSession
  ) throws -> String {
    let inputs = session.availableInputs ?? []
    let requestedInput = endpointId.flatMap { id in
      inputs.first(where: { audioEndpointId(for: $0) == id })
    }
    try session.overrideOutputAudioPort(.none)
    switch route {
    case "speaker":
      if let builtInMic = inputs.first(where: { $0.portType == .builtInMic }) {
        try session.setPreferredInput(builtInMic)
      }
      try session.overrideOutputAudioPort(.speaker)
      return "ios:speaker"
    case "bluetooth", "wired", "streaming":
      let input = requestedInput ?? inputs.first(where: {
        audioRoute(for: $0.portType) == route
      })
      guard let input else {
        throw audioRouteError("The selected audio device is no longer available.")
      }
      try session.setPreferredInput(input)
      return audioEndpointId(for: input)
    default:
      if let builtInMic = inputs.first(where: { $0.portType == .builtInMic }) {
        try session.setPreferredInput(builtInMic)
      }
      return "ios:receiver"
    }
  }

  private func audioDeviceEventFingerprint() -> String {
    let session = AVAudioSession.sharedInstance()
    let outputs = session.currentRoute.outputs.map { "\($0.portType.rawValue):\($0.uid)" }
    let inputs = session.currentRoute.inputs.map { "\($0.portType.rawValue):\($0.uid)" }
    return (outputs + inputs).sorted().joined(separator: "|")
  }

  private func normalizedAudioRoute(_ route: String) -> String {
    switch route {
    case "speaker", "bluetooth", "wired", "streaming":
      return route
    default:
      return "earpiece"
    }
  }

  private func audioRouteEndpoints(session: AVAudioSession) -> [[String: Any]] {
    let currentId = currentSystemEndpointId()
    var endpoints: [[String: Any]] = [
      [
        "id": "ios:receiver",
        "route": "earpiece",
        "label": "iPhone",
        "available": true,
        "selected": currentId == "ios:receiver"
      ],
      [
        "id": "ios:speaker",
        "route": "speaker",
        "label": "Speaker",
        "available": true,
        "selected": currentId == "ios:speaker"
      ]
    ]
    let externalInputs = (session.availableInputs ?? []).filter {
      $0.portType != .builtInMic
    }
    for input in externalInputs {
      let route = audioRoute(for: input.portType)
      endpoints.append([
        "id": audioEndpointId(for: input),
        "route": route,
        "label": input.portName,
        "available": true,
        "selected": currentId == audioEndpointId(for: input)
      ])
    }
    return endpoints
  }

  private func audioEndpointId(for port: AVAudioSessionPortDescription) -> String {
    "ios:input:\(port.uid)"
  }

  private func currentSystemEndpointId() -> String {
    let session = AVAudioSession.sharedInstance()
    let outputs = session.currentRoute.outputs
    if outputs.contains(where: { $0.portType == .builtInSpeaker }) {
      return "ios:speaker"
    }
    if outputs.contains(where: { $0.portType == .builtInReceiver }) {
      return "ios:receiver"
    }
    if let preferred = session.preferredInput,
       preferred.portType != .builtInMic {
      return audioEndpointId(for: preferred)
    }
    if let output = outputs.first,
       let matchingInput = session.availableInputs?.first(where: {
         $0.portName == output.portName || $0.portType == output.portType
       }) {
      return audioEndpointId(for: matchingInput)
    }
    return requestedAudioEndpointId ?? "ios:receiver"
  }

  private func audioRoute(for portType: AVAudioSession.Port) -> String {
    switch portType {
    case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE:
      return "bluetooth"
    case .headsetMic, .headphones, .lineIn, .usbAudio:
      return "wired"
    case .carAudio, .airPlay:
      return "streaming"
    default:
      return "earpiece"
    }
  }

  private func systemAudioRoute() -> String? {
    let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
    if outputs.contains(where: { $0.portType == .builtInSpeaker }) {
      return "speaker"
    }
    if outputs.contains(where: {
      $0.portType == .bluetoothA2DP ||
      $0.portType == .bluetoothHFP ||
      $0.portType == .bluetoothLE
    }) {
      return "bluetooth"
    }
    if outputs.contains(where: { $0.portType == .builtInReceiver }) {
      return "earpiece"
    }
    if outputs.contains(where: {
      $0.portType == .headphones ||
      $0.portType == .headsetMic ||
      $0.portType == .lineOut ||
      $0.portType == .usbAudio
    }) {
      return "wired"
    }
    if outputs.contains(where: {
      $0.portType == .carAudio || $0.portType == .airPlay
    }) {
      return "streaming"
    }
    return nil
  }

  private func audioRouteError(_ message: String) -> NSError {
    return NSError(
      domain: "SoftphoneAudioRoute",
      code: 1,
      userInfo: [NSLocalizedDescriptionKey: message]
    )
  }

  private func scheduleAudioRouteConfirmation(callId: String) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
      guard let self,
            let call = self.findCall(id: callId),
            self.audioRouteCallId == callId
      else {
        return
      }
      self.emitCall(call: call, state: call.state)
    }
  }

  private func holdCall(id: String) throws {
    guard let activeCall = findCall(id: id) else {
      throw NSError(
        domain: "VoIPCloud",
        code: 404,
        userInfo: [NSLocalizedDescriptionKey: "There is no active call to hold."]
      )
    }
    let state = activeCall.state
    let nativeId = callId(activeCall)
    if state == .Paused || state == .Pausing {
      NSLog("VoIPCloud/Linphone Hold ignored; already held id=%@ state=%@", nativeId, String(describing: state))
      return
    }
    guard state == .StreamsRunning || state == .Connected else {
      throw NSError(
        domain: "VoIPCloud",
        code: 409,
        userInfo: [NSLocalizedDescriptionKey: "Cannot hold call while it is \(state)."]
      )
    }
    try SoftphoneCallKitController.shared.setLinphoneCallHeldDirectly(
      activeCall,
      held: true
    )
    NSLog("VoIPCloud/Linphone Hold direct fallback id=%@ requestedId=%@", nativeId, id)
  }

  private func resumeCall(id: String) throws {
    guard let activeCall = findCall(id: id) else {
      throw NSError(
        domain: "VoIPCloud",
        code: 404,
        userInfo: [NSLocalizedDescriptionKey: "There is no held call to resume."]
      )
    }
    let state = activeCall.state
    let nativeId = callId(activeCall)
    if state == .StreamsRunning || state == .Connected {
      NSLog("VoIPCloud/Linphone Resume ignored; already active id=%@ state=%@", nativeId, String(describing: state))
      return
    }
    guard state == .Paused || state == .PausedByRemote || state == .Pausing else {
      throw NSError(
        domain: "VoIPCloud",
        code: 409,
        userInfo: [NSLocalizedDescriptionKey: "Cannot resume call while it is \(state)."]
      )
    }
    try SoftphoneCallKitController.shared.setLinphoneCallHeldDirectly(
      activeCall,
      held: false
    )
    NSLog("VoIPCloud/Linphone Resume direct fallback id=%@ requestedId=%@", nativeId, id)
  }

  private func findCall(id: String) -> Call? {
    if !id.isEmpty, let call = calls[id] {
      return call
    }
    return findCurrentCall()
  }

  private func findCurrentCall() -> Call? {
    if let current = core?.currentCall, isLiveCall(current) {
      return current
    }
    return recoverLiveCall()
  }

  private func hasActiveCall() -> Bool {
    guard let call = findCurrentCall() else { return false }
    return isLiveCall(call)
  }

  private func syncCurrentCall(reason: String) {
    guard let call = findCurrentCall() else {
      NSLog("VoIPCloud/Linphone syncCurrentCall(%@) => none", reason)
      callEvents.send(["status": "none"])
      return
    }
    #if DEBUG
    NSLog(
      "VoIPCloud/Linphone Syncing current call to Flutter reason=%@ id=%@ state=%@",
      reason,
      callId(call),
      String(describing: call.state)
    )
    #endif
    emitCall(call: call, state: call.state)
  }

  private func recoverLiveCall() -> Call? {
    pruneTerminalCachedCalls()
    if let cached = calls.values.reversed().first(where: isLiveCall) {
      return cached
    }
    guard let fromSdk = core?.calls.reversed().first(where: isLiveCall) else {
      return nil
    }
    calls[callId(fromSdk)] = fromSdk
    return fromSdk
  }

  private func pruneTerminalCachedCalls() {
    let terminalIds = calls.compactMap { id, call -> String? in
      isLiveCall(call) ? nil : id
    }
    terminalIds.forEach { calls.removeValue(forKey: $0) }
  }

  private func isLiveCall(_ call: Call) -> Bool {
    !isTerminalCallState(call.state)
  }

  private func normalizeDestination(_ destination: String) throws -> Address {
    let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
    let domain = account?.params?.identityAddress?.domain ?? ""
    let uri: String
    if trimmed.hasPrefix("sip:") {
      uri = trimmed
    } else if trimmed.contains("@") {
      uri = "sip:\(trimmed)"
    } else {
      uri = "sip:\(trimmed)@\(domain)"
    }
    return try Factory.Instance.createAddress(addr: uri)
  }

  private func startPresenceSubscriptions(extensions: [String]) throws {
    guard let currentCore = core else {
      throw NSError(
        domain: "SoftphoneLinphone",
        code: 1010,
        userInfo: [NSLocalizedDescriptionKey: "Linphone core is not initialized."]
      )
    }
    stopPresenceSubscriptions()
    let uniqueExtensions = Array(Set(extensions.map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }))
      .filter { $0.range(of: "^[0-9]{2,8}$", options: .regularExpression) != nil }
      .sorted()
      .prefix(250)

    for extensionNumber in uniqueExtensions {
      for (eventPackage, accept) in [
        ("dialog", "application/dialog-info+xml"),
        ("presence", "application/pidf+xml")
      ] {
      let event = try currentCore.createSubscribe(
        resource: normalizeDestination(extensionNumber),
        event: eventPackage,
        expires: 300
      )
      event.addCustomHeader(
        name: "Accept",
        value: accept
      )
      presenceSubscriptions[ObjectIdentifier(event)] = (
        event,
        extensionNumber,
        eventPackage
      )
      do {
        try event.sendSubscribe(body: nil)
      } catch {
        presenceSubscriptions.removeValue(forKey: ObjectIdentifier(event))
        try? event.terminate()
        presenceEvents.send([
          "kind": "subscription",
          "extension": extensionNumber,
          "event": eventPackage,
          "state": "error"
        ])
      }
      }
    }
    NSLog(
      "VoIPCloud/Linphone Started %d BLF subscriptions",
      presenceSubscriptions.count
    )
  }

  private func stopPresenceSubscriptions() {
    let subscriptions = presenceSubscriptions.values.map { $0.0 }
    presenceSubscriptions.removeAll()
    subscriptions.forEach { try? $0.terminate() }
  }

  private func emitPresenceNotify(
    event: Event,
    notifiedEvent: String,
    body: Content?
  ) {
    guard let (_, extensionNumber, eventPackage) =
            presenceSubscriptions[ObjectIdentifier(event)],
          notifiedEvent.caseInsensitiveCompare(eventPackage) == .orderedSame
    else { return }
    presenceEvents.send([
      "kind": "notify",
      "extension": extensionNumber,
      "event": notifiedEvent,
      "contentType": "\(body?.type ?? "")/\(body?.subtype ?? "")",
      "body": body?.utf8Text ?? ""
    ])
  }

  private func emitSubscriptionState(event: Event, state: SubscriptionState) {
    guard let (_, extensionNumber, eventPackage) =
      presenceSubscriptions[ObjectIdentifier(event)] else {
      return
    }
    let stateName: String
    switch state {
    case .Active: stateName = "active"
    case .Error: stateName = "error"
    case .Terminated: stateName = "terminated"
    case .OutgoingProgress: stateName = "progress"
    case .Pending: stateName = "pending"
    case .IncomingReceived: stateName = "incoming"
    case .None: stateName = "none"
    default: stateName = "unknown"
    }
    presenceEvents.send([
      "kind": "subscription",
      "extension": extensionNumber,
      "event": eventPackage,
      "state": stateName
    ])
  }

  private func emitRegistration(state: RegistrationState, message: String) {
    let status = registrationState(state, inBackground: isAppInBackground)
    NSLog(
      "VoIPCloud/Linphone Registration state=%@ message=%@",
      status,
      message.isEmpty ? "none" : message
    )
    nativeCallTrace(
      "registration_state",
      details: "state=\(status) background=\(isAppInBackground)"
    )
    if sipLoggingEnabled {
      emitSipLog(
        level: "info",
        source: "linphone",
        message: "Registration => \(status)\(message.isEmpty ? "" : " · \(message)")"
      )
    }
    registrationEvents.send([
      "status": status,
      "message": registrationMessage(
        status: status,
        originalMessage: message,
        inBackground: isAppInBackground
      )
    ])
  }

  private func emitCall(
    call: Call,
    state: Call.State,
    featureCode: Bool? = nil,
    stateMessage: String? = nil
  ) {
    let id = callId(call)
    let objectId = ObjectIdentifier(call)
    let terminal = isTerminalCallState(state)
    if terminal, terminalCallIds.contains(id) {
      return
    }
    let startedAt = callStartedAtByObject[objectId] ?? callStartedAtById[id] ?? Date()
    callStartedAtByObject[objectId] = startedAt
    callStartedAtById[id] = startedAt
    if terminal {
      calls.removeValue(forKey: id)
      if audioRouteCallId == id {
        audioRouteCallId = nil
        requestedAudioEndpointId = nil
      }
    } else {
      calls[id] = call
    }
    let status = callStatus(state)
    let diagnosticMessage = (stateMessage ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    nativeCallTrace(
      "flutter_call_event_emitted",
      callId: id,
      details: "direction=\(call.dir == .Incoming ? "incoming" : "outgoing") status=\(status) message=\(diagnosticMessage.isEmpty ? "none" : diagnosticMessage)"
    )
    let remote = call.remoteAddress?.asStringUriOnly() ?? "none"
    let remoteHandle = call.remoteAddress?.username ?? remote
    let remoteDisplayName = callerNamePreservingDialPrefix(
      IOSCallerIdentityStore.shared.cachedName(for: remoteHandle)
        ?? callerDisplayLabel(call.remoteAddress, fallback: remoteHandle),
      remoteHandle: remoteHandle,
      sourceDisplayName: call.remoteAddress?.displayName
    )
    let isFeatureCode = featureCode ?? featureCodeCalls.contains(ObjectIdentifier(call))
    let endpoints = getAudioRoutes()
    let currentEndpointId = endpoints.first(where: {
      $0["selected"] as? Bool == true
    })?["id"] as? String
    let endpointFingerprint = endpoints.map { endpoint in
      let endpointId = endpoint["id"] as? String ?? ""
      let selected = endpoint["selected"] as? Bool == true ? "1" : "0"
      return "\(endpointId):\(selected)"
    }.sorted().joined(separator: "|")
    let eventFingerprint = [
      id,
      status,
      remote,
      core?.micEnabled == false ? "muted" : "unmuted",
      audioRoute(for: call),
      currentEndpointId ?? "",
      endpointFingerprint,
      isFeatureCode ? "feature" : "call",
      diagnosticMessage,
    ].joined(separator: "#")
    guard lastCallEventFingerprintById[id] != eventFingerprint else {
      return
    }
    lastCallEventFingerprintById[id] = eventFingerprint
    if terminal {
      terminalCallIds.insert(id)
    }
    NSLog(
      "Softphone/Linphone emitting call id=%@ direction=%@ state=%@ status=%@ remote=%@ featureCode=%@ message=%@",
      id,
      call.dir == .Incoming ? "incoming" : "outgoing",
      String(describing: state),
      status,
      remote,
      isFeatureCode ? "true" : "false",
      diagnosticMessage.isEmpty ? "none" : diagnosticMessage
    )
    if sipLoggingEnabled {
      emitSipLog(
        level: "info",
        source: "linphone",
        message: "Call => id=\(id) \(call.dir == .Incoming ? "incoming" : "outgoing") \(status) remote=\(remote) reason=\(diagnosticMessage.isEmpty ? "none" : diagnosticMessage)"
      )
    }
    callEvents.send([
      "id": id,
      "remoteUri": call.remoteAddress?.asStringUriOnly() ?? "",
      "remoteDisplayName": remoteDisplayName,
      "direction": call.dir == .Incoming ? "incoming" : "outgoing",
      "status": status,
      "startedAt": startedAt.iso8601String,
      "isMuted": core?.micEnabled == false,
      "isSpeakerEnabled": audioRoute(for: call) == "speaker",
      "audioRoute": audioRoute(for: call),
      "currentEndpointId": currentEndpointId,
      "availableEndpoints": endpoints,
      "featureCode": isFeatureCode,
      "stateMessage": diagnosticMessage
    ])
    if terminal {
      DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
        self?.callStartedAtByObject.removeValue(forKey: objectId)
        self?.callStartedAtById.removeValue(forKey: id)
        self?.lastCallEventFingerprintById.removeValue(forKey: id)
        self?.terminalCallIds.remove(id)
      }
    }
  }

  private func emitMessage(
    message: ChatMessage,
    direction: String,
    fallbackStatus: String
  ) {
    let remote = direction == "incoming"
      ? message.fromAddress?.asStringUriOnly()
      : message.toAddress?.asStringUriOnly()
    messageEvents.send([
      "id": message.messageId.isEmpty ? UUID().uuidString : message.messageId,
      "remoteUri": remote ?? "",
      "direction": direction,
      "text": message.utf8Text,
      "status": messageStatus(message.state, fallback: fallbackStatus),
      "createdAt": Date().iso8601String
    ])
  }

  private func setSipLoggingEnabled(_ enabled: Bool) {
    sipLoggingEnabled = enabled
    if enabled {
      emitSipLog(
        level: "info",
        source: "linphone",
        message: "Native SIP logging enabled"
      )
    }
  }

  private func appendSipLogLine(_ line: String) {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    writeSipLogLine(trimmed)
  }

  private func readSipLogFile() -> String {
    let url = sipLogFileURL()
    guard FileManager.default.fileExists(atPath: url.path) else { return "" }
    return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
  }

  private func clearSipLogFile() {
    sipLogFileLock.lock()
    defer { sipLogFileLock.unlock() }
    let url = sipLogFileURL()
    try? "".write(to: url, atomically: true, encoding: .utf8)
  }

  private func emitSipLog(level: String, source: String, message: String) {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let at = formatter.string(from: Date())
    let persisted = "\(at) [\(level.uppercased())] [\(source)] \(message)"
    writeSipLogLine(persisted)
    sipLogEvents.send([
      "at": at,
      "level": level,
      "source": source,
      "message": message,
    ])
  }

  private func writeSipLogLine(_ line: String) {
    sipLogFileLock.lock()
    defer { sipLogFileLock.unlock() }
    let url = sipLogFileURL()
    let directory = url.deletingLastPathComponent()
    try? FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
       let size = attributes[.size] as? NSNumber,
       size.intValue > maxSipLogBytes,
       let existing = try? String(contentsOf: url, encoding: .utf8) {
      let keep = String(existing.suffix(maxSipLogBytes / 2))
      try? keep.write(to: url, atomically: true, encoding: .utf8)
    }
    if let handle = try? FileHandle(forWritingTo: url) {
      defer { try? handle.close() }
      handle.seekToEndOfFile()
      if let data = (line.trimmingCharacters(in: CharacterSet.newlines) + "\n")
        .data(using: .utf8) {
        handle.write(data)
      }
    } else {
      try? (line.trimmingCharacters(in: CharacterSet.newlines) + "\n")
        .write(to: url, atomically: true, encoding: .utf8)
    }
  }

  private func sipLogFileURL() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    return base
      .appendingPathComponent("sip_logs", isDirectory: true)
      .appendingPathComponent("voipcloud_sip.log", isDirectory: false)
  }

  private func dispose() {
    stopPresenceSubscriptions()
    if let delegate {
      core?.removeDelegate(delegate: delegate)
    }
    core?.stop()
    core = nil
    account = nil
    delegate = nil
    calls.removeAll()
  }

  private func callId(_ call: Call) -> String {
    return call.callLog?.callId ?? String(ObjectIdentifier(call).hashValue)
  }

  private func isTerminalCallState(_ state: Call.State) -> Bool {
    switch state {
    case .End, .Released, .Error:
      return true
    default:
      return false
    }
  }

  private func releaseTerminalCallIfNeeded(call: Call, state: Call.State) {
    guard state == .Error || state == .End else { return }
    let id = callId(call)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self, weak call] in
      guard let self, let call,
            call.state == .Error || call.state == .End else { return }
      do {
        try call.terminate()
        NSLog(
          "Softphone/Linphone forced terminal call release id=%@ state=%@",
          id,
          String(describing: call.state)
        )
      } catch {
        NSLog(
          "Softphone/Linphone terminal-call release id=%@ result=%@",
          id,
          error.localizedDescription
        )
      }
      self.calls.removeValue(forKey: id)
    }
  }

  private func isIncomingRinging(_ call: Call) -> Bool {
    guard call.dir == .Incoming else { return false }
    switch call.state {
    case .PushIncomingReceived, .IncomingReceived, .IncomingEarlyMedia:
      return true
    default:
      return false
    }
  }
}

private func stringArg(_ args: [String: Any], _ key: String) -> String {
  return (args[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

private func normalizeRelayServer(_ value: String) -> String {
  return value
    .replacingOccurrences(of: "stun:", with: "")
    .replacingOccurrences(of: "turn:", with: "")
    .replacingOccurrences(of: "turns:", with: "")
    .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func normalizeSipAddress(_ value: String) -> String {
  let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
  if trimmed.hasPrefix("sip:") || trimmed.hasPrefix("sips:") {
    return trimmed
  }
  return "sip:\(trimmed)"
}

private func argument(_ call: FlutterMethodCall, _ key: String) -> String {
  let args = call.arguments as? [String: Any] ?? [:]
  return stringArg(args, key)
}

private func boolArgument(_ call: FlutterMethodCall, _ key: String) -> Bool {
  let args = call.arguments as? [String: Any] ?? [:]
  return args[key] as? Bool ?? false
}

private func firstDtmf(_ value: String) -> CChar {
  return value.utf8CString.first ?? 0
}

private func audioDevice(_ device: AudioDevice?, isNamed typeName: String) -> Bool {
  guard let device else { return false }
  return String(describing: device.type).localizedCaseInsensitiveContains(typeName)
}

private func transportType(_ value: String) -> TransportType {
  switch value.lowercased() {
  case "tls":
    return .Tls
  case "tcp":
    return .Tcp
  default:
    return .Udp
  }
}

private func registrationState(_ state: RegistrationState, inBackground: Bool) -> String {
  switch state {
  case .Ok:
    return "registered"
  case .Progress:
    return "registering"
  case .Failed:
    return inBackground ? "registered" : "failed"
  case .Cleared:
    return inBackground ? "registered" : "unregistered"
  default:
    return inBackground ? "registered" : "unregistered"
  }
}

private func registrationMessage(
  status: String,
  originalMessage: String,
  inBackground: Bool
) -> String? {
  if inBackground && status == "registered" {
    return "Reachable via push while app is in background"
  }
  return originalMessage.isEmpty ? nil : originalMessage
}

private func registrationState(_ state: RegistrationState) -> String {
  registrationState(state, inBackground: false)
}

private func callerDisplayLabel(
  _ address: Address?,
  fallback: String
) -> String {
  let rawUsername = (address?.username ?? "")
    .trimmingCharacters(in: .whitespacesAndNewlines)
  let username = rawUsername.removingPercentEncoding ?? rawUsername
  let displayName = (address?.displayName ?? "")
    .trimmingCharacters(in: .whitespacesAndNewlines)
  let base = !displayName.isEmpty
    ? displayName
    : (!username.isEmpty ? username : fallback)
  return callerNamePreservingDialPrefix(
    base,
    remoteHandle: username,
    sourceDisplayName: displayName
  ) ?? base
}

private func callerNamePreservingDialPrefix(
  _ resolvedName: String?,
  remoteHandle: String,
  sourceDisplayName: String? = nil
) -> String? {
  guard let rawPrefix = dialPrefix(from: remoteHandle)
    ?? displayNamePrefix(from: sourceDisplayName) else {
    return resolvedName
  }
  let name = (resolvedName ?? "")
    .trimmingCharacters(in: .whitespacesAndNewlines)
  let marker = rawPrefix + ":"
  if name.lowercased().hasPrefix(marker.lowercased()) {
    return name
  }
  let user = sipUser(from: remoteHandle)
  let suffix = dialPrefix(from: remoteHandle) == nil
    ? ""
    : String(user.dropFirst(marker.count))
  if name.isEmpty {
    return dialPrefix(from: remoteHandle) == nil ? "\(rawPrefix): \(user)" : user
  }
  if !suffix.isEmpty && name == suffix {
    return user
  }
  return "\(rawPrefix): \(name)"
}

private func displayNamePrefix(from value: String?) -> String? {
  let displayName = (value ?? "")
    .trimmingCharacters(in: .whitespacesAndNewlines)
  guard let separator = displayName.firstIndex(of: ":") else { return nil }
  let prefix = String(displayName[..<separator])
    .trimmingCharacters(in: .whitespacesAndNewlines)
  guard prefix.range(
    of: "^[A-Za-z][A-Za-z0-9._ -]{0,31}$",
    options: .regularExpression
  ) != nil else { return nil }
  let suffix = String(displayName[displayName.index(after: separator)...])
    .trimmingCharacters(in: .whitespacesAndNewlines)
  return suffix.isEmpty ? nil : prefix
}

private func dialPrefix(from remoteHandle: String) -> String? {
  let user = sipUser(from: remoteHandle)
  guard let separator = user.firstIndex(of: ":") else { return nil }
  let prefix = String(user[..<separator])
  guard prefix.range(
    of: "^[A-Za-z][A-Za-z0-9._-]*$",
    options: .regularExpression
  ) != nil else { return nil }
  let suffix = String(user[user.index(after: separator)...])
  guard !suffix.isEmpty else { return nil }
  return prefix
}

private func sipUser(from value: String) -> String {
  var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
  if normalized.hasPrefix("<") && normalized.hasSuffix(">") {
    normalized = String(normalized.dropFirst().dropLast())
  }
  let lower = normalized.lowercased()
  if lower.hasPrefix("sips:") {
    normalized = String(normalized.dropFirst(5))
  } else if lower.hasPrefix("sip:") {
    normalized = String(normalized.dropFirst(4))
  }
  normalized = String(normalized.split(separator: "@", maxSplits: 1).first ?? "")
  normalized = String(normalized.split(separator: ";", maxSplits: 1).first ?? "")
  return normalized.removingPercentEncoding ?? normalized
}

private func callStatus(_ state: Call.State) -> String {
  switch state {
  case .PushIncomingReceived, .IncomingReceived, .IncomingEarlyMedia:
    return "ringing"
  case .OutgoingInit, .OutgoingProgress, .OutgoingRinging, .OutgoingEarlyMedia:
    return "dialing"
  case .Connected, .StreamsRunning:
    return "active"
  case .Pausing, .Paused, .PausedByRemote:
    return "held"
  case .End, .Released:
    return "ended"
  case .Error:
    return "failed"
  default:
    return "connecting"
  }
}

private func messageStatus(_ state: ChatMessage.State, fallback: String) -> String {
  switch state {
  case .Delivered, .DeliveredToUser, .Displayed:
    return "delivered"
  case .NotDelivered:
    return "failed"
  case .InProgress:
    return "pending"
  default:
    return fallback
  }
}

private extension Date {
  var iso8601String: String {
    ISO8601DateFormatter().string(from: self)
  }
}
#endif

private extension Notification.Name {
  static let softphoneVoipPushTokenUpdated = Notification.Name("SoftphoneVoipPushTokenUpdated")
}
