import Foundation
import XCTest

@testable import SafeClamIPC

final class WireContractTests: XCTestCase {
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
    XCTAssertLessThan(data.count, SafeClamIPCContract.maximumRequestBytes)
  }

  func testStatusResponseRoundTripsRecoveryState() throws {
    let response = HelperMutationWireResponse(
      outcome: .recoveryPending,
      status: HelperStatusWire(
        phase: .recoveryPending,
        leaseID: UUID(),
        ownerUID: 501,
        sleepOverride: .disabled,
        ttlDeadlineUptimeNanoseconds: 1_000,
        hardDeadlineUptimeNanoseconds: 2_000,
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
      hardCapSeconds: 5_400
    )

    let data = try JSONEncoder().encode(request)
    let decoded = try JSONDecoder().decode(StartTripWireRequest.self, from: data)

    XCTAssertEqual(decoded, request)
    XCTAssertLessThan(data.count, SafeClamIPCContract.maximumRequestBytes)
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
    XCTAssertLessThan(data.count, SafeClamIPCContract.maximumRequestBytes)
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
      protocolVersion: SafeClamIPCContract.protocolVersion + 1,
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
      SafeClamIPCContract.acceptsRequest(
        protocolVersion: decoded.protocolVersion,
        byteCount: data.count
      )
    )
  }

  func testRequestContractEnforcesByteBoundary() {
    XCTAssertTrue(
      SafeClamIPCContract.acceptsRequest(
        protocolVersion: SafeClamIPCContract.protocolVersion,
        byteCount: SafeClamIPCContract.maximumRequestBytes
      )
    )
    XCTAssertFalse(
      SafeClamIPCContract.acceptsRequest(
        protocolVersion: SafeClamIPCContract.protocolVersion,
        byteCount: SafeClamIPCContract.maximumRequestBytes + 1
      )
    )
    XCTAssertFalse(
      SafeClamIPCContract.acceptsRequest(
        protocolVersion: SafeClamIPCContract.protocolVersion,
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
      SafeClamIPCContract.decodeRequest(
        StartTripWireRequest.self,
        from: validData
      ),
      request
    )

    let oversized = Data(
      repeating: 0x20,
      count: SafeClamIPCContract.maximumRequestBytes + 1
    )
    XCTAssertNil(
      SafeClamIPCContract.decodeRequest(
        StartTripWireRequest.self,
        from: oversized
      )
    )
  }
}
