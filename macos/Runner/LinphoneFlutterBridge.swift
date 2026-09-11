import Cocoa
import FlutterMacOS
import Foundation
import UserNotifications

#if canImport(linphonesw)
import linphonesw
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
  private let callEvents = LinphoneEventStreamHandler()
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
  private var eventSink: FlutterEventSink?

  func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  func send(_ event: [String: Any?]) {
    DispatchQueue.main.async { [weak self] in
      self?.eventSink?(event)
    }
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
  private var account: Account?
  private var delegate: CoreDelegateStub?
  private var calls: [String: Call] = [:]
  private var featureCodeCalls = Set<ObjectIdentifier>()
  private var featureCodeTerminateScheduled = Set<ObjectIdentifier>()
  private var featureCodePreviousMicEnabled: Bool?
  private var pendingFeatureCodeDial = false
  private var presenceSubscriptions: [ObjectIdentifier: (Event, String, String)] = [:]
  private var selectedAudioEndpointId: String?
  private var desktopNotificationCallIds = Set<String>()
  private var dndDeclinedCalls = Set<ObjectIdentifier>()
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
        try findCall(id: argument(call, "callId"))?.decline(reason: .Declined)
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
      case "sendDtmf":
        try findCurrentCall()?.sendDtmf(dtmf: firstDtmf(argument(call, "value")))
        result(nil)
      case "getCallQuality":
        result(try getCallQuality(callId: argument(call, "callId")))
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
    let appVersion = Bundle.main.object(
      forInfoDictionaryKey: "CFBundleShortVersionString"
    ) as? String ?? "0.1.0"
    newCore.setUserAgent(name: "VoIPCloud-macOS", version: appVersion)
    newCore.ipv6Enabled = true
    newCore.micEnabled = true
    newCore.config?.setInt(section: "sip", key: "inactive_audio_on_pause", value: 0)
    newCore.avpfMode = .Disabled

    let newDelegate = CoreDelegateStub(
      onCallStateChanged: { [weak self] _, call, state, _ in
        guard let self else { return }
        let id = self.callId(call)
        self.calls[id] = call
        let featureKey = ObjectIdentifier(call)
        if self.pendingFeatureCodeDial {
          self.featureCodeCalls.insert(featureKey)
        }
        if self.featureCodeCalls.contains(featureKey) {
          self.maybeTerminateFeatureCodeCall(call: call, state: state)
          self.emitCall(call: call, state: state, featureCode: true)
          if self.isTerminalCallState(state) {
            self.clearFeatureCodeCall(call: call)
          }
          return
        }
        self.emitCall(call: call, state: state, featureCode: false)
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
        self.selectedAudioEndpointId = self.audioEndpointId(device)
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
    registrationEvents.send(["status": "unregistered", "message": nil])
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
      try call.decline(reason: .Declined)
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
    let params =…681 tokens truncated…izedDescriptionKey: "Linphone core is not initialized."]
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

  private func matchingInputDevice(for output: AudioDevice) -> AudioDevice? {
    let inputs = availableAudioDevices().filter {
      String(describing: $0.type).caseInsensitiveCompare("Microphone") == .orderedSame
    }
    return inputs.first(where: {
      $0.driverName == output.driverName && $0.deviceName == output.deviceName
    }) ?? inputs.first(where: {
      $0.driverName == output.driverName
    })
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
    return outputAudioDevices().map { device in
      let id = audioEndpointId(device)
      return [
        "id": id,
        "route": audioRoute(device),
        "label": device.deviceName.isEmpty ? "System audio" : device.deviceName,
        "available": true,
        "selected": id == currentId
      ]
    }
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
    currentCore.defaultOutputAudioDevice = selected
    currentCore.outputAudioDevice = selected
    let matchingInput = matchingInputDevice(for: selected)
    if let matchingInput {
      currentCore.defaultInputAudioDevice = matchingInput
      currentCore.inputAudioDevice = matchingInput
    }
    if let currentCall = findCurrentCall() {
      currentCall.outputAudioDevice = selected
      if let matchingInput {
        currentCall.inputAudioDevice = matchingInput
      }
      emitCall(call: currentCall, state: currentCall.state)
    }
    return audioRoute(selected)
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

  private func emitCall(call: Call, state: Call.State, featureCode: Bool? = nil) {
    let id = callId(call)
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
      "featureCode": isFeatureCode
    ])
    if deviceDndEnabled && call.dir == .Incoming && isIncomingRinging(call) {
      clearDesktopCallNotification(callId: id)
      let key = ObjectIdentifier(call)
      if dndDeclinedCalls.insert(key).inserted {
        do {
          try call.decline(reason: .Declined)
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
      try call.decline(reason: .Declined)
    } catch {
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
