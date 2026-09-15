import Flutter
import UIKit
import XCTest
@testable import Runner

class RunnerTests: XCTestCase {

  func testExternalCallDestinationFromOpaqueURL() throws {
    let url = try XCTUnwrap(URL(string: "tel:%2B14165550100"))

    XCTAssertEqual(
      ExternalCommunicationIntentBridge.validatedDestination(from: url),
      "+14165550100"
    )
  }

  func testExternalCallDestinationFromHierarchicalURL() throws {
    let url = try XCTUnwrap(URL(string: "tel://4165550100"))

    XCTAssertEqual(
      ExternalCommunicationIntentBridge.validatedDestination(from: url),
      "4165550100"
    )
  }

  func testExternalMessageDestinationFromHierarchicalURL() throws {
    let url = try XCTUnwrap(URL(string: "im://4165550100"))

    XCTAssertEqual(
      ExternalCommunicationIntentBridge.validatedDestination(from: url),
      "4165550100"
    )
  }

  func testUnsafeExternalDestinationIsRejected() throws {
    let url = try XCTUnwrap(URL(string: "tel://4165550100@example.com"))

    XCTAssertNil(
      ExternalCommunicationIntentBridge.validatedDestination(from: url)
    )
  }

  func testExternalCallDestinationFromSystemHandle() {
    XCTAssertEqual(
      ExternalCommunicationIntentBridge.validatedDestination(
        fromSystemHandle: "+1 (416) 555-0100"
      ),
      "+1 (416) 555-0100"
    )
  }

  func testExternalCallDestinationFromEncodedSystemHandle() {
    XCTAssertEqual(
      ExternalCommunicationIntentBridge.validatedDestination(
        fromSystemHandle: "tel:%2B14165550100"
      ),
      "+14165550100"
    )
  }

  func testUnsafeExternalSystemHandleIsRejected() {
    XCTAssertNil(
      ExternalCommunicationIntentBridge.validatedDestination(
        fromSystemHandle: "4165550100@example.com"
      )
    )
  }

  func testExternalCallDestinationFromActivityUserInfo() {
    let activity = NSUserActivity(activityType: "com.apple.callkit.start-call")
    activity.addUserInfoEntries(from: [
      "startCallHandle": "tel:%2B14165550100",
    ])

    XCTAssertEqual(
      ExternalCommunicationIntentBridge.startCallHandle(from: activity),
      "tel:%2B14165550100"
    )
  }

  func testExternalCallDestinationFromTargetContentIdentifier() {
    let activity = NSUserActivity(activityType: "com.apple.callkit.start-call")
    activity.targetContentIdentifier = "+1 (416) 555-0100"

    XCTAssertEqual(
      ExternalCommunicationIntentBridge.startCallHandle(from: activity),
      "+1 (416) 555-0100"
    )
  }

}
