import Foundation
import XCTest

@testable import RuntinueIPC
@testable import RuntinueMenuBar

@MainActor
final class TripPreferencesTests: XCTestCase {
  func testLastHotspotIsRestoredByANewPreferencesInstance() throws {
    let fixture = try isolatedDefaults()
    let preferences = TripPreferences(defaults: fixture.defaults)
    XCTAssertNil(preferences.lastHotspotSSID)
    preferences.remember(request(ssid: "  Fixture Phone  "))

    let restoredDefaults = try XCTUnwrap(UserDefaults(suiteName: fixture.name))
    let restored = TripPreferences(defaults: restoredDefaults)
    XCTAssertEqual(restored.lastHotspotSSID, "Fixture Phone")
    let form = TripConfigurationView(
      rememberedHotspotSSID: restored.lastHotspotSSID, currentWiFiSSID: "Office"
    )
    XCTAssertEqual(try form.input.makeRequest().expectedHotspotSSID, "Fixture Phone")
  }

  func testUSBRequestPreservesRememberedWiFiHotspot() throws {
    let fixture = try isolatedDefaults()
    let preferences = TripPreferences(defaults: fixture.defaults)
    preferences.remember(request(ssid: "Fixture Phone"))
    preferences.remember(
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
    preferences.remember(request(ssid: "Fixture Phone"))
    for invalid in ["  ", String(repeating: "가", count: 11)] {
      preferences.remember(request(ssid: invalid))
      XCTAssertEqual(preferences.lastHotspotSSID, "Fixture Phone")
    }
    preferences.remember(request(ssid: "Another Phone"))
    XCTAssertEqual(preferences.lastHotspotSSID, "Another Phone")
  }

  func testMalformedStoredPreferenceIsIgnored() throws {
    let fixture = try isolatedDefaults()
    let preferences = TripPreferences(defaults: fixture.defaults)
    for invalid: Any in [42, ["unexpected"], " ", String(repeating: "a", count: 33)] {
      fixture.defaults.set(invalid, forKey: "trip.lastHotspotSSID")
      XCTAssertNil(preferences.lastHotspotSSID)
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

  private func request(ssid: String) -> StartTripWireRequest {
    StartTripWireRequest(
      expectedHotspotSSID: ssid, hotspotHandoffTimeoutSeconds: 900, hardCapSeconds: 3_600
    )
  }
}
