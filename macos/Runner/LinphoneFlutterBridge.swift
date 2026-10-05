import Cocoa
import AVFoundation
import AudioToolbox
import CoreAudio
import FlutterMacOS
import Foundation
import UserNotifications

#if canImport(linphonesw)
import linphonesw
#endif

#if canImport(linphonesw)
/// Matches mobile: original 440 Hz / 400 ms tone, 25 ms soft edges.
private enum DesktopWaitingTonePolicy {
  static func wave(level: Int) -> Data {
    let sampleRate = 8_000
    let count = sampleRate
    var wave = Data()
    wave.append(contentsOf: "RIFF".utf8)
    wave.appendLittleEndian(UInt32(36 + count * 2))
    wave.append(contentsOf: "WAVEfmt ".utf8)
    wave.appendLittleEndian(UInt32(16))
    wave.appendLittleEndian(UInt16(1))
    wave.appendLittleEndian(UInt16(1))
    wave.appendLittleEndian(UInt32(sampleRate))
    wave.appendLittleEndian(UInt32(sampleRate * 2))
    wave.appendLittleEndian(UInt16(2))
    wave.appendLittleEndian(UInt16(16))
    wave.append(contentsOf: "data".utf8)
    wave.appendLittleEndian(UInt32(count * 2))
    let amplitude = 0.08 * Double(min(100, max(0, level))) / 100
    for index in 0..<count {
      let time = Double(index) / Double(sampleRate)
      var sample: Int16 = 0
      if time < 0.4 {
        let ramp = max(0, min(1, min(time / 0.025, (0.4 - time) / 0.025)))
        let envelope = 0.5 - 0.5 * cos(.pi * ramp)
        sample = Int16(sin(2 * .pi * 440 * time) * amplitude * envelope * 32767)
      }
      wave.appendLittleEndian(sample)
    }
    return wave
  }
}

#endif

private enum DesktopDndStore {
  static let key = "device_dnd_enabled"

  static var isEnabled: Bool {
    get { UserDefaults.standard.bool(forKey: key) }
    set { UserDefaults.standard.set(newValue, forKey: key) }
  }
}

final class LinphoneFlutterBridge {
  private let methodChannelName = "voipcloud/linphone"
  private let registrationEventsName = "voipcloud/linphone/registration"
  private let callEventsName = "voipcloud/linphone/calls"
  private let messageEventsName = "voipcloud/linphone/messages"
  private let presenceEventsName = "voipcloud/linphone/presence"

  private let registrationEvents = LinphoneEventStreamHandler()
  private let callEvents = LinphoneEventStreamHandler(
    detachedBufferCapacity: 64,
    terminalOutbox: .shared
  )
  private let messageEvents = LinphoneEventStreamHandler()
  private let presenceEvents = LinphoneEventStreamHandler()
  private let controller: LinphoneController

  init(binaryMessenger: FlutterBinaryMessenger) {
    controller = LinphoneControllerFactory.make(
      registrationEvents: registrationEvents,
      callEvents: callEvents,
      messageEvents: messageEvents,
      presenceEvents: presenceEvents
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
      if call.method == "setAppBadgeCount" {
        let arguments = call.arguments as? [String: Any]
        let count = max(0, (arguments?["count"] as? NSNumber)?.intValue ?? 0)
        DispatchQueue.main.async {
          NSApp.dockTile.badgeLabel = count == 0 ? nil : String(count)
        }
        result(nil)
        return
      }
      if call.method == "ackCallHistoryEvent" {
        let arguments = call.arguments as? [String: Any]
        DesktopCallHistoryOutbox.shared.acknowledge(
          arguments?["historyEventId"] as? String ?? ""
        )
        result(nil)
        return
      }
      if call.method == "purgeAccount" {
        DesktopCallHistoryOutbox.shared.clear()
        self.callEvents.clearPending()
      }
      self.controller.handle(call: call, result: result)
    }

    FlutterEventChannel(
      name: registrationEventsName,
      binaryMessenger: binaryMessenger
    ).setStreamHandler(registrationEvents)
    FlutterEventChannel(
      name: callEventsName,
      binaryMessenger: binaryMessenger
    ).setStreamHandler(callEvents)
    FlutterEventChannel(
      name: messageEventsName,
      binaryMessenger: binaryMessenger
    ).setStreamHandler(messageEvents)
    FlutterEventChannel(
      name: presenceEventsName,
      binaryMessenger: binaryMessenger
    ).setStreamHandler(presenceEvents)
  }
}

private final class LinphoneEventStreamHandler: NSObject, FlutterStreamHandler {
  private let detachedBufferCapacity: Int
  private let terminalOutbox: DesktopCallHistoryOutbox?
  private var eventSink: FlutterEventSink?
  private var detachedEvents: [[String: Any?]] = []

  init(
    detachedBufferCapacity: Int = 0,
    terminalOutbox: DesktopCallHistoryOutbox? = nil
  ) {
    self.detachedBufferCapacity = max(0, detachedBufferCapacity)
    self.terminalOutbox = terminalOutbox
    super.init()
  }

  func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    eventSink = events
    if let terminalOutbox {
      for event in terminalOutbox.pendingEvents() {
        events(event)
      }
    }
    if !detachedEvents.isEmpty {
      let pending = detachedEvents
      detachedEvents.removeAll(keepingCapacity: true)
      for event in pending {
        events(event)
      }
    }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  func send(_ event: [String: Any?]) {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      let status = event["status"] as? String
      let isTerminal = status == "ended" || status == "failed" || status == "missed"
      if isTerminal, let terminalOutbox {
        if let persisted = terminalOutbox.persist(event) {
          self.eventSink?(persisted)
          return
        }
      }
      if let eventSink = self.eventSink {
        eventSink(event)
        return
      }
      guard self.detachedBufferCapacity > 0 else { return }
      self.detachedEvents.append(event)
      let overflow = self.detachedEvents.count - self.detachedBufferCapacity
      if overflow > 0 {
        self.detachedEvents.removeFirst(overflow)
      }
    }
  }

  func clearPending() {
    detachedEvents.removeAll(keepingCapacity: false)
  }
}

private enum DesktopSipInstanceStore {
  private static let key = "sip_instance_uuid"

  static func value() -> String {
    if let existing = UserDefaults.standard.string(forKey: key),
       UUID(uuidString: existing) != nil {
      return existing.lowercased()
    }
    let generated = UUID().uuidString.lowercased()
    UserDefaults.standard.set(generated, forKey: key)
    return generated
  }
}

private final class DesktopCallHistoryOutbox {
  static let shared = DesktopCallHistoryOutbox()

  private let fileManager = FileManager.default
  private let maximumEventCount = 200
  private let maximumAge: TimeInterval = 30 * 24 * 60 * 60

  private var directoryURL: URL? {
    guard let applicationSupport = fileManager.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first else { return nil }
    return applicationSupport
      .appendingPathComponent("VoIPCloud", isDirectory: true)
      .appendingPathComponent("CallHistory", isDirectory: true)
  }

  func persist(_ event: [String: Any?]) -> [String: Any?]? {
    guard let directoryURL else { return nil }
    do {
      try prepareDirectory(directoryURL)
      let callId = event["id"] as? String
      for record in try records(in: directoryURL)
      where callId != nil && record.event["id"] as? String == callId {
        try? fileManager.removeItem(at: record.url)
      }
      let eventId = UUID().uuidString.lowercased()
      var stored = event.compactMapValues { $0 }
      stored["historyEventId"] = eventId
      stored["historyReplay"] = false
      stored["historyPersistedAtEpochMs"] = Int64(Date().timeIntervalSince1970 * 1000)
      guard JSONSerialization.isValidJSONObject(stored) else { return nil }
      let data = try JSONSerialization.data(withJSONObject: stored)
      try data.write(
        to: directoryURL.appendingPathComponent("\(eventId).json"),
        options: .atomic
      )
      try prune(in: directoryURL)
      return optionalDictionary(stored)
    } catch {
      NSLog("VoIPCloud/macOS could not persist call-history event: %@", error.localizedDescription)
      return nil
    }
  }

  func pendingEvents() -> [[String: Any?]] {
    guard let directoryURL else { return [] }
    do {
      try prepareDirectory(directoryURL)
      try prune(in: directoryURL)
      return try records(in: directoryURL).map { record in
        var event = record.event
        event["historyReplay"] = true
        return optionalDictionary(event)
      }
    } catch {
      NSLog("VoIPCloud/macOS could not replay call-history events: %@", error.localizedDescription)
      return []
    }
  }

  func acknowledge(_ eventId: String) {
    let allowed = CharacterSet.alphanumerics.union(
      CharacterSet(charactersIn: "-")
    )
    guard !eventId.isEmpty,
          eventId.unicodeScalars.allSatisfy({ allowed.contains($0) }),
          let directoryURL else { return }
    try? fileManager.removeItem(
      at: directoryURL.appendingPathComponent("\(eventId).json")
    )
  }

  func clear() {
    guard let directoryURL else { return }
    try? fileManager.removeItem(at: directoryURL)
  }

  private func prepareDirectory(_ directoryURL: URL) throws {
    try fileManager.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true
    )
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var mutableURL = directoryURL
    try? mutableURL.setResourceValues(values)
  }

  private func records(in directoryURL: URL) throws -> [(url: URL, event: [String: Any])] {
    let urls = try fileManager.contentsOfDirectory(
      at: directoryURL,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    ).filter { $0.pathExtension == "json" }
    var result: [(url: URL, event: [String: Any])] = []
    for url in urls {
      do {
        let data = try Data(contentsOf: url)
        guard let event = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
          try? fileManager.removeItem(at: url)
          continue
        }
        result.append((url, event))
      } catch {
        try? fileManager.removeItem(at: url)
      }
    }
    return result.sorted { persistedAt($0.event) < persistedAt($1.event) }
  }

  private func prune(in directoryURL: URL) throws {
    let oldest = Int64((Date().timeIntervalSince1970 - maximumAge) * 1000)
    var current = try records(in: directoryURL)
    for record in current where persistedAt(record.event) < oldest {
      try? fileManager.removeItem(at: record.url)
    }
    current = try records(in: directoryURL)
    for record in current.prefix(max(0, current.count - maximumEventCount)) {
      try? fileManager.removeItem(at: record.url)
    }
  }

  private func persistedAt(_ event: [String: Any]) -> Int64 {
    (event["historyPersistedAtEpochMs"] as? NSNumber)?.int64Value ?? 0
  }

  private func optionalDictionary(_ event: [String: Any]) -> [String: Any?] {
    var result: [String: Any?] = [:]
    for (key, value) in event { result[key] = value }
    return result
  }
}

private enum DesktopAudioVolumeStore {
  static let microphoneKey = "voipcloud_microphone_volume"
  static let callAudioKey = "voipcloud_call_audio_volume"
  static let ringtoneKey = "voipcloud_ringtone_volume"
  static let ringbackKey = "voipcloud_ringback_volume"
  static let waitingKey = "voipcloud_call_waiting_volume"

  static func level(for key: String) -> Int {
    guard UserDefaults.standard.object(forKey: key) != nil else {
      switch key {
      case callAudioKey: return 70
      case ringtoneKey: return 55
      case ringbackKey: return 45
      case waitingKey: return 30
      default: return 100
      }
    }
    return min(100, max(0, UserDefaults.standard.integer(forKey: key)))
  }

  static func set(_ level: Int, for key: String) {
    UserDefaults.standard.set(min(100, max(0, level)), forKey: key)
  }
}

private protocol LinphoneController {
  func handle(call: FlutterMethodCall, result: @escaping FlutterResult)
}

private enum LinphoneControllerFactory {
  static func make(
    registrationEvents: LinphoneEventStreamHandler,
    callEvents: LinphoneEventStreamHandler,
    messageEvents: LinphoneEventStreamHandler,
    presenceEvents: LinphoneEventStreamHandler
  ) -> LinphoneController {
    #if canImport(linphonesw)
    return NativeLinphoneController(
      registrationEvents: registrationEvents,
      callEvents: callEvents,
      messageEvents: messageEvents,
      presenceEvents: presenceEvents
    )
    #else
    return UnavailableLinphoneController()
    #endif
  }
}

private final class UnavailableLinphoneController: LinphoneController {
  func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "setNativeDnd":
      DesktopDndStore.isEnabled = boolArgument(call, "enabled")
      result(nil)
    case "getSipInstanceId":
      result(DesktopSipInstanceStore.value())
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
         "setAudioInputDevice",
         "getAudioVolumeLevels",
         "setAudioVolume",
         "playAudioTestSound",
         "previewCallWaitingAlert",
         "startAudioInputTest",
         "getAudioInputLevel",
         "stopAudioInputTest",
         "sendDtmf",
         "completeAttendedTransfer",
         "mergeCalls",
         "sendMessage",
         "startPresenceSubscriptions",
         "stopPresenceSubscriptions",
         "dispose":
      result(FlutterError(
        code: "LINPHONE_NOT_LINKED",
        message: "macOS liblinphone bridge is not linked in this build.",
        details: nil
      ))
    case "hasActiveCall":
      result(false)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

#if canImport(linphonesw)
private final class NativeLinphoneController: LinphoneController {
  private let registrationEvents: LinphoneEventStreamHandler
  private let callEvents: LinphoneEventStreamHandler
  private let messageEvents: LinphoneEventStreamHandler
  private let presenceEvents: LinphoneEventStreamHandler

  private var core: Core?
  private var waitingAlertTimer: Timer?
  private var waitingPreviewPlayer: AVAudioPlayer?
  private var account: Account?
  private var delegate: CoreDelegateStub?
  private var calls: [String: Call] = [:]
  private var featureCodeCalls = Set<ObjectIdentifier>()
  private var featureCodeTerminateScheduled = Set<ObjectIdentifier>()
  private var featureCodePreviousMicEnabled: Bool?
  private var pendingFeatureCodeDial = false
  private var presenceSubscriptions: [ObjectIdentifier: (Event, String, String)] = [:]
  private var selectedAudioEndpointId: String?
  private var selectedAudioInputEndpointId: String?
  private var audioInputTestEngine: AVAudioEngine?
  private let audioInputLevelLock = NSLock()
  private var audioInputLevel: Double = 0
  private var audioTestToneURL: URL?
  private var ringtoneSourceURL: URL?
  private var ringbackSourceURL: URL?
  private var desktopNotificationCallIds = Set<String>()
  private var dndDeclinedCalls = Set<ObjectIdentifier>()
  private var locallyDeclinedCallIds = Set<String>()
  private var deviceDndEnabled = DesktopDndStore.isEnabled
  private var notificationObservers: [NSObjectProtocol] = []

  init(
    registrationEvents: LinphoneEventStreamHandler,
    callEvents: LinphoneEventStreamHandler,
    messageEvents: LinphoneEventStreamHandler,
    presenceEvents: LinphoneEventStreamHandler
  ) {
    self.registrationEvents = registrationEvents
    self.callEvents = callEvents
    self.messageEvents = messageEvents
    self.presenceEvents = presenceEvents
    let center = NotificationCenter.default
    notificationObservers.append(center.addObserver(
      forName: DesktopCallNotification.answerRequested,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      self?.answerIncomingCallFromNotification(notification)
    })
    notificationObservers.append(center.addObserver(
      forName: DesktopCallNotification.declineRequested,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      self?.declineIncomingCallFromNotification(notification)
    })
  }

  deinit {
    notificationObservers.forEach {
      NotificationCenter.default.removeObserver($0)
    }
  }

  func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    do {
      switch call.method {
      case "initialize":
        try initialize()
        result(nil)
      case "getSipInstanceId":
        result(DesktopSipInstanceStore.value())
      case "configureAccount":
        try configureAccount(args: call.arguments as? [String: Any] ?? [:])
        result(nil)
      case "register":
        try updateRegistration(enabled: true)
        account?.refreshRegister()
        result(nil)
      case "syncCurrentCall":
        syncCurrentCall(reason: "dart-sync")
        result(nil)
      case "hasActiveCall":
        result(findCurrentCall() != nil)
      case "setNativeDnd":
        setNativeDnd(enabled: boolArgument(call, "enabled"))
        result(nil)
      case "enterBackground":
        result(nil)
      case "enterForeground":
        result(nil)
      case "unregister":
        try updateRegistration(enabled: false)
        account?.refreshRegister()
        core?.refreshRegisters()
        result(nil)
      case "purgeAccount":
        purgeAccount()
        result(nil)
      case "makeCall":
        try makeCall(destination: argument(call, "destination"))
        result(nil)
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
        try incomingCall.accept()
        result(nil)
      case "rejectCall":
        try findCall(id: argument(call, "callId"))?.decline(reason: .Busy)
        result(nil)
      case "endCall":
        try findCall(id: argument(call, "callId"))?.terminate()
        result(nil)
      case "mute":
        core?.micEnabled = !boolArgument(call, "enabled")
        result(nil)
      case "hold":
        try holdCall(id: argument(call, "callId"))
        result(nil)
      case "resume":
        try resumeCall(id: argument(call, "callId"))
        result(nil)
      case "setSpeaker":
        result(try setAudioEndpoint(
          endpointId: nil,
          fallbackRoute: boolArgument(call, "enabled") ? "speaker" : "streaming"
        ))
      case "setBluetooth":
        result(try setAudioEndpoint(
          endpointId: nil,
          fallbackRoute: boolArgument(call, "enabled") ? "bluetooth" : "speaker"
        ))
      case "ensureBluetoothPermission":
        result(true)
      case "getAudioRoutes":
        result(audioEndpoints())
      case "setAudioRoute":
        let args = call.arguments as? [String: Any]
        result(try setAudioEndpoint(
          endpointId: args?["endpointId"] as? String,
          fallbackRoute: argument(call, "route")
        ))
      case "setAudioInputDevice":
        let args = call.arguments as? [String: Any]
        result(try setAudioInputEndpoint(
          endpointId: args?["endpointId"] as? String
        ))
      case "getAudioVolumeLevels":
        result(audioVolumeLevels())
      case "previewCallWaitingAlert":
        guard findCurrentCall() == nil else {
          result(FlutterError(code: "AUDIO_TEST_BUSY", message: "Finish all calls before previewing the alert.", details: nil))
          return
        }
        let args = call.arguments as? [String: Any] ?? [:]
        let level = min(100, max(0, (args["level"] as? NSNumber)?.intValue ?? 30))
        waitingPreviewPlayer?.stop()
        let player = try AVAudioPlayer(data: DesktopWaitingTonePolicy.wave(level: level))
        player.numberOfLoops = 0
        waitingPreviewPlayer = player
        guard player.play() else {
          throw NSError(domain: "VoIPCloud", code: 1404,
            userInfo: [NSLocalizedDescriptionKey: "Unable to play the alert preview."])
        }
        result(nil)
      case "setAudioVolume":
        try setAudioVolume(call: call)
        result(nil)
      case "playAudioTestSound":
        try playAudioTestSound()
        result(nil)
      case "startAudioInputTest":
        startAudioInputTest(result: result)
      case "getAudioInputLevel":
        audioInputLevelLock.lock()
        let level = audioInputLevel
        audioInputLevelLock.unlock()
        result(level)
      case "stopAudioInputTest":
        stopAudioInputTest()
        result(nil)
      case "sendDtmf":
        try findCurrentCall()?.sendDtmf(dtmf: firstDtmf(argument(call, "value")))
        result(nil)
      case "getCallQuality":
        result(try getCallQuality(callId: argument(call, "callId")))
      case "completeAttendedTransfer":
        try completeAttendedTransfer(
          originalCallId: argument(call, "originalCallId"),
          consultationCallId: argument(call, "consultationCallId")
        )
        result(nil)
      case "mergeCalls":
        try mergeCalls(
          activeCallId: argument(call, "activeCallId"),
          heldCallId: argument(call, "heldCallId")
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
        result(nil)
      case "appendSipLogLine":
        result(nil)
      case "readSipLogFile":
        result("")
      case "clearSipLogFile":
        result(nil)
      case "dispose":
        dispose()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    } catch {
      result(FlutterError(
        code: "LINPHONE_ERROR",
        message: error.localizedDescription,
        details: nil
      ))
    }
  }

  private func initialize() throws {
    guard core == nil else { return }
    let newCore = try Factory.Instance.createCore(
      configPath: nil,
      factoryConfigPath: nil,
      systemContext: nil
    )
    newCore.config?.setString(
      section: "misc",
      key: "uuid",
      value: DesktopSipInstanceStore.value()
    )
    let appVersion = Bundle.main.object(
      forInfoDictionaryKey: "CFBundleShortVersionString"
    ) as? String ?? "0.1.0"
    newCore.setUserAgent(name: "VoIPCloud-macOS", version: appVersion)
    newCore.ipv6Enabled = true
    newCore.micEnabled = true
    newCore.config?.setInt(section: "sip", key: "inactive_audio_on_pause", value: 0)
    newCore.avpfMode = .Disabled
    configureDesktopCallSounds(on: newCore)
    restoreAudioVolumes(on: newCore)
    // Never use the SDK's unattenuated synthesized waiting fallback.
    let waitingTone = try waitingAlertFile(level: DesktopAudioVolumeStore.level(for: DesktopAudioVolumeStore.waitingKey))
    newCore.setTone(toneId: .CallWaiting, audiofile: waitingTone.path)

    let newDelegate = CoreDelegateStub(
      onCallStateChanged: { [weak self] _, call, state, message in
        guard let self else { return }
        self.waitingPreviewPlayer?.stop()
        self.waitingPreviewPlayer = nil
        let id = self.callId(call)
        self.calls[id] = call
        self.reconcileWaitingAlert()
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
        self.emitCall(
          call: call,
          state: state,
          featureCode: false,
          stateMessage: message
        )
      },
      onMessageReceived: { [weak self] _, _, message in
        self?.emitMessage(message: message, direction: "incoming", fallbackStatus: "delivered")
      },
      onMessageSent: { [weak self] _, _, message in
        self?.emitMessage(message: message, direction: "outgoing", fallbackStatus: "sent")
      },
      onSubscriptionStateChanged: { [weak self] _, event, state in
        self?.emitSubscriptionState(event: event, state: state)
      },
      onNotifyReceived: { [weak self] _, event, notifiedEvent, body in
        self?.emitPresenceNotify(
          event: event,
          notifiedEvent: notifiedEvent,
          body: body
        )
      },
      onAudioDeviceChanged: { [weak self] _, device in
        guard let self else { return }
        if self.isInputAudioDevice(device) {
          self.selectedAudioInputEndpointId = self.audioEndpointId(device)
        } else {
          self.selectedAudioEndpointId = self.audioEndpointId(device)
        }
        if let call = self.findCurrentCall() {
          self.emitCall(call: call, state: call.state)
        }
      },
      onAudioDevicesListUpdated: { [weak self] _ in
        guard let self else { return }
        if let selected = self.selectedAudioEndpointId,
           !self.outputAudioDevices().contains(where: {
             self.audioEndpointId($0) == selected
           }) {
          self.selectedAudioEndpointId = nil
        }
        if let selected = self.selectedAudioInputEndpointId,
           !self.inputAudioDevices().contains(where: {
             self.audioEndpointId($0) == selected
           }) {
          self.selectedAudioInputEndpointId = nil
        }
        if let call = self.findCurrentCall() {
          self.emitCall(call: call, state: call.state)
        }
      },
      onAccountRegistrationStateChanged: { [weak self] _, _, state, message in
        self?.emitRegistration(state: state, message: message)
      }
    )

    newCore.addDelegate(delegate: newDelegate)
    try newCore.start()
    core = newCore
    delegate = newDelegate
    restorePreferredAudioDevices()
    registrationEvents.send(["status": "unregistered", "message": nil])
  }

  private func waitingAlertFile(level: Int) throws -> URL {
    let directory = try FileManager.default.url(for: .applicationSupportDirectory,
      in: .userDomainMask, appropriateFor: nil, create: true)
      .appendingPathComponent("VoipCloud/Audio", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("call-waiting-v1-\(level).wav")
    let expected = DesktopWaitingTonePolicy.wave(level: level)
    if (try? Data(contentsOf: file)) != expected { try expected.write(to: file, options: .atomic) }
    return file
  }

  private var shouldRepeatWaitingAlert: Bool {
    let current = core?.calls ?? []
    return current.contains { $0.state == .IncomingReceived || $0.state == .IncomingEarlyMedia } &&
      current.contains { $0.state == .Connected || $0.state == .StreamsRunning }
  }

  private func reconcileWaitingAlert() {
    guard shouldRepeatWaitingAlert else {
      waitingAlertTimer?.invalidate()
      waitingAlertTimer = nil
      return
    }
    guard waitingAlertTimer == nil else { return }
    let timer = Timer(timeInterval: 5, repeats: true) { [weak self] timer in
      guard let self, self.shouldRepeatWaitingAlert, let currentCore = self.core else {
        timer.invalidate()
        self?.waitingAlertTimer = nil
        return
      }
      let level = DesktopAudioVolumeStore.level(for: DesktopAudioVolumeStore.waitingKey)
      guard level > 0 else { return }
      do {
        try currentCore.playLocal(audiofile: self.waitingAlertFile(level: level).path)
      } catch {
        NSLog("VoipCloud/Audio waiting alert repeat failed")
      }
    }
    waitingAlertTimer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  private func playAudioTestSound() throws {
    guard findCurrentCall() == nil else {
      throw NSError(
        domain: "VoIPCloud",
        code: 1401,
        userInfo: [NSLocalizedDescriptionKey: "Finish the current call before testing audio."]
      )
    }
    guard let currentCore = core else {
      throw NSError(
        domain: "VoIPCloud",
        code: 1402,
        userInfo: [NSLocalizedDescriptionKey: "Calling audio is not ready."]
      )
    }
    let toneURL = try makeAudioTestTone()
    try currentCore.playLocal(audiofile: toneURL.path)
  }

  private func startAudioInputTest(result: @escaping FlutterResult) {
    guard findCurrentCall() == nil else {
      result(FlutterError(
        code: "AUDIO_TEST_BUSY",
        message: "Finish the current call before testing audio.",
        details: nil
      ))
      return
    }
    let start = { [weak self] in
      guard let self else { return }
      do {
        try self.startAudioInputMeter()
        result(nil)
      } catch {
        result(FlutterError(
          code: "AUDIO_INPUT",
          message: error.localizedDescription,
          details: nil
        ))
      }
    }
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
      start()
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .audio) { allowed in
        DispatchQueue.main.async {
          if allowed {
            start()
          } else {
            result(FlutterError(
              code: "AUDIO_PERMISSION",
              message: "Microphone permission is required to test audio.",
              details: nil
            ))
          }
        }
      }
    default:
      result(FlutterError(
        code: "AUDIO_PERMISSION",
        message: "Microphone permission is required to test audio.",
        details: nil
      ))
    }
  }

  private func startAudioInputMeter() throws {
    stopAudioInputTest()
    let engine = AVAudioEngine()
    let input = engine.inputNode
    if let selectedName = core?.inputAudioDevice?.deviceName,
       let deviceId = coreAudioDeviceId(named: selectedName),
       let audioUnit = input.audioUnit {
      var mutableDeviceId = deviceId
      let status = AudioUnitSetProperty(
        audioUnit,
        kAudioOutputUnitProperty_CurrentDevice,
        kAudioUnitScope_Global,
        0,
        &mutableDeviceId,
        UInt32(MemoryLayout<AudioDeviceID>.size)
      )
      guard status == noErr else {
        throw NSError(
          domain: NSOSStatusErrorDomain,
          code: Int(status),
          userInfo: [NSLocalizedDescriptionKey: "The selected microphone could not be opened."]
        )
      }
    }
    let format = input.inputFormat(forBus: 0)
    guard format.channelCount > 0 else {
      throw NSError(
        domain: "VoIPCloud",
        code: 1403,
        userInfo: [NSLocalizedDescriptionKey: "No microphone is available."]
      )
    }
    input.installTap(onBus: 0, bufferSize: 1024, format: format) {
      [weak self] buffer, _ in
      guard let self,
            let channels = buffer.floatChannelData,
            buffer.frameLength > 0
      else { return }
      let frames = Int(buffer.frameLength)
      var sum: Float = 0
      for frame in 0..<frames {
        let sample = channels[0][frame]
        sum += sample * sample
      }
      let rms = sqrt(sum / Float(frames))
      let normalized = min(1, max(0, Double(rms) * 5.0))
      self.audioInputLevelLock.lock()
      self.audioInputLevel = normalized
      self.audioInputLevelLock.unlock()
    }
    engine.prepare()
    try engine.start()
    audioInputTestEngine = engine
  }

  private func stopAudioInputTest() {
    if let engine = audioInputTestEngine {
      engine.inputNode.removeTap(onBus: 0)
      engine.stop()
    }
    audioInputTestEngine = nil
    audioInputLevelLock.lock()
    audioInputLevel = 0
    audioInputLevelLock.unlock()
  }

  private func makeAudioTestTone() throws -> URL {
    if let url = audioTestToneURL,
       FileManager.default.fileExists(atPath: url.path) {
      return url
    }
    let sampleRate = 16_000
    let sampleCount = Int(Double(sampleRate) * 0.48)
    var samples = Data(capacity: sampleCount * 2)
    for index in 0..<sampleCount {
      let time = Double(index) / Double(sampleRate)
      let frequency = time < 0.24 ? 659.25 : 783.99
      let edge = min(1, min(time / 0.025, (0.48 - time) / 0.025))
      let value = Int16((sin(2 * .pi * frequency * time) * 0.28 * edge) * 32767)
      samples.appendLittleEndian(value)
    }
    var wave = Data()
    wave.append(contentsOf: "RIFF".utf8)
    wave.appendLittleEndian(UInt32(36 + samples.count))
    wave.append(contentsOf: "WAVEfmt ".utf8)
    wave.appendLittleEndian(UInt32(16))
    wave.appendLittleEndian(UInt16(1))
    wave.appendLittleEndian(UInt16(1))
    wave.appendLittleEndian(UInt32(sampleRate))
    wave.appendLittleEndian(UInt32(sampleRate * 2))
    wave.appendLittleEndian(UInt16(2))
    wave.appendLittleEndian(UInt16(16))
    wave.append(contentsOf: "data".utf8)
    wave.appendLittleEndian(UInt32(samples.count))
    wave.append(samples)
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("voipcloud-audio-test.wav")
    try wave.write(to: url, options: .atomic)
    audioTestToneURL = url
    return url
  }

  private func coreAudioDeviceId(named selectedName: String) -> AudioDeviceID? {
    var devicesAddress = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(
      AudioObjectID(kAudioObjectSystemObject),
      &devicesAddress,
      0,
      nil,
      &size
    ) == noErr else { return nil }
    var devices = [AudioDeviceID](
      repeating: 0,
      count: Int(size) / MemoryLayout<AudioDeviceID>.size
    )
    let deviceStatus = devices.withUnsafeMutableBytes { bytes in
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &devicesAddress,
        0,
        nil,
        &size,
        bytes.baseAddress
      )
    }
    guard deviceStatus == noErr else { return nil }
    let requested = selectedName.trimmingCharacters(in: .whitespacesAndNewlines)
    for device in devices {
      var nameAddress = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
      )
      var name: CFString = "" as CFString
      var nameSize = UInt32(MemoryLayout<CFString>.size)
      guard AudioObjectGetPropertyData(
        device,
        &nameAddress,
        0,
        nil,
        &nameSize,
        &name
      ) == noErr else { continue }
      if (name as String).caseInsensitiveCompare(requested) == .orderedSame {
        return device
      }
    }
    return nil
  }

  private func configureAccount(args: [String: Any]) throws {
    try initialize()
    guard let currentCore = core else { return }

    let username = stringArg(args, "sipUsername")
    let authUsernameValue = stringArg(args, "authUsername")
    let authUsername = authUsernameValue.isEmpty ? username : authUsernameValue
    let password = stringArg(args, "password")
    let ha1 = stringArg(args, "ha1")
    let algorithm = stringArg(args, "algorithm")
    let domain = stringArg(args, "domain")
    let registrar = stringArg(args, "registrar").isEmpty ? domain : stringArg(args, "registrar")
    let realm = stringArg(args, "realm").isEmpty ? domain : stringArg(args, "realm")
    let authDomain = stringArg(args, "authDomain").isEmpty ? realm : stringArg(args, "authDomain")
    let outboundProxy = stringArg(args, "outboundProxy")
    let stunServer = stringArg(args, "stunServer")
    let turnServer = stringArg(args, "turnServer")

    stopPresenceSubscriptions()
    currentCore.clearAccounts()
    currentCore.clearAllAuthInfo()
    try configureNatPolicy(core: currentCore, stunServer: stunServer, turnServer: turnServer)

    let authInfo = try Factory.Instance.createAuthInfo(
      username: authUsername,
      userid: username,
      passwd: password.isEmpty ? nil : password,
      ha1: ha1.isEmpty ? nil : ha1,
      realm: realm,
      domain: authDomain,
      algorithm: algorithm.isEmpty ? nil : algorithm
    )
    currentCore.addAuthInfo(info: authInfo)

    let identity = try Factory.Instance.createAddress(addr: "sip:\(username)@\(domain)")
    let displayName = stringArg(args, "displayName")
    if !displayName.isEmpty {
      try identity.setDisplayname(newValue: displayName)
    }

    let serverAddress = try Factory.Instance.createAddress(
      addr: normalizeSipAddress(registrar)
    )
    try serverAddress.setTransport(newValue: transportType(stringArg(args, "transport")))

    let params = try currentCore.createAccountParams()
    try params.setIdentityaddress(newValue: identity)
    try params.setServeraddress(newValue: serverAddress)
    if !outboundProxy.isEmpty {
      params.outboundProxyEnabled = true
      let route = try Factory.Instance.createAddress(addr: outboundProxy)
      try route.setTransport(newValue: transportType(stringArg(args, "transport")))
      try params.setRoutesaddresses(newValue: [route])
    } else {
      params.outboundProxyEnabled = false
    }
    params.registerEnabled = true

    let newAccount = try currentCore.createAccount(params: params)
    try currentCore.addAccount(account: newAccount)
    currentCore.defaultAccount = newAccount
    account = newAccount
    registrationEvents.send(["status": "configuring", "message": "SIP account configured"])
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
    if !enabled {
      stopPresenceSubscriptions()
    }
    guard let currentCore = core else {
      return
    }
    let accounts = currentCore.accountList
    for currentAccount in accounts {
      guard let params = currentAccount.params else { continue }
      params.registerEnabled = enabled
      currentAccount.params = params
    }
    account = currentCore.defaultAccount ?? accounts.first
  }

  private func setNativeDnd(enabled: Bool) {
    DesktopDndStore.isEnabled = enabled
    deviceDndEnabled = enabled
    guard enabled, let call = findCurrentCall(), isIncomingRinging(call) else { return }
    let key = ObjectIdentifier(call)
    guard dndDeclinedCalls.insert(key).inserted else { return }
    clearDesktopCallNotification(callId: callId(call))
    do {
      try call.decline(reason: .Busy)
    } catch {
      NSLog("VoIPCloud/macOS device DND decline failed: %@", error.localizedDescription)
    }
  }

  private func purgeAccount() {
    stopPresenceSubscriptions()
    core?.clearAccounts()
    core?.clearAllAuthInfo()
    account = nil
    NSLog("VoIPCloud/Linphone purged logged-out SIP account")
  }

  private func makeCall(destination: String) throws {
    guard let currentCore = core else { return }
    let address = try normalizeDestination(destination)
    let params = try currentCore.createCallParams(call: nil)
    params.videoEnabled = false
    let call = currentCore.inviteAddressWithParams(addr: address, params: params)
      ?? currentCore.inviteAddress(addr: address)
    if let call {
      calls[callId(call)] = call
      emitCall(call: call, state: call.state)
    }
  }

  private func dialFeatureCode(code: String) throws -> String {
    let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw NSError(
        domain: "VoIPCloud",
        code: 1010,
        userInfo: [NSLocalizedDescriptionKey: "Feature code is required."]
      )
    }
    guard let currentCore = core else {
      throw NSError(
        domain: "VoIPCloud",
        code: 1002,
        userInfo: [NSLocalizedDescriptionKey: "The SIP engine is unavailable."]
      )
    }
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
        domain: "VoIPCloud",
        code: 1011,
        userInfo: [NSLocalizedDescriptionKey: "Unable to dial feature code."]
      )
    }
    let id = callId(call)
    featureCodeCalls.insert(ObjectIdentifier(call))
    calls[id] = call
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

  private func sendMessage(destination: String, text: String) throws {
    guard let currentCore = core, !destination.trimmingCharacters(in: .whitespaces).isEmpty else {
      return
    }
    let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedText.isEmpty else { return }

    let peer = try normalizeDestination(destination)
    let params = try currentCore.createDefaultChatRoomParams()
    let chatRoom = try currentCore.createChatRoom(
      params: params,
      localAddr: account?.params?.identityAddress,
      participants: [peer]
    )
    let message = try chatRoom.createMessageFromUtf8(message: trimmedText)
    message.send()
    emitMessage(message: message, direction: "outgoing", fallbackStatus: "sent")
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
        event.terminate()
        presenceEvents.send([
          "kind": "subscription",
          "extension": extensionNumber,
          "event": eventPackage,
          "state": "error"
        ])
      }
      }
    }
  }

  private func stopPresenceSubscriptions() {
    let subscriptions = presenceSubscriptions.values.map { $0.0 }
    presenceSubscriptions.removeAll()
    subscriptions.forEach { $0.terminate() }
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

  private func availableAudioDevices() -> [AudioDevice] {
    guard let currentCore = core else { return [] }
    let extended = currentCore.extendedAudioDevices
    return extended.isEmpty ? currentCore.audioDevices : extended
  }

  private func audioEndpointId(_ device: AudioDevice) -> String {
    "macos:\(device.driverName):\(device.deviceName):\(String(describing: device.type))"
  }

  private func audioRoute(_ device: AudioDevice) -> String {
    let description = "\(device.deviceName) \(String(describing: device.type))".lowercased()
    if description.contains("bluetooth") || description.contains("airpods") {
      return "bluetooth"
    }
    if description.contains("headphone") || description.contains("headset") ||
       description.contains("usb") {
      return "wired"
    }
    if description.contains("built-in") || description.contains("builtin") ||
       device.type == .Speaker {
      return "speaker"
    }
    return "streaming"
  }

  private func outputAudioDevices() -> [AudioDevice] {
    availableAudioDevices().filter { device in
      String(describing: device.type).caseInsensitiveCompare("Microphone") != .orderedSame
    }
  }

  private func completeAttendedTransfer(
    originalCallId: String,
    consultationCallId: String
  ) throws {
    guard let original = findCallStrict(id: originalCallId),
          let consultation = findCallStrict(id: consultationCallId),
          ObjectIdentifier(original) != ObjectIdentifier(consultation) else {
      throw NSError(
        domain: "VoIPCloud",
        code: 1410,
        userInfo: [NSLocalizedDescriptionKey: "Two established calls are required for attended transfer."]
      )
    }
    try original.transferToAnother(dest: consultation)
    NSLog(
      "VoIPCloud/macOS attended transfer original=%@ consultation=%@",
      originalCallId,
      consultationCallId
    )
  }

  private func mergeCalls(activeCallId: String, heldCallId: String) throws {
    guard let currentCore = core,
          let active = findCallStrict(id: activeCallId),
          let held = findCallStrict(id: heldCallId),
          ObjectIdentifier(active) != ObjectIdentifier(held) else {
      throw NSError(
        domain: "VoIPCloud",
        code: 1411,
        userInfo: [NSLocalizedDescriptionKey: "Two established calls are required to merge."]
      )
    }
    try currentCore.addToConference(call: active)
    do {
      try currentCore.addToConference(call: held)
    } catch {
      try? currentCore.removeFromConference(call: active)
      throw error
    }
    NSLog("VoIPCloud/macOS conference merged active=%@ held=%@", activeCallId, heldCallId)
  }

  private func isInputAudioDevice(_ device: AudioDevice) -> Bool {
    String(describing: device.type).caseInsensitiveCompare("Microphone") == .orderedSame
  }

  private func inputAudioDevices() -> [AudioDevice] {
    availableAudioDevices().filter(isInputAudioDevice)
  }

  private func audioEndpoints() -> [[String: Any]] {
    let currentId: String?
    if let selectedAudioEndpointId {
      currentId = selectedAudioEndpointId
    } else if let currentDevice = core?.outputAudioDevice {
      currentId = audioEndpointId(currentDevice)
    } else {
      currentId = nil
    }
    let outputs: [[String: Any]] = outputAudioDevices().map { device in
      let id = audioEndpointId(device)
      return [
        "id": id,
        "direction": "output",
        "route": audioRoute(device),
        "label": device.deviceName.isEmpty ? "System audio" : device.deviceName,
        "available": true,
        "selected": id == currentId
      ]
    }
    let currentInputId = selectedAudioInputEndpointId
      ?? core?.inputAudioDevice.map(audioEndpointId)
    let inputs: [[String: Any]] = inputAudioDevices().map { device in
      let id = audioEndpointId(device)
      return [
        "id": id,
        "direction": "input",
        "route": audioRoute(device),
        "label": device.deviceName.isEmpty ? "System microphone" : device.deviceName,
        "available": true,
        "selected": id == currentInputId
      ]
    }
    return outputs + inputs
  }

  private func setAudioEndpoint(
    endpointId: String?,
    fallbackRoute: String
  ) throws -> String {
    guard let currentCore = core else {
      throw NSError(
        domain: "SoftphoneAudioRoute",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "The audio engine is unavailable."]
      )
    }
    let devices = outputAudioDevices()
    let selected = endpointId.flatMap { requestedId in
      devices.first(where: { audioEndpointId($0) == requestedId })
    } ?? devices.first(where: { audioRoute($0) == fallbackRoute })
    guard let selected else {
      throw NSError(
        domain: "SoftphoneAudioRoute",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: "The selected audio device is unavailable."]
      )
    }
    selectedAudioEndpointId = audioEndpointId(selected)
    UserDefaults.standard.set(selectedAudioEndpointId, forKey: "VoipCloudAudioOutputEndpoint")
    currentCore.defaultOutputAudioDevice = selected
    currentCore.outputAudioDevice = selected
    if let currentCall = findCurrentCall() {
      currentCall.outputAudioDevice = selected
      emitCall(call: currentCall, state: currentCall.state)
    }
    return audioRoute(selected)
  }

  private func setAudioInputEndpoint(endpointId: String?) throws -> String {
    guard let currentCore = core else {
      throw NSError(
        domain: "SoftphoneAudioRoute",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "The audio engine is unavailable."]
      )
    }
    let selected = endpointId.flatMap { requestedId in
      inputAudioDevices().first(where: { audioEndpointId($0) == requestedId })
    }
    guard let selected else {
      throw NSError(
        domain: "SoftphoneAudioRoute",
        code: 3,
        userInfo: [NSLocalizedDescriptionKey: "The selected microphone is unavailable."]
      )
    }
    selectedAudioInputEndpointId = audioEndpointId(selected)
    UserDefaults.standard.set(
      selectedAudioInputEndpointId,
      forKey: "VoipCloudAudioInputEndpoint"
    )
    currentCore.defaultInputAudioDevice = selected
    currentCore.inputAudioDevice = selected
    if let currentCall = findCurrentCall() {
      currentCall.inputAudioDevice = selected
      emitCall(call: currentCall, state: currentCall.state)
    }
    return audioEndpointId(selected)
  }

  private func restorePreferredAudioDevices() {
    guard let currentCore = core else { return }
    if let preferredOutput = UserDefaults.standard.string(
      forKey: "VoipCloudAudioOutputEndpoint"
    ), let device = outputAudioDevices().first(where: {
      audioEndpointId($0) == preferredOutput
    }) {
      selectedAudioEndpointId = preferredOutput
      currentCore.defaultOutputAudioDevice = device
      currentCore.outputAudioDevice = device
    }
    if let preferredInput = UserDefaults.standard.string(
      forKey: "VoipCloudAudioInputEndpoint"
    ), let device = inputAudioDevices().first(where: {
      audioEndpointId($0) == preferredInput
    }) {
      selectedAudioInputEndpointId = preferredInput
      currentCore.defaultInputAudioDevice = device
      currentCore.inputAudioDevice = device
    }
  }

  private func gainDb(for level: Int) -> Float {
    let clamped = min(100, max(0, level))
    guard clamped > 0 else { return -80 }
    return 20 * log10(Float(clamped) / 100)
  }

  private func audioVolumeLevels() -> [String: Int] {
    return [
      "microphone": DesktopAudioVolumeStore.level(
        for: DesktopAudioVolumeStore.microphoneKey
      ),
      "callAudio": DesktopAudioVolumeStore.level(
        for: DesktopAudioVolumeStore.callAudioKey
      ),
      "ringtone": DesktopAudioVolumeStore.level(
        for: DesktopAudioVolumeStore.ringtoneKey
      ),
      "ringback": DesktopAudioVolumeStore.level(
        for: DesktopAudioVolumeStore.ringbackKey
      ),
      "callWaiting": DesktopAudioVolumeStore.level(for: DesktopAudioVolumeStore.waitingKey)
    ]
  }

  private func restoreAudioVolumes(on currentCore: Core) {
    currentCore.micGainDb = gainDb(for: DesktopAudioVolumeStore.level(
      for: DesktopAudioVolumeStore.microphoneKey
    ))
    currentCore.playbackGainDb = gainDb(for: DesktopAudioVolumeStore.level(
      for: DesktopAudioVolumeStore.callAudioKey
    ))
    do {
      try applyRingtoneVolume(
        on: currentCore,
        level: DesktopAudioVolumeStore.level(for: DesktopAudioVolumeStore.ringtoneKey)
      )
    } catch {
      NSLog("Softphone/Audio ringtone level could not be restored: %@", error.localizedDescription)
    }
    do {
      try applyRingbackVolume(
        on: currentCore,
        level: DesktopAudioVolumeStore.level(for: DesktopAudioVolumeStore.ringbackKey)
      )
    } catch {
      NSLog("Softphone/Audio ringback level could not be restored: %@", error.localizedDescription)
    }
  }

  private func configureDesktopCallSounds(on currentCore: Core) {
    let existingRing = currentCore.ring
    ringtoneSourceURL = desktopSoundURL(
      relativePath: "rings/oldphone-mono.wav",
      preferredPath: existingRing
    )
    if let ringtoneSourceURL { currentCore.ring = ringtoneSourceURL.path }
    ringbackSourceURL = desktopSoundURL(
      relativePath: "ringback.wav",
      preferredPath: currentCore.ringback
    ) ?? (try? makeDesktopRingbackTone())
    if let ringbackURL = ringbackSourceURL {
      currentCore.ringback = ringbackURL.path
    } else {
      NSLog("Softphone/Audio outgoing ringback could not be prepared")
    }
  }

  private func makeDesktopRingbackTone() throws -> URL {
    // North American ringback cadence: two seconds of tone, four seconds quiet.
    let sampleRate = 8_000
    let sampleCount = sampleRate * 6
    var samples = Data(capacity: sampleCount * 2)
    for index in 0..<sampleCount {
      let time = Double(index) / Double(sampleRate)
      let value: Int16
      if time < 2 {
        let edge = min(1, min(time / 0.01, (2 - time) / 0.01))
        let tone = (sin(2 * .pi * 440 * time) + sin(2 * .pi * 480 * time)) * 0.13
        value = Int16(tone * edge * 32767)
      } else {
        value = 0
      }
      samples.appendLittleEndian(value)
    }
    var wave = Data()
    wave.append(contentsOf: "RIFF".utf8)
    wave.appendLittleEndian(UInt32(36 + samples.count))
    wave.append(contentsOf: "WAVEfmt ".utf8)
    wave.appendLittleEndian(UInt32(16))
    wave.appendLittleEndian(UInt16(1))
    wave.appendLittleEndian(UInt16(1))
    wave.appendLittleEndian(UInt32(sampleRate))
    wave.appendLittleEndian(UInt32(sampleRate * 2))
    wave.appendLittleEndian(UInt16(2))
    wave.appendLittleEndian(UInt16(16))
    wave.append(contentsOf: "data".utf8)
    wave.appendLittleEndian(UInt32(samples.count))
    wave.append(samples)
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("VoipCloud-ringback-\(ProcessInfo.processInfo.processIdentifier).wav")
    try wave.write(to: url, options: .atomic)
    return url
  }

  private func desktopSoundURL(relativePath: String, preferredPath: String?) -> URL? {
    let files = FileManager.default
    if let preferredPath, !preferredPath.isEmpty,
      files.fileExists(atPath: preferredPath) {
      return URL(fileURLWithPath: preferredPath)
    }
    for bundle in [Bundle.main] + Bundle.allFrameworks {
      guard let root = bundle.resourceURL else { continue }
      for prefix in ["share/sounds/linphone", "sounds/linphone"] {
        let candidate = root.appendingPathComponent(prefix)
          .appendingPathComponent(relativePath)
        if files.fileExists(atPath: candidate.path) { return candidate }
      }
    }
    return nil
  }

  private func applyRingtoneVolume(on currentCore: Core, level: Int) throws {
    guard let source = ringtoneSourceURL else {
      throw NSError(domain: "VoIPCloud", code: 1404,
        userInfo: [NSLocalizedDescriptionKey: "The packaged ringtone is unavailable."])
    }
    currentCore.ring = try scaledDesktopSoundURL(
      source: source, level: level, name: "ringtone"
    ).path
  }

  private func applyRingbackVolume(on currentCore: Core, level: Int) throws {
    guard let source = ringbackSourceURL else {
      throw NSError(domain: "VoIPCloud", code: 1407,
        userInfo: [NSLocalizedDescriptionKey: "The outgoing ringback sound is unavailable."])
    }
    currentCore.ringback = try scaledDesktopSoundURL(
      source: source, level: level, name: "ringback"
    ).path
  }

  private func scaledDesktopSoundURL(source: URL, level: Int, name: String) throws -> URL {
    if level == 100 { return source }
    var bytes = [UInt8](try Data(contentsOf: source))
    guard bytes.count >= 44,
      String(bytes: bytes[0..<4], encoding: .ascii) == "RIFF",
      String(bytes: bytes[8..<12], encoding: .ascii) == "WAVE" else {
      throw NSError(domain: "VoIPCloud", code: 1405,
        userInfo: [NSLocalizedDescriptionKey: "The ringtone is not a WAV file."])
    }
    func u16(_ offset: Int) -> Int {
      Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
    }
    func u32(_ offset: Int) -> Int {
      u16(offset) | (u16(offset + 2) << 16)
    }
    var pcm16 = false
    var audioRange: Range<Int>?
    var offset = 12
    while offset + 8 <= bytes.count {
      let size = u32(offset + 4)
      let start = offset + 8
      guard size <= bytes.count - start else { break }
      let kind = String(bytes: bytes[offset..<(offset + 4)], encoding: .ascii)
      if kind == "fmt " && size >= 16 {
        pcm16 = u16(start) == 1 && u16(start + 14) == 16
      } else if kind == "data" {
        audioRange = start..<(start + size)
      }
      offset = start + size + (size & 1)
    }
    guard pcm16, let range = audioRange, !range.isEmpty, range.count.isMultiple(of: 2) else {
      throw NSError(domain: "VoIPCloud", code: 1406,
        userInfo: [NSLocalizedDescriptionKey: "The ringtone is not 16-bit PCM audio."])
    }
    for index in stride(from: range.lowerBound, to: range.upperBound, by: 2) {
      let sample = Int(Int16(bitPattern: UInt16(u16(index))))
      let scaled = Int16(sample * level / 100)
      let bits = UInt16(bitPattern: scaled)
      bytes[index] = UInt8(bits & 0xff)
      bytes[index + 1] = UInt8(bits >> 8)
    }
    let output = FileManager.default.temporaryDirectory.appendingPathComponent(
      "VoipCloud-\(name)-\(ProcessInfo.processInfo.processIdentifier)-\(level).wav"
    )
    try Data(bytes).write(to: output, options: .atomic)
    return output
  }

  private func setAudioVolume(call: FlutterMethodCall) throws {
    guard let currentCore = core else {
      throw NSError(
        domain: "VoIPCloud",
        code: 1402,
        userInfo: [NSLocalizedDescriptionKey: "The audio engine is unavailable."]
      )
    }
    let args = call.arguments as? [String: Any] ?? [:]
    let kind = args["kind"] as? String ?? ""
    let level = min(100, max(0, (args["level"] as? NSNumber)?.intValue ?? 100))
    switch kind {
    case "microphone":
      DesktopAudioVolumeStore.set(level, for: DesktopAudioVolumeStore.microphoneKey)
      currentCore.micGainDb = gainDb(for: level)
    case "callAudio":
      DesktopAudioVolumeStore.set(level, for: DesktopAudioVolumeStore.callAudioKey)
      currentCore.playbackGainDb = gainDb(for: level)
    case "ringtone":
      try applyRingtoneVolume(on: currentCore, level: level)
      DesktopAudioVolumeStore.set(level, for: DesktopAudioVolumeStore.ringtoneKey)
    case "ringback":
      try applyRingbackVolume(on: currentCore, level: level)
      DesktopAudioVolumeStore.set(level, for: DesktopAudioVolumeStore.ringbackKey)
    case "callWaiting":
      let tone = try waitingAlertFile(level: level)
      currentCore.setTone(toneId: .CallWaiting, audiofile: tone.path)
      DesktopAudioVolumeStore.set(level, for: DesktopAudioVolumeStore.waitingKey)
    default:
      throw NSError(
        domain: "VoIPCloud",
        code: 1403,
        userInfo: [NSLocalizedDescriptionKey: "Unknown desktop audio volume control."]
      )
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
    if state == .Paused || state == .Pausing {
      return
    }
    guard state == .StreamsRunning || state == .Connected else {
      throw NSError(
        domain: "VoIPCloud",
        code: 409,
        userInfo: [NSLocalizedDescriptionKey: "Cannot hold call while it is \(state)."]
      )
    }
    do {
      try activeCall.pause()
    } catch {
      guard let currentCore = core else { throw error }
      let params = try currentCore.createCallParams(call: activeCall)
      params.videoEnabled = false
      params.audioDirection = .SendOnly
      try activeCall.update(params: params)
    }
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
    if state == .StreamsRunning || state == .Connected {
      return
    }
    guard state == .Paused || state == .PausedByRemote || state == .Pausing else {
      throw NSError(
        domain: "VoIPCloud",
        code: 409,
        userInfo: [NSLocalizedDescriptionKey: "Cannot resume call while it is \(state)."]
      )
    }
    do {
      try activeCall.resume()
    } catch {
      guard let currentCore = core else { throw error }
      let params = try currentCore.createCallParams(call: activeCall)
      params.videoEnabled = false
      params.audioDirection = .SendRecv
      try activeCall.update(params: params)
    }
  }

  private func findCall(id: String) -> Call? {
    if !id.isEmpty, let call = calls[id] {
      return call
    }
    return findCurrentCall()
  }

  private func getCallQuality(callId: String) throws -> [String: Any?] {
    guard let active = findCall(id: callId) ?? findCurrentCall() else {
      throw NSError(
        domain: "SoftphoneLinphone",
        code: 1007,
        userInfo: [NSLocalizedDescriptionKey: "There is no active call."]
      )
    }
    let stats = active.audioStats
    let current = Double(active.currentQuality)
    let average = Double(active.averageQuality)
    let roundTripMs = stats.map { Double($0.roundTripDelay) * 1000.0 }
    let codec = active.currentParams?.usedAudioPayloadType?.mimeType
    let route = active.outputAudioDevice.map(audioRoute) ?? "speaker"
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
      "audioRoute": route,
      "remoteUri": active.remoteAddress?.asStringUriOnly() ?? "",
    ]
  }

  private func findCurrentCall() -> Call? {
    if let current = core?.currentCall, !isTerminalCallState(current.state) {
      return current
    }
    return calls.values.first(where: { !isTerminalCallState($0.state) })
  }

  private func syncCurrentCall(reason: String) {
    guard let call = findCurrentCall() else {
      calls.removeAll()
      callEvents.send(["status": "none"])
      return
    }
    emitCall(call: call, state: call.state)
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

  private func emitRegistration(state: RegistrationState, message: String) {
    registrationEvents.send([
      "status": registrationState(state),
      "message": message.isEmpty ? nil : message
    ])
  }

  private func emitCall(
    call: Call,
    state: Call.State,
    featureCode: Bool? = nil,
    stateMessage: String? = nil
  ) {
    let id = callId(call)
    let terminationMessage = [
      stateMessage,
      call.errorInfo?.phrase,
      call.errorInfo?.subErrorInfo?.phrase,
      locallyDeclinedCallIds.contains(id) ? "Locally declined" : nil
    ]
      .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .reduce(into: [String]()) { values, value in
        if !values.contains(value) { values.append(value) }
      }
      .joined(separator: " | ")
    if isTerminalCallState(state) {
      calls.removeValue(forKey: id)
      dndDeclinedCalls.remove(ObjectIdentifier(call))
    } else {
      calls[id] = call
    }
    let isFeatureCode = featureCode ?? featureCodeCalls.contains(ObjectIdentifier(call))
    let endpoints = audioEndpoints()
    let currentEndpointId = endpoints.first(where: {
      $0["selected"] as? Bool == true
    })?["id"] as? String
    let route = endpoints.first(where: {
      $0["selected"] as? Bool == true
    })?["route"] as? String ?? "streaming"
    callEvents.send([
      "id": id,
      "remoteUri": call.remoteAddress?.asStringUriOnly() ?? "",
      "remoteDisplayName": call.remoteAddress?.displayName ?? call.remoteAddress?.username ?? "",
      "direction": call.dir == .Incoming ? "incoming" : "outgoing",
      "status": callStatus(state),
      "startedAt": Date().iso8601String,
      "isMuted": core?.micEnabled == false,
      "isSpeakerEnabled": route == "speaker",
      "audioRoute": route,
      "currentEndpointId": currentEndpointId,
      "availableEndpoints": endpoints,
      "featureCode": isFeatureCode,
      "stateMessage": terminationMessage
    ])
    if isTerminalCallState(state) {
      locallyDeclinedCallIds.remove(id)
    }
    if deviceDndEnabled && call.dir == .Incoming && isIncomingRinging(call) {
      clearDesktopCallNotification(callId: id)
      let key = ObjectIdentifier(call)
      if dndDeclinedCalls.insert(key).inserted {
        do {
          try call.decline(reason: .Busy)
        } catch {
          NSLog("VoIPCloud/macOS device DND decline failed: %@", error.localizedDescription)
        }
      }
      return
    }
    updateDesktopCallNotification(call: call, state: state, callId: id)
  }

  private func clearDesktopCallNotification(callId: String) {
    let notificationId = "voipcloud.call.\(callId)"
    desktopNotificationCallIds.remove(callId)
    let center = UNUserNotificationCenter.current()
    center.removePendingNotificationRequests(withIdentifiers: [notificationId])
    center.removeDeliveredNotifications(withIdentifiers: [notificationId])
  }

  private func updateDesktopCallNotification(
    call: Call,
    state: Call.State,
    callId: String
  ) {
    let notificationId = "voipcloud.call.\(callId)"
    guard call.dir == .Incoming, isIncomingRinging(call) else {
      if desktopNotificationCallIds.remove(callId) != nil {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [notificationId])
        center.removeDeliveredNotifications(withIdentifiers: [notificationId])
      }
      return
    }
    guard !(NSApp.isActive && NSApp.mainWindow?.isVisible == true) else { return }
    guard desktopNotificationCallIds.insert(callId).inserted else { return }

    let caller = (call.remoteAddress?.displayName ?? call.remoteAddress?.username ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let content = UNMutableNotificationContent()
    content.title = "Incoming call"
    content.body = caller.isEmpty ? "VoipCloud call" : caller
    content.sound = .default
    content.categoryIdentifier = DesktopCallNotification.category
    content.userInfo = [DesktopCallNotification.callIdKey: callId]
    UNUserNotificationCenter.current().add(
      UNNotificationRequest(identifier: notificationId, content: content, trigger: nil)
    ) { error in
      if let error {
        NSLog("VoIPCloud/macOS incoming-call notification failed: %@", error.localizedDescription)
      }
    }
  }

  private func answerIncomingCallFromNotification(_ notification: Notification) {
    let requestedId = notification.userInfo?[DesktopCallNotification.callIdKey] as? String ?? ""
    guard let call = findCall(id: requestedId), isIncomingRinging(call) else { return }
    do {
      try call.accept()
    } catch {
      NSLog("VoIPCloud/macOS native answer failed: %@", error.localizedDescription)
    }
  }

  private func declineIncomingCallFromNotification(_ notification: Notification) {
    let requestedId = notification.userInfo?[DesktopCallNotification.callIdKey] as? String ?? ""
    guard let call = findCall(id: requestedId), isIncomingRinging(call) else { return }
    do {
      locallyDeclinedCallIds.insert(callId(call))
      try call.decline(reason: .Busy)
    } catch {
      locallyDeclinedCallIds.remove(callId(call))
      NSLog("VoIPCloud/macOS native decline failed: %@", error.localizedDescription)
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

  private func findCallStrict(id: String) -> Call? {
    guard !id.isEmpty else { return nil }
    if let call = calls[id], !isTerminalCallState(call.state) { return call }
    return core?.calls.first(where: {
      !isTerminalCallState($0.state) && callId($0) == id
    })
  }

  private func dispose() {
    waitingPreviewPlayer?.stop()
    waitingPreviewPlayer = nil
    waitingAlertTimer?.invalidate()
    waitingAlertTimer = nil
    stopAudioInputTest()
    stopPresenceSubscriptions()
    if let delegate {
      core?.removeDelegate(delegate: delegate)
    }
    core?.stop()
    core = nil
    account = nil
    delegate = nil
    calls.removeAll()
    let identifiers = desktopNotificationCallIds.map { "voipcloud.call.\($0)" }
    desktopNotificationCallIds.removeAll()
    UNUserNotificationCenter.current().removePendingNotificationRequests(
      withIdentifiers: identifiers
    )
    UNUserNotificationCenter.current().removeDeliveredNotifications(
      withIdentifiers: identifiers
    )
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

private extension Data {
  mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
    var littleEndian = value.littleEndian
    Swift.withUnsafeBytes(of: &littleEndian) { bytes in
      append(contentsOf: bytes)
    }
  }

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

private func registrationState(_ state: RegistrationState) -> String {
  switch state {
  case .Ok:
    return "registered"
  case .Progress:
    return "registering"
  case .Failed:
    return "failed"
  case .Cleared:
    return "unregistered"
  default:
    return "unregistered"
  }
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
