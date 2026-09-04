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

}
