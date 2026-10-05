import Flutter
import UIKit
import XCTest
@testable import Runner

class RunnerTests: XCTestCase {

  func testWaitingToneIsValidPCMWithBoundedSoftBeep() {
    let wave = IOSCallKitTonePolicy.waitingToneWave()
    XCTAssertEqual(wave.count, 44 + 16_000)
    XCTAssertEqual(String(data: wave.prefix(4), encoding: .ascii), "RIFF")
    XCTAssertEqual(String(data: wave.subdata(in: 8..<16), encoding: .ascii), "WAVEfmt ")
    XCTAssertEqual(String(data: wave.subdata(in: 36..<40), encoding: .ascii), "data")
    XCTAssertEqual(Array(wave[20..<24]), [1, 0, 1, 0]) // PCM, mono.
    XCTAssertEqual(Array(wave[24..<28]), [64, 31, 0, 0]) // 8000 Hz.
    XCTAssertEqual(Array(wave[32..<36]), [2, 0, 16, 0]) // 16-bit alignment.
    let samples = stride(from: 44, to: wave.count, by: 2).map { offset in
      Int(Int16(bitPattern: UInt16(wave[offset]) | (UInt16(wave[offset + 1]) << 8)))
    }
    XCTAssertLessThanOrEqual(samples.map { abs($0) }.max() ?? 0, 786)
    XCTAssertTrue(samples[0..<3_200].contains { $0 != 0 })
    XCTAssertTrue(samples[3_200..<8_000].allSatisfy { $0 == 0 })
    // Soft edges must be substantially quieter than the sustained tone.
    XCTAssertLessThan(samples[0..<40].map { abs($0) }.max() ?? 0, 200)
    XCTAssertLessThan(samples[3_160..<3_200].map { abs($0) }.max() ?? 0, 200)
    XCTAssertEqual(samples[0], 0)
    XCTAssertEqual(samples[3_200], 0)
  }

  func testWaitingToneAssetIsReusableAndRepairsCorruption() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("waiting-tone-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = try IOSCallKitTonePolicy.prepareWaitingTone(in: directory)
    XCTAssertEqual(try Data(contentsOf: first), IOSCallKitTonePolicy.waitingToneWave())
    XCTAssertEqual(try IOSCallKitTonePolicy.prepareWaitingTone(in: directory), first)
    try Data("corrupt".utf8).write(to: first)
    let repaired = try IOSCallKitTonePolicy.prepareWaitingTone(in: directory)
    XCTAssertEqual(try Data(contentsOf: repaired), IOSCallKitTonePolicy.waitingToneWave())
  }

  func testWaitingToneVolumeIsClampedAndZeroIsSilent() {
    let muted = IOSCallKitTonePolicy.waitingToneWave(level: 0)
    XCTAssertTrue(muted.dropFirst(44).allSatisfy { $0 == 0 })
    XCTAssertEqual(muted, IOSCallKitTonePolicy.waitingToneWave(level: -1))
    let loudest = IOSCallKitTonePolicy.waitingToneWave(level: 100)
    XCTAssertEqual(loudest, IOSCallKitTonePolicy.waitingToneWave(level: 200))
    let samples = stride(from: 44, to: loudest.count, by: 2).map { offset in
      abs(Int(Int16(bitPattern: UInt16(loudest[offset]) | (UInt16(loudest[offset + 1]) << 8))))
    }
    XCTAssertLessThanOrEqual(samples.max() ?? 0, 2_621)
    XCTAssertGreaterThan(samples.max() ?? 0, 786)
  }

  func testWaitingAlertRepeatsOnlyDuringAnExistingConversation() {
    XCTAssertEqual(IOSCallKitTonePolicy.repeatInterval, 5)
    XCTAssertTrue(IOSCallKitTonePolicy.shouldRepeat(hasWaiting: true, hasConversation: true))
    XCTAssertFalse(IOSCallKitTonePolicy.shouldRepeat(hasWaiting: false, hasConversation: true))
    XCTAssertFalse(IOSCallKitTonePolicy.shouldRepeat(hasWaiting: true, hasConversation: false))
    XCTAssertFalse(IOSCallKitTonePolicy.shouldRepeat(hasWaiting: false, hasConversation: false))
  }

  func testWaitingToneStorageFailureDoesNotSelectAnAudibleFallback() throws {
    let file = FileManager.default.temporaryDirectory
      .appendingPathComponent("waiting-tone-failure-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: file) }
    try Data("not a directory".utf8).write(to: file)
    XCTAssertThrowsError(try IOSCallKitTonePolicy.prepareWaitingTone(in: file))
  }

  func testToneDiagnosticsCaptureStartAndStopWithoutSDKPayload() {
    XCTAssertEqual(
      IOSToneDiagnostic.event(from: "[210] [ToneManager] startNamedTone"),
      "sdk_tone_action=startNamedTone"
    )
    XCTAssertEqual(
      IOSToneDiagnostic.event(from: "[ToneManager] playFile /private/secret.wav sip:user@example.com"),
      "sdk_tone_action=playFile"
    )
    XCTAssertEqual(IOSToneDiagnostic.event(from: "[ToneManager] stopTone"), "sdk_tone_action=stopTone")
  }

  func testToneDiagnosticsDiscardUnrelatedAndAppleLogs() {
    XCTAssertNil(IOSToneDiagnostic.event(from: "Authorization: Digest password=secret"))
    XCTAssertNil(IOSToneDiagnostic.event(from: "<TLToneManager>: currentToneIdentifierForAlertType"))
    XCTAssertNil(IOSToneDiagnostic.event(from: "INVITE sip:210@example.com"))
  }

  func testUnknownToneActionCannotLeakPayload() {
    XCTAssertEqual(
      IOSToneDiagnostic.event(from: "[ToneManager] secret-token secret-address"),
      "sdk_tone_action=other"
    )
  }

  func testGainFailuresAreIncludedWithoutCallerIdentity() {
    XCTAssertEqual(
      IOSToneDiagnostic.event(from: "[210] Could not apply playback gain: gain control wasn't activated."),
      "sdk_playback_gain_unavailable"
    )
    XCTAssertEqual(
      IOSToneDiagnostic.event(from: "Could not apply gain on sent RTP packets: gain control wasn't activated."),
      "sdk_microphone_gain_unavailable"
    )
  }

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
