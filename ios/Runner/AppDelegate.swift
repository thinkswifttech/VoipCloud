import AVFoundation
import AVKit
import Flutter
import CallKit
import Contacts
import Foundation
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

final class…31990 tokens truncated…omain)"
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
