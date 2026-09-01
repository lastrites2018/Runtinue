import Foundation
import XCTest

@testable import RuntinueIPC

final class WireContractTests: XCTestCase {
  func testHelperDurationValidationRejectsNonFiniteAndOutOfRangeNumbersBeforeConversion() {
    for invalid in [Double.nan, .infinity, -.infinity, 0, -1, 91, 1e300] {
      XCTAssertNil(RuntinueIPCContract.validatedDuration(seconds: invalid, maximumSeconds: 90))
    }
    XCTAssertEqual(RuntinueIPCContract.validatedDuration(seconds: 0.5, maximumSeconds: 90), .milliseconds(500))
    XCTAssertEqual(RuntinueIPCContract.validatedDuration(seconds: 90, maximumSeconds: 90), .seconds(90))
    XCTAssertEqual(RuntinueIPCContract.validatedDuration(seconds: 86_400, maximumSeconds: 86_400), .seconds(86_400))
    XCTAssertNil(RuntinueIPCContract.validatedDuration(seconds: 86_401, maximumSeconds: 86_400))
    XCTAssertNil(RuntinueIPCContract.validatedDuration(seconds: 1, maximumSeconds: .nan))
    XCTAssertNil(RuntinueIPCContract.validatedDuration(seconds: .leastNonzeroMagnitude, maximumSeconds: 90))
  }

  func testPreviousUptimeProtocolIsRejectedAndWireNamesDeclareContinuousTime() throws {
    XCTAssertEqual(RuntinueIPCContract.protocolVersion, 5)
    XCTAssertFalse(RuntinueIPCContract.acceptsRequest(protocolVersion: 4, byteCount: 100))
    let status = HelperStatusWire(
      phase: .active, leaseID: UUID(), ownerUID: 501, sleepOverride: .disabled,
      ttlDeadlineContinuousNanoseconds: 10, hardDeadlineContinuousNanoseconds: 20, detail: nil
    )
    let text = try XCTUnwrap(String(data: JSONEncoder().encode(status), encoding: .utf8))
    XCTAssertTrue(text.contains("ttlDeadlineContinuousNanoseconds"))
    XCTAssertTrue(text.contains("hardDeadlineContinuousNanoseconds"))
    XCTAssertFalse(text.contains("Uptime"))
  }

  func testObservationFieldsRoundTripAndLegacyStatusStillDecodes() throws {
    let legacy = SupervisorStatusWire(
      phase: .idle, sessionID: nil, verdict: .inactive, remainingSeconds: nil,
      batteryPercent: nil, thermalLevel: nil, lidState: nil, detail: nil, updatedAt: Date()
    )
    let oldData = try JSONEncoder().encode(legacy)
    XCTAssertNil(try JSONDecoder().decode(SupervisorStatusWire.self, from: oldData).observation)
    let observed = legacy.withObservation(
      WireObservationStatus(
        buildID: String(repeating: "a", count: 64), issues: [.eventsUnavailable]
      ))
    XCTAssertEqual(
      try JSONDecoder().decode(SupervisorStatusWire.self, from: JSONEncoder().encode(observed)),
      observed
    )
  }

  func testAcquireRequestRoundTripsWithoutOwnerUID() throws {
    let request = AcquireLeaseWireRequest(
      leaseID: UUID(),
      ttlSeconds: 90,
      hardCapSeconds: 5_400,
      reason: "commute"
    )

    let data = try JSONEncoder().encode(request)
    let decoded = try JSONDecoder().decode(AcquireLeaseWireRequest.self, from: data)

    XCTAssertEqual(decoded, request)
    XCTAssertLessThan(data.count, RuntinueIPCContract.maximumRequestBytes)
  }

  func testStatusResponseRoundTripsRecoveryState() throws {
    let response = HelperMutationWireResponse(
      outcome: .recoveryPending,
      status: HelperStatusWire(
        phase: .recoveryPending,
        leaseID: UUID(),
        ownerUID: 501,
        sleepOverride: .disabled,
        ttlDeadlineContinuousNanoseconds: 1_000,
        hardDeadlineContinuousNanoseconds: 2_000,
        detail: "retrying"
      ),
      rejection: nil
    )

    let data = try JSONEncoder().encode(response)
    let decoded = try JSONDecoder().decode(HelperMutationWireResponse.self, from: data)

    XCTAssertEqual(decoded, response)
  }

  func testSupervisorTripRequestRoundTripsWithinRequestLimit() throws {
    let request = StartTripWireRequest(
      expectedHotspotSSID: "Jaewan iPhone",
      hotspotHandoffTimeoutSeconds: 900,
      hardCapSeconds: 5_400,
      allowAlreadyConnected: true
    )

    let data = try JSONEncoder().encode(request)
    let decoded = try JSONDecoder().decode(StartTripWireRequest.self, from: data)

    XCTAssertEqual(decoded, request)
    XCTAssertTrue(decoded.allowAlreadyConnected)
    XCTAssertLessThan(data.count, RuntinueIPCContract.maximumRequestBytes)
  }

  func testUSBTetheringTripRequestRoundTripsWithoutSSID() throws {
    let request = StartTripWireRequest(
      networkTargetKind: .usbTethering,
      hotspotHandoffTimeoutSeconds: 900,
      hardCapSeconds: 5_400
    )

    let data = try JSONEncoder().encode(request)
    let decoded = try JSONDecoder().decode(StartTripWireRequest.self, from: data)

    XCTAssertEqual(decoded, request)
    XCTAssertNil(decoded.expectedHotspotSSID)
    XCTAssertFalse(decoded.allowAlreadyConnected)
  }

  func testWiFiObservationRoundTripsWithinRequestLimit() throws {
    let request = WiFiObservationWireRequest(
      ssid: "Jaewan iPhone",
      interfaceName: "en0"
    )

    let data = try JSONEncoder().encode(request)
    let decoded = try JSONDecoder().decode(
      WiFiObservationWireRequest.self,
      from: data
    )

    XCTAssertEqual(decoded, request)
    XCTAssertLessThan(data.count, RuntinueIPCContract.maximumRequestBytes)
  }

  func testSupervisorProtectedStatusRoundTrips() throws {
    let status = SupervisorStatusWire(
      phase: .active,
      sessionID: UUID(),
      verdict: .protected,
      remainingSeconds: 5_399,
      batteryPercent: 78,
      thermalLevel: "nominal",
      lidState: "closed",
      detail: nil,
      updatedAt: Date(timeIntervalSince1970: 1_000)
    )
    let response = SupervisorCommandWireResponse(
      outcome: .success,
      status: status,
      error: nil
    )

    let data = try JSONEncoder().encode(response)
    let decoded = try JSONDecoder().decode(SupervisorCommandWireResponse.self, from: data)

    XCTAssertEqual(decoded, response)
  }

  func testSupervisorStopReasonRoundTrips() throws {
    let status = SupervisorStatusWire(
      phase: .releasingLease,
      mode: .trip,
      sessionID: UUID(),
      verdict: .releasing,
      closedLidAllowed: false,
      remainingSeconds: nil,
      batteryPercent: 42,
      thermalLevel: "fair",
      lidState: "closed",
      stopReason: .safety,
      detail: "thermal limit reached",
      updatedAt: Date(timeIntervalSince1970: 1_000)
    )

    let data = try JSONEncoder().encode(status)
    let decoded = try JSONDecoder().decode(SupervisorStatusWire.self, from: data)

    XCTAssertEqual(decoded, status)
    XCTAssertEqual(decoded.stopReason, .safety)
  }

  func testProtocolMismatchIsRejectedByRequestContract() throws {
    let request = StartTripWireRequest(
      protocolVersion: RuntinueIPCContract.protocolVersion + 1,
      expectedHotspotSSID: "iPhone",
      hotspotHandoffTimeoutSeconds: 900,
      hardCapSeconds: 5_400
    )

    let data = try JSONEncoder().encode(request)
    let decoded = try JSONDecoder().decode(
      StartTripWireRequest.self,
      from: data
    )

    XCTAssertFalse(
      RuntinueIPCContract.acceptsRequest(
        protocolVersion: decoded.protocolVersion,
        byteCount: data.count
      )
    )
  }

  func testRequestContractEnforcesByteBoundary() {
    XCTAssertTrue(
      RuntinueIPCContract.acceptsRequest(
        protocolVersion: RuntinueIPCContract.protocolVersion,
        byteCount: RuntinueIPCContract.maximumRequestBytes
      )
    )
    XCTAssertFalse(
      RuntinueIPCContract.acceptsRequest(
        protocolVersion: RuntinueIPCContract.protocolVersion,
        byteCount: RuntinueIPCContract.maximumRequestBytes + 1
      )
    )
    XCTAssertFalse(
      RuntinueIPCContract.acceptsRequest(
        protocolVersion: RuntinueIPCContract.protocolVersion,
        byteCount: -1
      )
    )
  }

  func testCommonRequestDecoderRejectsOversizedPayload() throws {
    let request = StartTripWireRequest(
      expectedHotspotSSID: "iPhone",
      hotspotHandoffTimeoutSeconds: 900,
      hardCapSeconds: 5_400
    )
    let validData = try JSONEncoder().encode(request)
    XCTAssertEqual(
      RuntinueIPCContract.decodeRequest(
        StartTripWireRequest.self,
        from: validData
      ),
      request
    )

    let oversized = Data(
      repeating: 0x20,
      count: RuntinueIPCContract.maximumRequestBytes + 1
    )
    XCTAssertNil(
      RuntinueIPCContract.decodeRequest(
        StartTripWireRequest.self,
        from: oversized
      )
    )
  }
}
