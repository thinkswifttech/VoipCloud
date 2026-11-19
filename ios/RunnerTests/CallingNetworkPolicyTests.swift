// DRAFT - written on Windows, never compiled or run. Add to the RunnerTests
// target together with CallingNetworkPolicy.swift. Mirrors CallingNetworkPolicyTest.kt.

import XCTest

@testable import Runner

final class CallingNetworkPolicyTests: XCTestCase {
  private let good = CallingNetworkCandidate(available: true, validated: true)
  private let unvalidated = CallingNetworkCandidate(available: true, validated: false)
  private let gone = CallingNetworkCandidate(available: false, validated: false)

  private func select(
    _ preference: CallingNetworkPreference,
    wifi: CallingNetworkCandidate,
    cellular: CallingNetworkCandidate,
    enabled: Bool = true,
    vpn: Bool = false
  ) -> CallingNetworkSelection {
    CallingNetworkPolicy.select(
      enabled: enabled, preference: preference, wifi: wifi, cellular: cellular, vpnActive: vpn)
  }

  func testParsesUnknownValuesAsAuto() {
    XCTAssertEqual(CallingNetworkPreference(wire: nil), .auto)
    XCTAssertEqual(CallingNetworkPreference(wire: "bogus"), .auto)
    XCTAssertEqual(CallingNetworkPreference(wire: " WiFi "), .wifi)
    XCTAssertEqual(CallingNetworkPreference(wire: "cellular"), .cellular)
  }

  func testDisabledAndAutoLeaveRoutingToTheSystem() {
    XCTAssertEqual(select(.cellular, wifi: good, cellular: good, enabled: false).reason, .disabled)
    XCTAssertNil(select(.cellular, wifi: good, cellular: good, enabled: false).path)
    let auto = select(.auto, wifi: good, cellular: good)
    XCTAssertNil(auto.path)
    XCTAssertEqual(auto.reason, .systemManaged)
  }

  func testKeepsAUsablePreferredPath() {
    XCTAssertEqual(select(.cellular, wifi: good, cellular: good).path, .cellular)
    XCTAssertEqual(select(.wifi, wifi: good, cellular: good).path, .wifi)
    XCTAssertEqual(select(.wifi, wifi: good, cellular: good).reason, .preferred)
  }

  func testFallsBackWhenThePreferredPathIsNotUsable() {
    let unavailable = select(.wifi, wifi: gone, cellular: good)
    XCTAssertEqual(unavailable.path, .cellular)
    XCTAssertEqual(unavailable.reason, .preferredUnavailable)
    XCTAssertEqual(select(.wifi, wifi: unvalidated, cellular: good).path, .cellular)
    XCTAssertEqual(select(.cellular, wifi: good, cellular: unvalidated).path, .wifi)
  }

  func testLeavesRoutingToTheSystemWhenNothingIsUsable() {
    let none = select(.cellular, wifi: unvalidated, cellular: unvalidated)
    XCTAssertNil(none.path)
    XCTAssertEqual(none.reason, .noUsablePath)
  }

  func testVpnKeepsTheSystemPath() {
    let vpn = select(.cellular, wifi: good, cellular: good, vpn: true)
    XCTAssertNil(vpn.path)
    XCTAssertEqual(vpn.reason, .vpnActive)
  }

  func testTheRouteNeverChangesWhileACallIsLive() {
    XCTAssertTrue(CallingNetworkPolicy.mayApplyNow(liveCall: false))
    XCTAssertFalse(CallingNetworkPolicy.mayApplyNow(liveCall: true))
  }

  func testEndsCallsAfterLossOnlyWhenReconnectedOrTimedOut() {
    let end = CallingNetworkPolicy.shouldEndCallsAfterLoss
    XCTAssertFalse(end(0.1, true, true))  // too early
    XCTAssertFalse(end(1.0, false, true))  // never saw the SDK go down
    XCTAssertFalse(end(1.0, true, false))  // still down
    XCTAssertTrue(end(0.3, true, true))
    XCTAssertTrue(end(3.0, false, false))  // wait ran out
  }

  func testMovesBackToThePreferredPathOnlyWhenStableAndCooledDown() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    func back(_ healthy: TimeInterval?, _ last: TimeInterval?) -> Bool {
      CallingNetworkPolicy.mayMoveBackToPreferred(
        preferredHealthySince: healthy.map { now.addingTimeInterval(-$0) },
        lastSwitch: last.map { now.addingTimeInterval(-$0) },
        now: now)
    }
    XCTAssertFalse(back(nil, nil))
    XCTAssertFalse(back(29, nil))
    XCTAssertTrue(back(30, nil))
    XCTAssertFalse(back(60, 20))
    XCTAssertTrue(back(120, 60))
  }
}
