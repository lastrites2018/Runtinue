import XCTest
import RuntinueCore

@testable import RuntinueSystem

final class MacDeviceProbeTests: XCTestCase {
  func testChargingSignalSeparatesExternalPowerFromBatteryProtection() {
    for charging: Bool? in [true, false, nil] {
      var raw: [String: Any] = [
        "Power Source State": "AC Power", "Current Capacity": 29, "Max Capacity": 100
      ]
      raw["Is Charging"] = charging
      let parsed = MacDeviceProbe.parseInternalBattery(raw)
      XCTAssertEqual(parsed.percentage, 29)
      XCTAssertEqual(parsed.connection, charging == true ? .acCharging : .acNotCharging)
    }
    XCTAssertEqual(
      MacDeviceProbe.parseInternalBattery(["Power Source State": "Battery Power"]).connection,
      .battery
    )
    XCTAssertEqual(MacDeviceProbe.parseInternalBattery([:]).connection, .unknown)
  }

  func testMalformedBatteryNumbersCannotTrapOrBecomeValidPercentages() {
    for current in [Double.nan, .infinity, -.infinity, -1, 101] {
      XCTAssertNil(MacDeviceProbe.parseInternalBattery([
        "Current Capacity": current, "Max Capacity": 100
      ]).percentage)
    }
    for maximum in [Double.nan, .infinity, 0, -1] {
      XCTAssertNil(MacDeviceProbe.parseInternalBattery([
        "Current Capacity": 50, "Max Capacity": maximum
      ]).percentage)
    }
  }

  func testThermalPressureStatesMapWithoutGuessingUnknownValues() {
    let expected: [(UInt64, ThermalLevel)] = [
      (0, .nominal),
      (1, .fair),
      (2, .serious),
      (3, .serious),
      (4, .critical),
      (5, .unknown),
      (.max, .unknown),
    ]

    for (state, level) in expected {
      XCTAssertEqual(MacDeviceProbe.thermalLevel(forPressureState: state), level)
    }
  }

  func testThermalFusionOnlyRaisesAKnownPublicThermalLevel() {
    XCTAssertEqual(MacDeviceProbe.moreSevereThermalLevel(.fair, .serious), .serious)
    XCTAssertEqual(MacDeviceProbe.moreSevereThermalLevel(.critical, .fair), .critical)
    XCTAssertEqual(MacDeviceProbe.moreSevereThermalLevel(.unknown, .fair), .unknown)
    XCTAssertEqual(MacDeviceProbe.moreSevereThermalLevel(.serious, .unknown), .serious)
    XCTAssertEqual(MacDeviceProbe.moreSevereThermalLevel(.unknown, .unknown), .unknown)
  }

  func testLidDisagreementAlwaysUsesClosedAndProducesDiagnosticSignal() {
    for (registry, active) in [(LidState.open, false), (.closed, true)] {
      let resolved = MacDeviceProbe.reconcileLid(
        registry: registry, hasInternalBattery: true, internalDisplayActive: active
      )
      XCTAssertEqual(resolved.state, .closed)
      XCTAssertTrue(resolved.signalsDisagree)
    }
  }

  func testLidAgreementAndUnavailableSignalsRemainConservative() {
    for (registry, active, expected) in [
      (LidState.open, true, LidState.open), (.closed, false, .closed), (.unknown, true, .unknown)
    ] {
      let resolved = MacDeviceProbe.reconcileLid(
        registry: registry, hasInternalBattery: true, internalDisplayActive: active
      )
      XCTAssertEqual(resolved.state, expected)
      XCTAssertFalse(resolved.signalsDisagree)
    }
    XCTAssertEqual(MacDeviceProbe.reconcileLid(
      registry: .open, hasInternalBattery: true, internalDisplayActive: nil
    ).state, .unknown)
    XCTAssertEqual(MacDeviceProbe.reconcileLid(
      registry: .closed, hasInternalBattery: true, internalDisplayActive: nil
    ).state, .closed)
  }
}
