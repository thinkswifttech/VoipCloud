// DRAFT - written on Windows, never compiled or run. Not part of the Xcode
// project yet (see README.md in this folder).
//
// Swift port of android/.../CallingNetworkPolicy.kt. Keep the two behaviourally
// identical: the same rules are exercised by the same cases in
// CallingNetworkPolicyTests.swift and CallingNetworkPolicyTest.kt.

import Foundation

enum CallingNetworkPreference: String {
  case auto
  case wifi
  case cellular

  init(wire: String?) {
    let value = wire?.trimmingCharacters(in: .whitespaces).lowercased()
    self = CallingNetworkPreference(rawValue: value ?? "") ?? .auto
  }
}

enum CallingNetworkPath: String {
  case wifi
  case cellular

  var other: CallingNetworkPath { self == .wifi ? .cellular : .wifi }
}

/// What is known about one physical path.
struct CallingNetworkCandidate: Equatable {
  var available: Bool
  /// True only after a connection to the SIP server succeeded on this path.
  var validated: Bool

  var usable: Bool { available && validated }
}

enum CallingNetworkReason: String {
  /// Auto, or nothing is constrained: the system chooses.
  case systemManaged = "system_managed"
  case preferred
  case preferredUnavailable = "preferred_unavailable"
  case noUsablePath = "no_usable_path"
  case vpnActive = "vpn_active"
  /// The SDK cannot bind sockets to an interface in this build (see the binder).
  case unsupported
  /// The binding was refused; the previous route is still in use.
  case bindFailed = "bind_failed"
  case disabled
}

struct CallingNetworkSelection: Equatable {
  /// Path to bind calling traffic to; nil leaves routing to the system.
  var path: CallingNetworkPath?
  var reason: CallingNetworkReason
}

enum CallingNetworkPolicy {
  /// Minimum time between elective (non-failure) switches.
  static let electiveSwitchCooldown: TimeInterval = 60
  /// A recovered preferred path must stay healthy this long before moving back.
  static let preferredStable: TimeInterval = 30

  /// Chooses the path for new traffic.
  ///
  /// - Disabled, Auto or an active VPN leave routing to the system.
  /// - A usable preferred path is kept.
  /// - An unusable preferred path falls back to the other usable path.
  /// - If neither is usable the system keeps control so registration can retry.
  static func select(
    enabled: Bool,
    preference: CallingNetworkPreference,
    wifi: CallingNetworkCandidate,
    cellular: CallingNetworkCandidate,
    vpnActive: Bool
  ) -> CallingNetworkSelection {
    if !enabled { return .init(path: nil, reason: .disabled) }
    if preference == .auto { return .init(path: nil, reason: .systemManaged) }
    if vpnActive { return .init(path: nil, reason: .vpnActive) }
    let preferred: CallingNetworkPath = preference == .wifi ? .wifi : .cellular
    func candidate(_ path: CallingNetworkPath) -> CallingNetworkCandidate {
      path == .wifi ? wifi : cellular
    }
    if candidate(preferred).usable { return .init(path: preferred, reason: .preferred) }
    if candidate(preferred.other).usable {
      return .init(path: preferred.other, reason: .preferredUnavailable)
    }
    return .init(path: nil, reason: .noUsablePath)
  }

  /// The route never changes while a call is live: a call keeps the network it
  /// started on, and losing that network ends the call (see the manager).
  static func mayApplyNow(liveCall: Bool) -> Bool { !liveCall }

  /// Longest the hang-up is held back waiting for a working connection.
  static let lossWaitLimit: TimeInterval = 3

  /// After the bound network is lost: end the calls once the SDK has gone down
  /// and come back (so the BYE can leave), or when the wait runs out.
  static func shouldEndCallsAfterLoss(
    elapsed: TimeInterval, sawDown: Bool, registered: Bool
  ) -> Bool {
    (sawDown && registered && elapsed >= 0.3) || elapsed >= lossWaitLimit
  }

  static func mayMoveBackToPreferred(
    preferredHealthySince: Date?,
    lastSwitch: Date?,
    now: Date
  ) -> Bool {
    guard let healthySince = preferredHealthySince else { return false }
    if now.timeIntervalSince(healthySince) < preferredStable { return false }
    guard let last = lastSwitch else { return true }
    return now.timeIntervalSince(last) >= electiveSwitchCooldown
  }
}
