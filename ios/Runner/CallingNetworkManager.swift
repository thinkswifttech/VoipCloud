// DRAFT - written on Windows, never compiled or run. Not part of the Xcode
// project yet (see README.md in this folder).
//
// Swift counterpart of android/.../CallingNetworkManager.kt.
//
// Rules (identical to Android):
// - Auto, disabled, a VPN, or a build whose SDK cannot bind sockets leave
//   routing to the system.
// - Wi-Fi / Mobile data: use the preferred path when usable, otherwise the
//   other usable path, for registration and new or incoming calls.
// - The route never changes while a call is live. A call keeps its network.
// - When the exact bound interface is lost, its calls cannot recover (sockets
//   are pinned). The hang-up is held back briefly until the SDK has a working
//   connection so the BYE can reach the server, then every live call ends with
//   the reason "calling_network_lost:<wifi|cellular>". The route is reselected
//   only after the calls are released plus a short settle time.
// - Weak signal, failed probes or lost internet access never end a call.
//
// All mutable state is touched only on `queue`.

import Foundation
import Network

final class CallingNetworkManager {
  /// Everything the manager needs from the app. Keeping the SDK out of this
  /// class lets it be tested without Linphone.
  struct Hooks {
    /// Registrar host and port that each path is validated against.
    var endpoint: () -> (host: String, port: UInt16)?
    var hasLiveCall: () -> Bool
    /// True once the SDK is registered again after a connection change.
    var isRegistered: () -> Bool
    /// SDK offline (true) / online (false): moves registration to a new route.
    var setSdkOffline: (Bool) -> Void
    /// Ends every live call; `reason` is "calling_network_lost:<path>".
    var endCalls: (_ path: CallingNetworkPath, _ reason: String) -> Void
    var onStatusChanged: () -> Void
  }

  private final class Slot {
    let path: CallingNetworkPath
    /// Recreated on every start(): a cancelled NWPathMonitor cannot be restarted.
    var monitor: NWPathMonitor
    var interface: NWInterface?
    var lastProbe = Date.distantPast
    var satisfied = false
    var validated = false
    var healthySince: Date?
    var probing = false
    /// Bumped whenever the interface or its tracking changes; stale probes are dropped.
    var generation = 0
    var consecutiveFailures = 0
    var firstFailure: Date?

    init(path: CallingNetworkPath) {
      self.path = path
      monitor = NWPathMonitor(requiredInterfaceType: path == .wifi ? .wifi : .cellular)
    }
  }

  private let queue = DispatchQueue(label: "voipcloud.calling-network")
  private let hooks: Hooks
  private let binder: CallingNetworkBinder
  private let store: CallingNetworkStore
  private let wifi = Slot(path: .wifi)
  private let cellular = Slot(path: .cellular)
  private var vpnMonitor = NWPathMonitor()
  private let queueKey = DispatchSpecificKey<Bool>()

  private var enabled: Bool
  private var preference: CallingNetworkPreference
  private var started = false
  private var vpnActive = false
  private var reason: CallingNetworkReason = .disabled
  private var lastSwitch: Date?
  private var pending = false

  // The route actually applied.
  private var boundInterface: NWInterface?
  private var boundPath: CallingNetworkPath?
  private var bindingGeneration = 0
  private var transitioning = false
  private var reconnectItem: DispatchWorkItem?

  // Network-loss handling.
  private var cleanupPending = false
  private var settleUntil: Date?
  private var lossWait: (path: CallingNetworkPath, since: Date, sawDown: Bool)?
  private var timer: DispatchSourceTimer?

  init(
    hooks: Hooks,
    binder: CallingNetworkBinder = UnsupportedCallingNetworkBinder(),
    store: CallingNetworkStore = CallingNetworkStore()
  ) {
    self.hooks = hooks
    self.binder = binder
    self.store = store
    enabled = store.enabled
    preference = store.preference
    queue.setSpecific(key: queueKey, value: true)
  }

  /// Safe from any thread, including a hook that runs on the manager's own queue
  /// (a plain queue.sync there would deadlock).
  private func onQueue<T>(_ body: () -> T) -> T {
    DispatchQueue.getSpecific(key: queueKey) == true ? body() : queue.sync(execute: body)
  }

  // MARK: - Lifecycle

  /// Call early, including on a PushKit cold start, before SIP registration.
  func start() {
    queue.async {
      guard !self.started else { return }
      self.started = true
      self.configureMonitors()
      self.vpnMonitor = NWPathMonitor()
      self.vpnMonitor.pathUpdateHandler = { [weak self] path in
        self?.queue.async {
          // A VPN shows up as an "other" interface type on the active path.
          self?.vpnActive = path.usesInterfaceType(.other)
          self?.evaluate("vpn")
        }
      }
      self.vpnMonitor.start(queue: self.queue)
      self.startTimer()
      self.evaluate("start")
    }
  }

  func stop() {
    queue.async {
      self.started = false
      self.timer?.cancel()
      self.timer = nil
      for slot in [self.wifi, self.cellular] { slot.monitor.cancel() }
      self.vpnMonitor.cancel()
      _ = self.binder.bind(to: nil)
      self.boundInterface = nil
      self.boundPath = nil
      self.transitioning = false
      self.cleanupPending = false
      self.lossWait = nil
      self.cancelReconnect()
    }
  }

  /// Mirrors the Flutter setting; also persisted for cold starts.
  func configure(enabled: Bool, preference: CallingNetworkPreference) {
    store.enabled = enabled
    store.preference = preference
    queue.async {
      let changed = self.enabled != enabled || self.preference != preference
      self.enabled = enabled
      self.preference = preference
      if self.started && changed { self.evaluate("configure") }
      self.hooks.onStatusChanged()
    }
  }

  /// Call whenever the set of live calls changes.
  func liveCallsChanged() {
    queue.async { if self.started { self.evaluate("calls_changed") } }
  }

  /// True while a route change is settling; new outgoing calls should wait.
  func isTransitioning() -> Bool { onQueue { transitioning } }

  func status() -> [String: Any] {
    onQueue {
      [
        "enabled": enabled && binder.isSupported,
        "requested": preference.rawValue,
        "effective": boundPath?.rawValue ?? "system",
        "reason": (binder.isSupported ? reason : .unsupported).rawValue,
        "pending": pending,
        "liveCall": hooks.hasLiveCall(),
        "transitioning": transitioning,
        "wifiAvailable": wifi.satisfied,
        "cellularAvailable": cellular.satisfied,
        "wifiValidated": wifi.validated,
        "cellularValidated": cellular.validated,
        "vpnActive": vpnActive,
      ]
    }
  }

  // MARK: - Path tracking

  private func slot(_ path: CallingNetworkPath) -> Slot { path == .wifi ? wifi : cellular }

  private func configureMonitors() {
    for item in [wifi, cellular] {
      item.monitor = NWPathMonitor(requiredInterfaceType: item.path == .wifi ? .wifi : .cellular)
      item.monitor.pathUpdateHandler = { [weak self] path in
        self?.queue.async { self?.pathChanged(item, path) }
      }
      item.monitor.start(queue: queue)
    }
  }

  private func pathChanged(_ item: Slot, _ path: NWPath) {
    let satisfied = path.status == .satisfied
    let wantedType: NWInterface.InterfaceType = item.path == .wifi ? .wifi : .cellular
    let interface = path.availableInterfaces.first { $0.type == wantedType }
    let wasBound = boundInterface != nil && boundPath == item.path
    // iOS reports many harmless updates (cost flags, addresses). Only a real
    // change of the interface or of availability restarts validation.
    let changed = satisfied != item.satisfied || interface?.index != item.interface?.index
    item.satisfied = satisfied
    item.interface = satisfied ? interface : nil
    if changed {
      item.generation += 1
      item.validated = false
      item.healthySince = nil
      item.consecutiveFailures = 0
      item.firstFailure = nil
      if satisfied && !hooks.hasLiveCall() { validate(item) }
    }
    // shortcut: roaming between Wi-Fi access points keeps the same interface and
    // is not seen as a loss; check on a device, then compare the SSID/gateway.
    // Only the exact bound interface going away counts; any other path's
    // change never touches a call.
    if !satisfied && wasBound {
      onBoundNetworkLost(item.path)
    } else {
      evaluate("path_changed")
    }
    hooks.onStatusChanged()
  }

  // MARK: - Loss of the bound network

  private func onBoundNetworkLost(_ path: CallingNetworkPath) {
    NSLog("CallingNetwork bound %@ lost (generation %d)", path.rawValue, bindingGeneration)
    transitioning = false
    // Release the binding first so a hang-up can still leave over whatever the
    // system now offers.
    _ = binder.bind(to: nil)
    cancelReconnect()
    boundInterface = nil
    boundPath = nil
    bindingGeneration += 1
    settleUntil = nil
    if hooks.hasLiveCall() {
      cleanupPending = true
      lossWait = (path, Date(), false)
      // The SDK's connections were created pinned to the lost network and only die on a timeout. When
      // the other network stayed up (Wi-Fi never changed) the system reports no change at all, so the
      // SDK never reconnects by itself and the hang-up (BYE) would leave over a dead socket. Cycle the
      // SDK now: it opens new connections over the system route, registration goes down and up (which
      // the loss wait watches for), and then the calls end.
      hooks.setSdkOffline(true)
      let item = DispatchWorkItem { [weak self] in
        guard let self else { return }
        self.reconnectItem = nil
        self.hooks.setSdkOffline(false)
      }
      reconnectItem = item
      queue.asyncAfter(deadline: .now() + Self.reconnectGap, execute: item)
      scheduleLossCheck()
    }
    evaluate("path_lost")
  }

  /// A cancelled reconnect task never turns the SDK back on, so do it here.
  private func cancelReconnect() {
    guard let item = reconnectItem else { return }
    item.cancel()
    reconnectItem = nil
    hooks.setSdkOffline(false)
  }

  /// Checked every 0.3 s, not on the 5 s timer, so the hang-up is not late and
  /// the short "SDK down, then up" window is seen.
  private func scheduleLossCheck() {
    queue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
      guard let self, self.started, self.lossWait != nil else { return }
      self.checkLossWait()
      if self.lossWait != nil { self.scheduleLossCheck() }
    }
  }

  /// Holds the hang-up back, for at most `lossWaitLimit`, until the SDK has a
  /// working connection again, then ends every live call.
  private func checkLossWait() {
    guard let wait = lossWait else { return }
    let registered = hooks.isRegistered()
    let sawDown = wait.sawDown || !registered
    lossWait = (wait.path, wait.since, sawDown)
    let elapsed = Date().timeIntervalSince(wait.since)
    if CallingNetworkPolicy.shouldEndCallsAfterLoss(
      elapsed: elapsed, sawDown: sawDown, registered: registered)
    {
      lossWait = nil
      NSLog("CallingNetwork ending calls (reconnected=%d, waited %.1fs)", registered ? 1 : 0, elapsed)
      hooks.endCalls(wait.path, "calling_network_lost:\(wait.path.rawValue)")
    }
  }

  // MARK: - Validation

  /// Three bounded probes through the path; two successes validate it. This
  /// proves transport reachability only, not that SIP registration or audio
  /// would work.
  private func validate(_ item: Slot) {
    guard !item.probing, let target = hooks.endpoint(), item.interface != nil else { return }
    item.probing = true
    item.lastProbe = Date()
    let generation = item.generation
    var successes = 0
    var attempts = 0

    func next() {
      if attempts >= 3 || successes >= 2 || attempts - successes >= 2 {
        // Probe completions already run on `queue`.
        let ok = successes >= 2
        item.probing = false
        guard item.generation == generation else { return }
        if ok {
          item.consecutiveFailures = 0
          item.firstFailure = nil
          if !item.validated { item.healthySince = Date() }
          item.validated = true
        } else {
          noteFailure(item)
        }
        evaluate("validated")
        return
      }
      attempts += 1
      probeOnce(item.path, host: target.host, port: target.port) { success in
        if success { successes += 1 }
        next()
      }
    }
    next()
  }

  private func noteFailure(_ item: Slot) {
    let now = Date()
    item.consecutiveFailures += 1
    if item.firstFailure == nil { item.firstFailure = now }
    // Three failures over at least ten seconds: persistent. Affects route
    // selection only; it never ends a call.
    if item.consecutiveFailures >= 3,
      now.timeIntervalSince(item.firstFailure ?? now) >= 10
    {
      item.validated = false
      item.healthySince = nil
    }
  }

  private func probeOnce(
    _ path: CallingNetworkPath,
    host: String,
    port: UInt16,
    completion: @escaping (Bool) -> Void
  ) {
    let parameters = NWParameters.tcp
    parameters.requiredInterfaceType = path == .wifi ? .wifi : .cellular
    guard let nwPort = NWEndpoint.Port(rawValue: port) else {
      completion(false)
      return
    }
    let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)
    var finished = false
    func finish(_ ok: Bool) {
      guard !finished else { return }
      finished = true
      connection.cancel()
      completion(ok)
    }
    connection.stateUpdateHandler = { state in
      switch state {
      case .ready: finish(true)
      case .failed, .cancelled: finish(false)
      default: break
      }
    }
    connection.start(queue: queue)
    queue.asyncAfter(deadline: .now() + Self.probeTimeout) { finish(false) }
  }

  private func startTimer() {
    let source = DispatchSource.makeTimerSource(queue: queue)
    source.schedule(deadline: .now() + Self.periodicCheck, repeating: Self.periodicCheck)
    source.setEventHandler { [weak self] in
      guard let self, self.started else { return }
      if self.enabled && self.preference != .auto {
        for item in [self.wifi, self.cellular] {
          // Probes are skipped during calls so media is not disturbed, and spaced
          // out so an idle phone does not keep the radio and server busy.
          let gap = item.validated ? Self.healthyReprobe : Self.failedReprobe
          if item.satisfied && (!item.validated || self.boundPath == item.path)
            && !self.hooks.hasLiveCall() && Date().timeIntervalSince(item.lastProbe) >= gap
          {
            self.validate(item)
          }
        }
        self.evaluate("periodic")
      }
    }
    source.resume()
    timer = source
  }

  // MARK: - Selection and application

  private func candidate(_ item: Slot) -> CallingNetworkCandidate {
    .init(available: item.satisfied, validated: item.validated)
  }

  private func evaluate(_ why: String) {
    let live = hooks.hasLiveCall()
    var settling = false
    if cleanupPending && !live && lossWait == nil {
      let now = Date()
      let until = settleUntil ?? now.addingTimeInterval(Self.cleanupSettle)
      settleUntil = until
      if now < until {
        settling = true
        queue.asyncAfter(deadline: .now() + until.timeIntervalSince(now) + 0.05) { [weak self] in
          if self?.started == true { self?.evaluate("cleanup_settled") }
        }
      } else {
        cleanupPending = false
        settleUntil = nil
      }
    }
    // A build without socket binding behaves like Auto.
    let active = enabled && binder.isSupported
    let selection = CallingNetworkPolicy.select(
      enabled: active,
      preference: preference,
      wifi: candidate(wifi),
      cellular: candidate(cellular),
      vpnActive: vpnActive
    )
    let movingBack =
      selection.reason == .preferred && boundPath != nil && boundPath != selection.path
    let electiveBlocked =
      movingBack
      && !CallingNetworkPolicy.mayMoveBackToPreferred(
        preferredHealthySince: selection.path.flatMap { slot($0).healthySince },
        lastSwitch: lastSwitch,
        now: Date()
      )
    let differs = selection.path != boundPath
    let allowed =
      CallingNetworkPolicy.mayApplyNow(liveCall: live)
      && !cleanupPending && !settling && !transitioning && !electiveBlocked
    pending = differs && !allowed
    reason = selection.reason
    if differs && allowed { applyRoute(selection.path) }
    NSLog(
      "CallingNetwork evaluated (%@): pref=%@ selected=%@/%@ bound=%@ pending=%d live=%d",
      why, preference.rawValue, selection.path?.rawValue ?? "system",
      selection.reason.rawValue, boundPath?.rawValue ?? "system", pending ? 1 : 0, live ? 1 : 0
    )
    hooks.onStatusChanged()
  }

  /// Idle route change: bind, then move the SDK's registration. Reports the
  /// route actually applied, not the intended one.
  private func applyRoute(_ path: CallingNetworkPath?) {
    let target = path.flatMap { slot($0).interface }
    if path != nil && target == nil { return }
    guard binder.bind(to: target) else {
      reason = .bindFailed
      return
    }
    bindingGeneration += 1
    boundInterface = target
    boundPath = path
    lastSwitch = Date()
    let generation = bindingGeneration
    transitioning = true
    hooks.setSdkOffline(true)
    let item = DispatchWorkItem { [weak self] in
      guard let self, generation == self.bindingGeneration else { return }
      self.reconnectItem = nil
      self.hooks.setSdkOffline(false)
      self.transitioning = false
      self.evaluate("route_settled")
    }
    reconnectItem = item
    queue.asyncAfter(deadline: .now() + Self.reconnectGap, execute: item)
  }

  // MARK: - Constants

  private static let probeTimeout: TimeInterval = 3
  private static let periodicCheck: TimeInterval = 5
  private static let healthyReprobe: TimeInterval = 60
  private static let failedReprobe: TimeInterval = 15
  private static let reconnectGap: TimeInterval = 0.3
  private static let cleanupSettle: TimeInterval = 1.5
}

/// Non-secret preference storage readable before Flutter starts (PushKit cold
/// start). UserDefaults is enough: nothing here is a credential.
final class CallingNetworkStore {
  private let defaults: UserDefaults
  init(defaults: UserDefaults = .standard) { self.defaults = defaults }

  var enabled: Bool {
    get { defaults.bool(forKey: "voipcloud.calling_network.enabled") }
    set { defaults.set(newValue, forKey: "voipcloud.calling_network.enabled") }
  }

  var preference: CallingNetworkPreference {
    get {
      CallingNetworkPreference(wire: defaults.string(forKey: "voipcloud.calling_network.preference"))
    }
    set { defaults.set(newValue.rawValue, forKey: "voipcloud.calling_network.preference") }
  }
}
