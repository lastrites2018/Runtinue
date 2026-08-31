import XCTest

@testable import RuntinueCore

final class CommuteTripEngineTests: XCTestCase {
  func testHotspotHandoffAcquiresThenThermalTripReleases() throws {
    var engine = CommuteTripEngine()
    let sessionID = UUID()
    let lease = LeaseToken()
    let start = instant(seconds: 100)
    let request = CommuteTripRequest(expectedHotspotSSID: "Jaewan iPhone")

    try engine.arm(
      request,
      originNetwork: network(ssid: "Office", at: start),
      device: device(at: start),
      at: start,
      sessionID: sessionID
    )

    let acquire = engine.observeNetwork(
      network(ssid: "Jaewan iPhone", at: instant(seconds: 110)),
      at: instant(seconds: 110)
    )
    XCTAssertEqual(acquire, [.acquire(sessionID: sessionID, hardCap: request.hardCap)])
    XCTAssertEqual(engine.phase, .acquiringLease)

    XCTAssertTrue(
      engine.completeAcquisition(
        sessionID: sessionID,
        outcome: .acquired(lease),
        at: instant(seconds: 111)
      ).isEmpty
    )
    XCTAssertEqual(engine.phase, .active)

    let release = engine.observeDevice(
      device(
        at: instant(seconds: 120),
        thermal: .fair,
        lid: .closed
      ),
      at: instant(seconds: 120)
    )
    let expectedReason = TripStopReason.safety(
      .thermalLimitReached(observed: .fair, cutoff: .fair)
    )
    XCTAssertEqual(
      release,
      [.release(sessionID: sessionID, lease: lease, reason: expectedReason)]
    )
    XCTAssertEqual(engine.phase, .releasingLease)

    _ = engine.completeRelease(
      sessionID: sessionID,
      lease: lease,
      outcome: .released
    )
    XCTAssertEqual(engine.phase, .ended)
    XCTAssertEqual(engine.status.stopReason, expectedReason)
  }

  func testNetworkLossDoesNotReleaseAnActiveTrip() throws {
    var fixture = try activeFixture()

    let commands = fixture.engine.observeNetwork(
      network(
        ssid: nil,
        at: instant(seconds: 120),
        reachable: false
      ),
      at: instant(seconds: 120)
    )

    XCTAssertTrue(commands.isEmpty)
    XCTAssertEqual(fixture.engine.phase, .active)
  }

  func testUSBTetheringHandoffCanAcquireLease() throws {
    var engine = CommuteTripEngine()
    let sessionID = UUID()
    let start = instant(seconds: 100)
    let request = CommuteTripRequest(networkTarget: .usbTethering)
    try engine.arm(
      request,
      originNetwork: network(
        ssid: "Office",
        at: start,
        interface: "en0",
        gateway: "192.168.1.1"
      ),
      device: device(at: start),
      at: start,
      sessionID: sessionID
    )

    let commands = engine.observeNetwork(
      network(
        ssid: nil,
        at: instant(seconds: 110),
        interface: "en5",
        gateway: "172.20.10.1"
      ),
      at: instant(seconds: 110)
    )

    XCTAssertEqual(
      commands,
      [.acquire(sessionID: sessionID, hardCap: request.hardCap)]
    )
  }

  func testHardDeadlineReleasesEvenWithHealthyDevice() throws {
    var fixture = try activeFixture(hardCap: .seconds(60))

    let commands = fixture.engine.tick(at: instant(seconds: 171))

    XCTAssertEqual(
      commands,
      [
        .release(
          sessionID: fixture.sessionID,
          lease: fixture.lease,
          reason: .hardDeadlineReached
        )
      ]
    )
  }

  func testStopDuringAcquireReleasesLateSuccessfulLease() throws {
    var engine = CommuteTripEngine()
    let sessionID = UUID()
    let lease = LeaseToken()
    let start = instant(seconds: 100)
    let request = CommuteTripRequest(expectedHotspotSSID: "Jaewan iPhone")
    try engine.arm(
      request,
      originNetwork: network(ssid: "Office", at: start),
      device: device(at: start),
      at: start,
      sessionID: sessionID
    )
    _ = engine.observeNetwork(
      network(ssid: "Jaewan iPhone", at: instant(seconds: 110)),
      at: instant(seconds: 110)
    )

    XCTAssertTrue(engine.stop().isEmpty)
    XCTAssertEqual(engine.phase, .releasingLease)
    XCTAssertEqual(
      engine.completeAcquisition(
        sessionID: sessionID,
        outcome: .acquired(lease),
        at: instant(seconds: 111)
      ),
      [.release(sessionID: sessionID, lease: lease, reason: .userRequested)]
    )
  }

  func testStaleSafetySnapshotBlocksAcquisition() throws {
    var engine = CommuteTripEngine()
    let start = instant(seconds: 100)
    try engine.arm(
      CommuteTripRequest(expectedHotspotSSID: "Jaewan iPhone"),
      originNetwork: network(ssid: "Office", at: start),
      device: device(at: start),
      at: start
    )

    XCTAssertTrue(
      engine.observeNetwork(
        network(ssid: "Jaewan iPhone", at: instant(seconds: 161)),
        at: instant(seconds: 161)
      ).isEmpty
    )
    XCTAssertEqual(engine.phase, .ended)
    XCTAssertEqual(
      engine.status.stopReason,
      .safety(.staleSnapshot(age: .seconds(61)))
    )
  }

  func testHandoffTimeoutEndsWithoutLease() throws {
    var engine = CommuteTripEngine()
    let start = instant(seconds: 100)
    try engine.arm(
      CommuteTripRequest(
        expectedHotspotSSID: "Jaewan iPhone",
        hotspotHandoffTimeout: .seconds(30)
      ),
      originNetwork: network(ssid: "Office", at: start),
      device: device(at: start),
      at: start
    )

    XCTAssertTrue(engine.tick(at: instant(seconds: 130)).isEmpty)
    XCTAssertEqual(engine.phase, .ended)
    XCTAssertEqual(engine.status.stopReason, .hotspotHandoffTimedOut)
  }

  func testHardCapOverTwentyFourHoursIsRejected() {
    var engine = CommuteTripEngine()
    let start = instant(seconds: 100)

    XCTAssertThrowsError(
      try engine.arm(
        CommuteTripRequest(
          expectedHotspotSSID: "Jaewan iPhone",
          hardCap: .seconds(24 * 60 * 60 + 1)
        ),
        originNetwork: network(ssid: "Office", at: start),
        device: device(at: start),
        at: start
      )
    ) { error in
      XCTAssertEqual(error as? CommuteTripError, .hardCapExceedsMaximum)
    }
  }

  func testHotspotSSIDOverThirtyTwoBytesIsRejected() {
    var engine = CommuteTripEngine()
    let start = instant(seconds: 100)

    XCTAssertThrowsError(
      try engine.arm(
        CommuteTripRequest(
          expectedHotspotSSID: String(repeating: "a", count: 33)
        ),
        originNetwork: network(ssid: "Office", at: start),
        device: device(at: start),
        at: start
      )
    ) { error in
      XCTAssertEqual(error as? CommuteTripError, .hotspotSSIDTooLong)
    }
  }

  private func activeFixture(
    hardCap: Duration = .seconds(90 * 60)
  ) throws -> (engine: CommuteTripEngine, sessionID: UUID, lease: LeaseToken) {
    var engine = CommuteTripEngine()
    let sessionID = UUID()
    let lease = LeaseToken()
    let start = instant(seconds: 100)
    try engine.arm(
      CommuteTripRequest(
        expectedHotspotSSID: "Jaewan iPhone",
        hardCap: hardCap
      ),
      originNetwork: network(ssid: "Office", at: start),
      device: device(at: start),
      at: start,
      sessionID: sessionID
    )
    _ = engine.observeNetwork(
      network(ssid: "Jaewan iPhone", at: instant(seconds: 110)),
      at: instant(seconds: 110)
    )
    _ = engine.completeAcquisition(
      sessionID: sessionID,
      outcome: .acquired(lease),
      at: instant(seconds: 111)
    )
    return (engine, sessionID, lease)
  }
}
