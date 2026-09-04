import XCTest

@testable import RuntinueCore

final class ChargingDropPersistenceTests: XCTestCase {
  func testLaterSnapshotAppliesFloorToPersistentChargingDrop() {
    var tracker = DeviceSafetyTracker()

    XCTAssertEqual(tracker.evaluate(sample(31, at: 100), at: instant(100)), .safe)
    XCTAssertEqual(tracker.evaluate(sample(29, at: 101), at: instant(101)), .safe)
    XCTAssertEqual(
      tracker.evaluate(sample(29, at: 102), at: instant(102)),
      .stop(.batteryBelowFloor(observed: 29, floor: 30))
    )
  }

  func testDuplicateSnapshotCannotConfirmAChargingDrop() {
    var tracker = DeviceSafetyTracker()
    let first = sample(31, at: 100)
    let drop = sample(29, at: 101)

    XCTAssertEqual(tracker.evaluate(first, at: instant(100)), .safe)
    XCTAssertEqual(tracker.evaluate(drop, at: instant(101)), .safe)
    XCTAssertEqual(tracker.evaluate(drop, at: instant(101)), .safe)
    XCTAssertEqual(
      tracker.evaluate(sample(29, at: 102), at: instant(102)),
      .stop(.batteryBelowFloor(observed: 29, floor: 30))
    )
  }

  func testBatteryRecoveryClearsAnUnconfirmedChargingDrop() {
    var tracker = DeviceSafetyTracker()

    XCTAssertEqual(tracker.evaluate(sample(31, at: 100), at: instant(100)), .safe)
    XCTAssertEqual(tracker.evaluate(sample(29, at: 101), at: instant(101)), .safe)
    XCTAssertEqual(tracker.evaluate(sample(30, at: 102), at: instant(102)), .safe)
    XCTAssertEqual(tracker.evaluate(sample(29, at: 103), at: instant(103)), .safe)
    XCTAssertEqual(tracker.evaluate(sample(30, at: 104), at: instant(104)), .safe)
  }

  func testPersistentChargingDropRemainsConservativeUntilBatteryRises() {
    var tracker = DeviceSafetyTracker()

    XCTAssertEqual(tracker.evaluate(sample(50, at: 100), at: instant(100)), .safe)
    XCTAssertEqual(tracker.evaluate(sample(49, at: 101), at: instant(101)), .safe)
    XCTAssertEqual(tracker.evaluate(sample(49, at: 102), at: instant(102)), .safe)
    XCTAssertEqual(
      tracker.evaluate(sample(29, at: 103), at: instant(103)),
      .stop(.batteryBelowFloor(observed: 29, floor: 30))
    )
    XCTAssertEqual(tracker.evaluate(sample(30, at: 104), at: instant(104)), .safe)
  }

  func testOutOfOrderSnapshotCannotConfirmOrReplaceChargingTrend() {
    var tracker = DeviceSafetyTracker()

    XCTAssertEqual(tracker.evaluate(sample(31, at: 100), at: instant(100)), .safe)
    XCTAssertEqual(tracker.evaluate(sample(29, at: 102), at: instant(102)), .safe)
    XCTAssertEqual(tracker.evaluate(sample(28, at: 101), at: instant(102)), .safe)
    XCTAssertEqual(
      tracker.evaluate(sample(29, at: 103), at: instant(103)),
      .stop(.batteryBelowFloor(observed: 29, floor: 30))
    )
  }

  func testLeavingChargingClearsPendingAndPersistentDrops() {
    var tracker = DeviceSafetyTracker()

    XCTAssertEqual(tracker.evaluate(sample(50, at: 100), at: instant(100)), .safe)
    XCTAssertEqual(tracker.evaluate(sample(49, at: 101), at: instant(101)), .safe)
    XCTAssertEqual(
      tracker.evaluate(sample(49, power: .acNotCharging, at: 102), at: instant(102)),
      .safe
    )
    XCTAssertEqual(tracker.evaluate(sample(29, at: 103), at: instant(103)), .safe)
    XCTAssertEqual(tracker.evaluate(sample(29, at: 104), at: instant(104)), .safe)

    tracker = DeviceSafetyTracker()
    XCTAssertEqual(tracker.evaluate(sample(50, at: 200), at: instant(200)), .safe)
    XCTAssertEqual(tracker.evaluate(sample(49, at: 201), at: instant(201)), .safe)
    XCTAssertEqual(tracker.evaluate(sample(49, at: 202), at: instant(202)), .safe)
    XCTAssertEqual(
      tracker.evaluate(sample(49, power: .acNotCharging, at: 203), at: instant(203)),
      .safe
    )
    XCTAssertEqual(tracker.evaluate(sample(29, at: 204), at: instant(204)), .safe)
    XCTAssertEqual(tracker.evaluate(sample(29, at: 205), at: instant(205)), .safe)
  }

  func testFreshPowerExitClearsTrendBeforeThermalUnknownReturn() {
    for power in [PowerConnection.acNotCharging, .battery, .unknown] {
      var tracker = DeviceSafetyTracker()

      XCTAssertEqual(tracker.evaluate(sample(31, at: 100), at: instant(100)), .safe)
      XCTAssertEqual(tracker.evaluate(sample(29, at: 101), at: instant(101)), .safe)
      XCTAssertEqual(
        tracker.evaluate(
          sample(29, power: power, thermal: .unknown, at: 102),
          at: instant(102)
        ),
        .uncertain(.thermalUnavailable(graceRemaining: .seconds(30)))
      )
      XCTAssertEqual(tracker.evaluate(sample(29, at: 103), at: instant(103)), .safe)
      XCTAssertEqual(tracker.evaluate(sample(29, at: 104), at: instant(104)), .safe)
    }
  }

  func testThermalUnknownFirstDropStillSeedsPersistentTrend() {
    var tracker = DeviceSafetyTracker()

    XCTAssertEqual(tracker.evaluate(sample(31, at: 100), at: instant(100)), .safe)
    XCTAssertEqual(
      tracker.evaluate(sample(29, thermal: .unknown, at: 101), at: instant(101)),
      .uncertain(.thermalUnavailable(graceRemaining: .seconds(30)))
    )
    XCTAssertEqual(
      tracker.evaluate(sample(29, at: 102), at: instant(102)),
      .stop(.batteryBelowFloor(observed: 29, floor: 30))
    )
  }

  func testThermalUnknownFollowUpStillMarksPersistentTrend() {
    var tracker = DeviceSafetyTracker()

    XCTAssertEqual(tracker.evaluate(sample(31, at: 100), at: instant(100)), .safe)
    XCTAssertEqual(tracker.evaluate(sample(29, at: 101), at: instant(101)), .safe)
    XCTAssertEqual(
      tracker.evaluate(sample(29, thermal: .unknown, at: 102), at: instant(102)),
      .uncertain(.thermalUnavailable(graceRemaining: .seconds(30)))
    )
    XCTAssertEqual(
      tracker.evaluate(sample(29, at: 103), at: instant(103)),
      .stop(.batteryBelowFloor(observed: 29, floor: 30))
    )
  }

  private func sample(
    _ percent: Int,
    power: PowerConnection = .acCharging,
    thermal: ThermalLevel = .nominal,
    at seconds: UInt64
  ) -> DeviceSafetySnapshot {
    DeviceSafetySnapshot(
      batteryPercent: percent,
      powerConnection: power,
      thermalLevel: thermal,
      lidState: .closed,
      externalDisplayState: .absent,
      lowPowerModeEnabled: false,
      capturedAt: instant(seconds)
    )
  }

  private func instant(_ seconds: UInt64) -> MonotonicInstant {
    MonotonicInstant(continuousNanoseconds: seconds * 1_000_000_000)
  }
}
