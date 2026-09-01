import Foundation
import XCTest

@testable import RuntinueCore
@testable import RuntinueIPC
@testable import RuntinueMenuBar

@MainActor
final class TripPreferencesTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_000)

  func testLastInputIsRestoredWithoutTreatingItAsVerified() throws {
    let fixture = try isolatedDefaults()
    let preferences = TripPreferences(defaults: fixture.defaults)
    XCTAssertNil(preferences.lastHotspotSSID)
    preferences.rememberInput(request(ssid: "  Fixture Phone  "))

    let restoredDefaults = try XCTUnwrap(UserDefaults(suiteName: fixture.name))
    let restored = TripPreferences(defaults: restoredDefaults)
    XCTAssertEqual(restored.lastHotspotSSID, "Fixture Phone")
    XCTAssertNil(restored.confirmedHotspotSSID(for: network()))
    let form = TripConfigurationView(
      rememberedHotspotSSID: restored.lastHotspotSSID, currentWiFiSSID: "Office"
    )
    XCTAssertEqual(form.input.hotspotSSID, "Fixture Phone")
    XCTAssertThrowsError(try form.input.makeRequest())
  }

  func testProtectedTargetIsRememberedAndReusedWithoutAnotherConfirmation() throws {
    let fixture = try isolatedDefaults()
    let preferences = TripPreferences(defaults: fixture.defaults)
    let sessionID = UUID()
    preferences.rememberInput(request(ssid: "Fixture Phone"))
    preferences.registerAcceptedRequest(request(ssid: "Fixture Phone"), status: status(sessionID))
    XCTAssertNil(preferences.confirmedHotspotSSID(for: network()))
    preferences.observeProtection(status(sessionID), network: network(), now: now)
    XCTAssertFalse(preferences.hasPendingVerification)

    let restored = TripPreferences(defaults: try XCTUnwrap(UserDefaults(suiteName: fixture.name)))
    XCTAssertEqual(restored.confirmedHotspotSSID(for: network()), "Fixture Phone")
    let form = TripConfigurationView(
      rememberedHotspotSSID: restored.lastHotspotSSID, currentWiFiSSID: "Fixture Phone",
      confirmedHotspotSSID: restored.confirmedHotspotSSID(for: network())
    )
    XCTAssertTrue(try form.input.makeRequest().allowAlreadyConnected)
  }

  func testUnprotectedOrUnmatchedObservationsCannotVerifyTheInput() throws {
    let fixture = try isolatedDefaults()
    let preferences = TripPreferences(defaults: fixture.defaults)
    let sessionID = UUID()
    preferences.registerAcceptedRequest(request(ssid: "Fixture Phone"), status: status(sessionID))
    let observations: [(SupervisorStatusWire, NetworkSnapshot?)] = [
      (status(sessionID, phase: .waitingForHotspot), network()),
      (status(sessionID, verdict: .unknown), network()),
      (status(sessionID, closedLidAllowed: false), network()),
      (status(sessionID, protocolVersion: 4), network()),
      (status(sessionID, updatedAt: now.addingTimeInterval(-31)), network()),
      (status(sessionID, updatedAt: now.addingTimeInterval(1)), network()),
      (status(sessionID), nil),
      (status(sessionID), network(ssid: "Office")),
      (status(sessionID), network(routeReachable: false)),
      (status(sessionID), network(gateway: nil)),
      (status(sessionID), network(interface: nil)),
    ]
    for (observation, network) in observations {
      preferences.observeProtection(observation, network: network, now: now)
      XCTAssertNil(preferences.confirmedHotspotSSID(for: self.network()))
    }
    XCTAssertTrue(preferences.hasPendingVerification)
  }

  func testDifferentOrEndedSessionCancelsPendingVerification() throws {
    let fixture = try isolatedDefaults()
    let preferences = TripPreferences(defaults: fixture.defaults)
    let sessionID = UUID()
    for terminal in [status(UUID()), status(sessionID, phase: .ended)] {
      preferences.registerAcceptedRequest(request(ssid: "Fixture Phone"), status: status(sessionID))
      preferences.observeProtection(terminal, network: network(), now: now)
      XCTAssertFalse(preferences.hasPendingVerification)
      preferences.observeProtection(status(sessionID), network: network(), now: now)
      XCTAssertNil(preferences.confirmedHotspotSSID(for: network()))
    }
  }

  func testAnUnconfirmedRequestCannotRegisterVerification() throws {
    let fixture = try isolatedDefaults()
    let preferences = TripPreferences(defaults: fixture.defaults)
    preferences.registerAcceptedRequest(
      request(ssid: "Fixture Phone", confirmed: false), status: status(UUID())
    )
    XCTAssertFalse(preferences.hasPendingVerification)
  }

  func testFailedNewInputDoesNotReplaceTheLastProtectedTarget() throws {
    let fixture = try isolatedDefaults()
    let preferences = TripPreferences(defaults: fixture.defaults)
    let sessionID = UUID()
    preferences.registerAcceptedRequest(request(ssid: "Fixture Phone"), status: status(sessionID))
    preferences.observeProtection(status(sessionID), network: network(), now: now)
    preferences.rememberInput(request(ssid: "Office"))
    XCTAssertEqual(preferences.lastEnteredSSID, "Office")
    XCTAssertEqual(preferences.lastHotspotSSID, "Fixture Phone")
    XCTAssertEqual(preferences.confirmedHotspotSSID(for: network(ssid: "Office")), "Fixture Phone")
  }

  func testSameSSIDWithADifferentFingerprintRequiresConfirmationAgain() throws {
    let fixture = try isolatedDefaults()
    let preferences = TripPreferences(defaults: fixture.defaults)
    let sessionID = UUID()
    preferences.registerAcceptedRequest(request(ssid: "Fixture Phone"), status: status(sessionID))
    preferences.observeProtection(status(sessionID), network: network(), now: now)
    XCTAssertNil(preferences.confirmedHotspotSSID(for: network(gateway: "192.0.2.1")))
    XCTAssertNil(preferences.confirmedHotspotSSID(for: network(interface: "en1")))
    XCTAssertNil(preferences.confirmedHotspotSSID(for: network(routeReachable: false)))
    XCTAssertEqual(preferences.lastHotspotSSID, "Fixture Phone")
  }

  func testUSBRequestPreservesRememberedWiFiHotspot() throws {
    let fixture = try isolatedDefaults()
    let preferences = TripPreferences(defaults: fixture.defaults)
    preferences.rememberInput(request(ssid: "Fixture Phone"))
    preferences.rememberInput(
      StartTripWireRequest(
        networkTargetKind: .usbTethering,
        hotspotHandoffTimeoutSeconds: 900,
        hardCapSeconds: 3_600
      )
    )
    XCTAssertEqual(preferences.lastHotspotSSID, "Fixture Phone")
  }

  func testInvalidNamesCannotReplaceTheLastInput() throws {
    let fixture = try isolatedDefaults()
    let preferences = TripPreferences(defaults: fixture.defaults)
    preferences.rememberInput(request(ssid: "Fixture Phone"))
    for invalid in ["  ", String(repeating: "가", count: 11)] {
      preferences.rememberInput(request(ssid: invalid))
      XCTAssertEqual(preferences.lastHotspotSSID, "Fixture Phone")
    }
    preferences.rememberInput(request(ssid: "Another Phone"))
    XCTAssertEqual(preferences.lastHotspotSSID, "Another Phone")
  }

  func testMalformedStoredPreferenceIsIgnored() throws {
    let fixture = try isolatedDefaults()
    let preferences = TripPreferences(defaults: fixture.defaults)
    for invalid: Any in [42, ["unexpected"], " ", String(repeating: "a", count: 33)] {
      fixture.defaults.set(invalid, forKey: "trip.lastHotspotSSID")
      XCTAssertNil(preferences.lastHotspotSSID)
    }
    for invalid in [Data("not-json".utf8), Data(repeating: 65, count: 1_025)] {
      fixture.defaults.set(invalid, forKey: "trip.verifiedHotspot.v1")
      XCTAssertNil(preferences.confirmedHotspotSSID(for: network()))
    }
  }

  private func isolatedDefaults() throws -> (name: String, defaults: UserDefaults) {
    let name = "io.github.lastrites2018.runtinue.tests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    addTeardownBlock {
      UserDefaults.standard.removePersistentDomain(forName: name)
    }
    return (name, defaults)
  }

  private func request(ssid: String, confirmed: Bool = true) -> StartTripWireRequest {
    StartTripWireRequest(
      expectedHotspotSSID: ssid, hotspotHandoffTimeoutSeconds: 900, hardCapSeconds: 3_600,
      allowAlreadyConnected: confirmed
    )
  }

  private func network(
    ssid: String = "Fixture Phone", gateway: String? = "172.20.10.1",
    interface: String? = "en0", routeReachable: Bool = true
  ) -> NetworkSnapshot {
    NetworkSnapshot(
      ssid: ssid, interfaceName: interface, gateway: gateway, routeReachable: routeReachable,
      capturedAt: MonotonicInstant(continuousNanoseconds: 1_000_000_000)
    )
  }

  private func status(
    _ sessionID: UUID, phase: WireTripPhase = .active,
    verdict: WireProtectionVerdict = .protected, closedLidAllowed: Bool = true,
    protocolVersion: Int = RuntinueIPCContract.protocolVersion, updatedAt: Date? = nil
  ) -> SupervisorStatusWire {
    SupervisorStatusWire(
      protocolVersion: protocolVersion, phase: phase, mode: .trip, sessionID: sessionID,
      verdict: verdict, closedLidAllowed: closedLidAllowed, remainingSeconds: 600,
      batteryPercent: 80, thermalLevel: "nominal", lidState: "open", detail: nil,
      updatedAt: updatedAt ?? now
    )
  }
}
