import AppKit
import XCTest

@testable import RuntinueIPC
@testable import RuntinueMenuBar

@MainActor
final class MenuBarFormViewsTests: XCTestCase {
  func testRememberedHotspotIsKeptWhileConnectedToAnotherNetwork() throws {
    _ = NSApplication.shared
    let form = TripConfigurationView(
      rememberedHotspotSSID: "Fixture Phone", currentWiFiSSID: "Office",
      confirmedHotspotSSID: "Fixture Phone"
    )
    let current: NSTextField = try control("runtinue.trip.currentWiFi", in: form)
    XCTAssertEqual(current.stringValue, "Office")
    XCTAssertEqual(try form.input.makeRequest().expectedHotspotSSID, "Fixture Phone")
  }

  func testCurrentWiFiNameIsUsedOnlyAfterExplicitSelection() throws {
    _ = NSApplication.shared
    let form = TripConfigurationView(currentWiFiSSID: "Fixture Phone")
    let useCurrent: NSButton = try control("runtinue.trip.useCurrentWiFi", in: form)
    XCTAssertEqual(form.input.hotspotSSID, "")
    XCTAssertTrue(useCurrent.isEnabled)
    XCTAssertEqual(useCurrent.accessibilityLabel(), "현재 Wi-Fi 이름 사용")

    _ = useCurrent.sendAction(useCurrent.action, to: useCurrent.target)

    XCTAssertEqual(form.input.hotspotSSID, "Fixture Phone")
    XCTAssertThrowsError(try form.input.makeRequest())
    let confirm: NSButton = try control("runtinue.trip.confirmHotspot", in: form)
    confirm.state = .on
    _ = confirm.sendAction(confirm.action, to: confirm.target)
    XCTAssertEqual(try form.input.makeRequest().expectedHotspotSSID, "Fixture Phone")
    XCTAssertTrue(try form.input.makeRequest().allowAlreadyConnected)
  }

  func testChangingTheHotspotNameRequiresASeparateConfirmation() throws {
    _ = NSApplication.shared
    let form = TripConfigurationView(
      rememberedHotspotSSID: "Fixture Phone", currentWiFiSSID: "Office",
      confirmedHotspotSSID: "Fixture Phone"
    )
    XCTAssertTrue(try form.input.makeRequest().allowAlreadyConnected)
    let hotspot: NSTextField = try control("runtinue.trip.hotspot", in: form)
    hotspot.stringValue = "Office"
    XCTAssertThrowsError(try form.input.makeRequest())
    form.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: hotspot))
    let confirm: NSButton = try control("runtinue.trip.confirmHotspot", in: form)
    XCTAssertEqual(confirm.state, .off)
  }

  func testUnavailableWiFiNameDisablesTheShortcut() throws {
    _ = NSApplication.shared
    let form = TripConfigurationView(rememberedHotspotSSID: "Fixture Phone")
    let useCurrent: NSButton = try control("runtinue.trip.useCurrentWiFi", in: form)
    XCTAssertFalse(useCurrent.isEnabled)
    XCTAssertEqual(form.input.hotspotSSID, "Fixture Phone")
  }

  func testUSBSelectionDisablesCurrentWiFiShortcutWithoutErasingTheName() throws {
    _ = NSApplication.shared
    let form = TripConfigurationView(
      rememberedHotspotSSID: "Saved Phone", currentWiFiSSID: "Current Phone"
    )
    let target: NSPopUpButton = try control("runtinue.trip.target", in: form)
    let useCurrent: NSButton = try control("runtinue.trip.useCurrentWiFi", in: form)
    target.selectItem(at: 1)
    _ = target.sendAction(target.action, to: target.target)
    XCTAssertFalse(useCurrent.isEnabled)
    _ = useCurrent.sendAction(useCurrent.action, to: useCurrent.target)
    XCTAssertEqual(form.input.hotspotSSID, "Saved Phone")
    XCTAssertNil(try form.input.makeRequest().expectedHotspotSSID)

    target.selectItem(at: 0)
    _ = target.sendAction(target.action, to: target.target)
    XCTAssertTrue(useCurrent.isEnabled)
    XCTAssertEqual(form.input.hotspotSSID, "Saved Phone")
  }

  func testTripControlsSwitchToUSBAndProduceTheSameWireRequest() throws {
    _ = NSApplication.shared
    let form = TripConfigurationView()
    let target: NSPopUpButton = try control("runtinue.trip.target", in: form)
    let hotspot: NSTextField = try control("runtinue.trip.hotspot", in: form)
    let duration: NSTextField = try control("runtinue.trip.duration", in: form)
    XCTAssertTrue(hotspot.isEnabled)
    XCTAssertEqual(hotspot.accessibilityLabel(), "핫스팟 이름")
    target.selectItem(at: 1)
    _ = target.sendAction(target.action, to: target.target)
    XCTAssertFalse(hotspot.isEnabled)
    hotspot.stringValue = "must-not-enter-the-usb-request"
    duration.stringValue = "60"
    let request = try form.input.makeRequest()
    XCTAssertEqual(request.networkTargetKind, .usbTethering)
    XCTAssertNil(request.expectedHotspotSSID)
    XCTAssertEqual(request.hardCapSeconds, 3_600)
  }

  func testTripInvalidInputIsRejectedBeforeAnyCommandCanBeSubmitted() throws {
    _ = NSApplication.shared
    let form = TripConfigurationView()
    XCTAssertThrowsError(try form.input.makeRequest())
    let hotspot: NSTextField = try control("runtinue.trip.hotspot", in: form)
    let duration: NSTextField = try control("runtinue.trip.duration", in: form)
    hotspot.stringValue = "Fixture Hotspot"
    duration.stringValue = "not-a-duration"
    XCTAssertThrowsError(try form.input.makeRequest())
  }

  func testDeskDefaultsToOpenLidAndAdaptiveInputsRemainIndependent() throws {
    _ = NSApplication.shared
    let desk = DeskConfigurationView()
    let checkbox: NSButton = try control("runtinue.desk.closedLid", in: desk)
    XCTAssertEqual(checkbox.state, .off)
    XCTAssertFalse(try desk.input.validatedSettings().allowClosedLid)
    let adaptive = AdaptiveConfigurationView()
    let grace: NSTextField = try control("runtinue.adaptive.grace", in: adaptive)
    let duration: NSTextField = try control("runtinue.adaptive.duration", in: adaptive)
    grace.stringValue = "3"
    duration.stringValue = "60"
    let settings = try adaptive.input.validatedSettings()
    XCTAssertEqual(settings.idleGraceSeconds, 180)
    XCTAssertEqual(settings.hardCapSeconds, 3_600)
  }

  private func control<T: NSView>(_ identifier: String, in view: NSView) throws -> T {
    if view.accessibilityIdentifier() == identifier, let control = view as? T {
      return control
    }
    for child in view.subviews {
      if let result: T = try? control(identifier, in: child) { return result }
    }
    throw NSError(domain: "MissingFormControl", code: 1)
  }
}
