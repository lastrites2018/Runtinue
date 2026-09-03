import XCTest

@testable import RuntinueCore

final class ChargingDischargeConfirmationTests: XCTestCase {
  func testNextFreshSampleConfirmsAnUnrecoveredChargingDrop() {
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

  func testConfirmedDrainRemainsConservativeUntilBatteryRises() {
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

  private func sample(_ percent: Int, at seconds: UInt64) -> DeviceSafetySnapshot {
    DeviceSafetySnapshot(
      batteryPercent: percent,
      powerConnection: .acCharging,
      thermalLevel: .nominal,
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
