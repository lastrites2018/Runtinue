import AppKit
import XCTest

@testable import SafeClamIPC
@testable import SafeClamMenuBar

@MainActor
final class MenuBarFormViewsTests: XCTestCase {
  func testTripControlsSwitchToUSBAndProduceTheSameWireRequest() throws {
    _ = NSApplication.shared
    let form = TripConfigurationView()
    let target: NSPopUpButton = try control("safeclam.trip.target", in: form)
    let hotspot: NSTextField = try control("safeclam.trip.hotspot", in: form)
    let duration: NSTextField = try control("safeclam.trip.duration", in: form)
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
    let hotspot: NSTextField = try control("safeclam.trip.hotspot", in: form)
    let duration: NSTextField = try control("safeclam.trip.duration", in: form)
    hotspot.stringValue = "Fixture Hotspot"
    duration.stringValue = "not-a-duration"
    XCTAssertThrowsError(try form.input.makeRequest())
  }

  func testDeskDefaultsToOpenLidAndAdaptiveInputsRemainIndependent() throws {
    _ = NSApplication.shared
    let desk = DeskConfigurationView()
    let checkbox: NSButton = try control("safeclam.desk.closedLid", in: desk)
    XCTAssertEqual(checkbox.state, .off)
    XCTAssertFalse(try desk.input.validatedSettings().allowClosedLid)
    let adaptive = AdaptiveConfigurationView()
    let grace: NSTextField = try control("safeclam.adaptive.grace", in: adaptive)
    let duration: NSTextField = try control("safeclam.adaptive.duration", in: adaptive)
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
