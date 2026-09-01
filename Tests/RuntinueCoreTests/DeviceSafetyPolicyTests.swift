import XCTest

@testable import RuntinueCore

final class DeviceSafetyPolicyTests: XCTestCase {
  private let policy = DeviceSafetyPolicy()

  func testNonChargingAndUnknownPowerUseTheNormalBatteryFloors() {
    let now = instant(seconds: 100)
    for power in [PowerConnection.acNotCharging, .battery, .unknown] {
      XCTAssertEqual(
        policy.evaluate(device(at: now, battery: 29, power: power, lid: .closed), at: now),
        .stop(.batteryBelowFloor(observed: 29, floor: 30))
      )
      XCTAssertEqual(
        policy.evaluate(device(at: now, battery: 30, power: power, lid: .closed), at: now), .safe
      )
    }
  }

  func testInvalidBatteryValuesAreNeverSafeEvenOnChargingPower() {
    let now = instant(seconds: 100)
    for battery: Int? in [nil, -1, 101] {
      XCTAssertEqual(
        policy.evaluate(device(at: now, battery: battery, power: .acCharging), at: now),
        .stop(.batteryUnavailable)
      )
    }
  }

  func testRepeatedDecreasesWhileChargingApplyBatteryFloorAndDuplicateDoesNotCount() {
    var tracker = DeviceSafetyTracker()
    func sample(_ percent: Int, _ seconds: UInt64) -> DeviceSafetySnapshot {
      device(at: instant(seconds: seconds), battery: percent, power: .acCharging, lid: .closed)
    }
    XCTAssertEqual(tracker.evaluate(sample(31, 100), at: instant(seconds: 100)), .safe)
    XCTAssertEqual(tracker.evaluate(sample(29, 101), at: instant(seconds: 101)), .safe)
    XCTAssertEqual(tracker.evaluate(sample(29, 101), at: instant(seconds: 101)), .safe)
    XCTAssertEqual(
      tracker.evaluate(sample(28, 102), at: instant(seconds: 102)),
      .stop(.batteryBelowFloor(observed: 28, floor: 30))
    )
    XCTAssertEqual(
      tracker.evaluate(sample(28, 103), at: instant(seconds: 103)),
      .stop(.batteryBelowFloor(observed: 28, floor: 30))
    )
    XCTAssertEqual(tracker.evaluate(sample(29, 104), at: instant(seconds: 104)), .safe)
  }

  func testChargingTrendDoesNotBridgeAStaleSamplingGap() {
    var tracker = DeviceSafetyTracker()
    func sample(_ percent: Int, _ seconds: UInt64) -> DeviceSafetySnapshot {
      device(at: instant(seconds: seconds), battery: percent, power: .acCharging, lid: .closed)
    }
    XCTAssertEqual(tracker.evaluate(sample(31, 100), at: instant(seconds: 100)), .safe)
    XCTAssertEqual(tracker.evaluate(sample(29, 101), at: instant(seconds: 101)), .safe)
    XCTAssertEqual(tracker.evaluate(sample(28, 200), at: instant(seconds: 200)), .safe)
    XCTAssertEqual(tracker.evaluate(sample(27, 201), at: instant(seconds: 201)), .safe)
    XCTAssertEqual(
      tracker.evaluate(sample(26, 202), at: instant(seconds: 202)),
      .stop(.batteryBelowFloor(observed: 26, floor: 30))
    )
  }

  func testUnavailableBatteryBreaksTheChargingTrendAndWithdrawsSafety() {
    var tracker = DeviceSafetyTracker()
    for (seconds, percent): (UInt64, Int) in [(100, 31), (101, 29)] {
      _ = tracker.evaluate(
        device(at: instant(seconds: seconds), battery: percent, power: .acCharging, lid: .closed),
        at: instant(seconds: seconds)
      )
    }
    let missing = device(at: instant(seconds: 102), battery: nil, power: .acCharging, lid: .closed)
    guard case .uncertain(.batteryUnavailable) = tracker.evaluate(missing, at: instant(seconds: 102)) else {
      return XCTFail("missing battery must not be safe")
    }
    XCTAssertEqual(
      tracker.evaluate(
        device(at: instant(seconds: 103), battery: 28, power: .acCharging, lid: .closed),
        at: instant(seconds: 103)
      ), .safe
    )
  }

  func testClosedLidWithoutExternalDisplayStopsAtFairThermalState() {
    let now = instant(seconds: 100)
    let snapshot = device(
      at: now,
      battery: 80,
      thermal: .fair,
      lid: .closed,
      display: .absent
    )

    XCTAssertEqual(
      policy.evaluate(snapshot, at: now),
      .stop(.thermalLimitReached(observed: .fair, cutoff: .fair))
    )
  }

  func testClosedLidOnBatteryStopsBelowThirtyPercent() {
    let now = instant(seconds: 100)
    let snapshot = device(at: now, battery: 29, lid: .closed)

    XCTAssertEqual(
      policy.evaluate(snapshot, at: now),
      .stop(.batteryBelowFloor(observed: 29, floor: 30))
    )
  }

  func testLowPowerModeRaisesClosedLidFloor() {
    let now = instant(seconds: 100)
    let snapshot = device(
      at: now,
      battery: 39,
      lid: .closed,
      lowPowerMode: true
    )

    XCTAssertEqual(
      policy.evaluate(snapshot, at: now),
      .stop(.batteryBelowFloor(observed: 39, floor: 40))
    )
  }

  func testLowPowerModeTightensThermalCutoffWherePossible() {
    let now = instant(seconds: 100)
    let snapshot = device(
      at: now,
      battery: 80,
      power: .acCharging,
      thermal: .fair,
      lid: .open,
      display: .absent,
      lowPowerMode: true
    )

    XCTAssertEqual(
      DeviceSafetyPolicy().evaluate(snapshot, at: now),
      .stop(.thermalLimitReached(observed: .fair, cutoff: .fair))
    )
  }

  func testCustomPolicyCannotRelaxMinimumSafetyEnvelope() {
    let policy = DeviceSafetyPolicy(
      maximumSnapshotAge: .seconds(3_600),
      closedMaximumSnapshotAge: .seconds(3_600),
      closedWithoutDisplayBatteryFloor: 0,
      closedWithDisplayBatteryFloor: 0,
      openBatteryFloor: 0,
      lowPowerModeBatteryPenalty: 0,
      closedWithoutDisplayThermalCutoff: .critical,
      otherThermalCutoff: .critical
    )

    XCTAssertEqual(policy.maximumSnapshotAge, .seconds(30))
    XCTAssertEqual(policy.closedMaximumSnapshotAge, .seconds(60))
    XCTAssertEqual(policy.closedWithoutDisplayBatteryFloor, 30)
    XCTAssertEqual(policy.closedWithDisplayBatteryFloor, 15)
    XCTAssertEqual(policy.openBatteryFloor, 10)
    XCTAssertEqual(policy.lowPowerModeBatteryPenalty, 10)
    XCTAssertEqual(policy.closedWithoutDisplayThermalCutoff, .fair)
    XCTAssertEqual(policy.otherThermalCutoff, .serious)
  }

  func testChargingPowerStillAppliesEmergencyBatteryFloor() {
    let now = instant(seconds: 100)
    let snapshot = device(
      at: now,
      battery: 5,
      power: .acCharging,
      lid: .closed
    )

    XCTAssertEqual(
      policy.evaluate(snapshot, at: now),
      .stop(.batteryBelowFloor(observed: 5, floor: 10))
    )
  }

  func testStaleSensorSnapshotStops() {
    let capturedAt = instant(seconds: 100)
    let now = instant(seconds: 161)

    XCTAssertEqual(
      policy.evaluate(device(at: capturedAt), at: now),
      .stop(.staleSnapshot(age: .seconds(61)))
    )
  }

  func testClosedLidUsesSixtySecondMaximumAge() {
    let capturedAt = instant(seconds: 100)

    XCTAssertEqual(
      policy.evaluate(
        device(at: capturedAt, lid: .closed),
        at: instant(seconds: 159)
      ),
      .safe
    )
    XCTAssertEqual(
      policy.evaluate(
        device(at: capturedAt, lid: .closed),
        at: instant(seconds: 161)
      ),
      .stop(.staleSnapshot(age: .seconds(61)))
    )
  }

  func testBatteryUnavailableReleasesOnThirdDistinctSnapshot() {
    var tracker = DeviceSafetyTracker(policy: policy)

    XCTAssertEqual(
      tracker.evaluate(
        device(at: instant(seconds: 100), battery: nil),
        at: instant(seconds: 100)
      ),
      .uncertain(.batteryUnavailable(consecutiveFailures: 1, releaseAfter: 3))
    )
    XCTAssertEqual(
      tracker.evaluate(
        device(at: instant(seconds: 101), battery: nil),
        at: instant(seconds: 101)
      ),
      .uncertain(.batteryUnavailable(consecutiveFailures: 2, releaseAfter: 3))
    )
    XCTAssertEqual(
      tracker.evaluate(
        device(at: instant(seconds: 102), battery: nil),
        at: instant(seconds: 102)
      ),
      .stop(.batteryUnavailable)
    )
  }

  func testThermalUnavailableIsUnknownDuringGraceThenStops() {
    var tracker = DeviceSafetyTracker(policy: policy)

    XCTAssertEqual(
      tracker.evaluate(
        device(at: instant(seconds: 100), thermal: .unknown),
        at: instant(seconds: 100)
      ),
      .uncertain(.thermalUnavailable(graceRemaining: .seconds(30)))
    )
    XCTAssertEqual(
      tracker.evaluate(
        device(at: instant(seconds: 129), thermal: .unknown),
        at: instant(seconds: 129)
      ),
      .uncertain(.thermalUnavailable(graceRemaining: .seconds(1)))
    )
    XCTAssertEqual(
      tracker.evaluate(
        device(at: instant(seconds: 130), thermal: .unknown),
        at: instant(seconds: 130)
      ),
      .stop(.thermalUnavailable)
    )
  }

  func testRecoveredSensorsResetFailureTracking() {
    var tracker = DeviceSafetyTracker(policy: policy)
    _ = tracker.evaluate(
      device(at: instant(seconds: 100), battery: nil, thermal: .unknown),
      at: instant(seconds: 100)
    )

    XCTAssertEqual(
      tracker.evaluate(
        device(at: instant(seconds: 101)),
        at: instant(seconds: 101)
      ),
      .safe
    )
    XCTAssertEqual(
      tracker.evaluate(
        device(at: instant(seconds: 102), battery: nil),
        at: instant(seconds: 102)
      ),
      .uncertain(.batteryUnavailable(consecutiveFailures: 1, releaseAfter: 3))
    )
  }
}

func instant(seconds: UInt64) -> MonotonicInstant {
  MonotonicInstant(continuousNanoseconds: seconds * 1_000_000_000)
}

func device(
  at time: MonotonicInstant,
  battery: Int? = 80,
  power: PowerConnection = .battery,
  thermal: ThermalLevel = .nominal,
  lid: LidState = .open,
  display: ExternalDisplayState = .absent,
  lowPowerMode: Bool = false
) -> DeviceSafetySnapshot {
  DeviceSafetySnapshot(
    batteryPercent: battery,
    powerConnection: power,
    thermalLevel: thermal,
    lidState: lid,
    externalDisplayState: display,
    lowPowerModeEnabled: lowPowerMode,
    capturedAt: time
  )
}

func network(
  ssid: String?,
  at time: MonotonicInstant,
  interface: String? = "en0",
  gateway: String? = nil,
  reachable: Bool = true,
  internet: InternetReachability = .confirmed
) -> NetworkSnapshot {
  NetworkSnapshot(
    ssid: ssid,
    interfaceName: interface,
    gateway: gateway,
    routeReachable: reachable,
    internetReachability: internet,
    capturedAt: time
  )
}
