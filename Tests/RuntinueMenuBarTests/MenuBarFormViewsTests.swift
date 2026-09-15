import AppKit
import RuntinueUserSupport
import XCTest

@testable import RuntinueIPC
@testable import RuntinueMenuBar

@MainActor
final class MenuBarFormViewsTests: KoreanInterfaceTestCase {
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
    form.controlTextDidChange(
      Notification(name: NSControl.textDidChangeNotification, object: hotspot))
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

  func testDeskFormUsesExplicitSleepAndDisplayWordingInBothLanguages() throws {
    _ = NSApplication.shared
    let expected = [
      (
        InterfaceLanguage.ko,
        "지속 시간(분)",
        "덮개를 닫아도 Mac을 잠자지 않게 하기",
        "설정한 시간이 지나면 Mac이 다시 자동으로 잠자기 상태로 전환될 수 있습니다. 덮개를 열어 두면 비활성 상태에서도 디스플레이가 꺼지지 않습니다."
      ),
      (
        InterfaceLanguage.en,
        "Duration (min)",
        "Keep Mac awake with lid closed",
        "After the set time, your Mac can sleep automatically again. With the lid open, the display stays on while idle."
      ),
    ]
    for (language, durationLabel, closedLidLabel, note) in expected {
      try InterfaceLanguage.$override.withValue(language) {
        let form = DeskConfigurationView()
        let duration: NSTextField = try control("runtinue.desk.duration", in: form)
        let closedLid: NSButton = try control("runtinue.desk.closedLid", in: form)
        XCTAssertEqual(duration.accessibilityLabel(), durationLabel)
        XCTAssertEqual(closedLid.title, closedLidLabel)
        XCTAssertEqual(closedLid.accessibilityLabel(), closedLidLabel)
        XCTAssertTrue(
          descendants(form).compactMap { ($0 as? NSTextField)?.stringValue }.contains(note))
      }
    }
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

  private func descendants(_ view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + descendants($0) }
  }
}

@MainActor
final class TimedSessionMenuTests: KoreanInterfaceTestCase {
  func testPresetsDispatchTheSelectedDurationWithoutCustomInput() throws {
    let target = TimedMenuActionTarget()
    let menu = makeMenu(target: target)
    XCTAssertEqual(TimedSessionMenu.title, "일정 시간 동안 Mac을 자동으로 잠자지 않게 하기")
    XCTAssertEqual(menu.numberOfItems, 4)
    XCTAssertEqual(menu.item(at: 0)?.title, "분")
    XCTAssertEqual(menu.item(at: 1)?.title, "시간")
    XCTAssertTrue(try XCTUnwrap(menu.item(at: 2)).isSeparatorItem)
    XCTAssertEqual(menu.item(at: 3)?.title, "시간과 덮개 설정…")
    TimedSessionMenu.setEnabled(true, in: menu)

    let expectedMinutes = [[5, 10, 15, 20, 30, 45], [60, 120, 180, 240, 360, 480]]
    var expectedInputs: [DeskFormInput] = []
    for (groupIndex, durations) in expectedMinutes.enumerated() {
      let submenu = try XCTUnwrap(menu.item(at: groupIndex)?.submenu)
      XCTAssertEqual(submenu.numberOfItems, durations.count)
      for (itemIndex, minutes) in durations.enumerated() {
        let item = try XCTUnwrap(submenu.item(at: itemIndex))
        let expected = DeskFormInput(
          maximumProtectionMinutes: String(minutes), allowClosedLid: false)
        XCTAssertEqual(item.representedObject as? DeskFormInput, expected)
        XCTAssertEqual(item.title, groupIndex == 0 ? "\(minutes)분" : "\(minutes / 60)시간")
        XCTAssertEqual(
          item.identifier?.rawValue, "runtinue.desk.preset.\(minutes)")
        XCTAssertEqual(try expected.validatedSettings().hardCapSeconds, Double(minutes * 60))
        XCTAssertFalse(try expected.validatedSettings().allowClosedLid)
        submenu.performActionForItem(at: itemIndex)
        expectedInputs.append(expected)
      }
    }
    XCTAssertEqual(target.presetInputs, expectedInputs)
    XCTAssertEqual(target.customInputCount, 0)
  }

  func testCustomInputUsesOnlyTheExistingFormAction() throws {
    let target = TimedMenuActionTarget()
    let menu = makeMenu(target: target)
    TimedSessionMenu.setEnabled(true, in: menu)
    let custom = try XCTUnwrap(menu.item(at: 3))
    XCTAssertNil(custom.representedObject)
    XCTAssertNil(custom.submenu)
    XCTAssertEqual(custom.identifier?.rawValue, "runtinue.desk.custom")
    menu.performActionForItem(at: 3)
    XCTAssertEqual(target.customInputCount, 1)
    XCTAssertTrue(target.presetInputs.isEmpty)
  }

  func testAllSubmenusFollowTheExistingStartAvailability() {
    let target = TimedMenuActionTarget()
    let menu = makeMenu(target: target)
    assertEnabled(false, in: menu)
    let idle = status(phase: .idle, mode: .none, verdict: .inactive)
    let cases: [(SupervisorStatusWire?, Bool, Bool)] = [
      (nil, false, false),
      (idle, false, true),
      (idle, true, false),
      (status(phase: .active, mode: .desk, verdict: .protected), false, false),
      (status(phase: .recoveryPending, mode: .desk, verdict: .recoveryPending), false, false),
      (idle, false, true),
    ]
    for (status, inFlight, expectedEnabled) in cases {
      let availability = MenuBarActionAvailability(status: status, isCommandInFlight: inFlight)
      XCTAssertEqual(availability.canStart, expectedEnabled)
      TimedSessionMenu.setEnabled(availability.canStart, in: menu)
      assertEnabled(expectedEnabled, in: menu)
    }
  }

  func testRebuiltMenuUsesEnglishLabelsAndTheSameDurations() throws {
    UserDefaults.standard.set("en", forKey: InterfaceLanguage.preferenceKey)
    let target = TimedMenuActionTarget()
    let menu = makeMenu(target: target)
    XCTAssertEqual(TimedSessionMenu.title, "Keep Mac awake for a set time")
    XCTAssertEqual(menu.item(at: 0)?.title, "Minutes")
    XCTAssertEqual(menu.item(at: 1)?.title, "Hours")
    XCTAssertEqual(menu.item(at: 3)?.title, "Time and lid settings…")
    let minutes = try XCTUnwrap(menu.item(at: 0)?.submenu)
    let hours = try XCTUnwrap(menu.item(at: 1)?.submenu)
    XCTAssertEqual(minutes.items.map(\.title), [
      "5 minutes", "10 minutes", "15 minutes", "20 minutes", "30 minutes", "45 minutes",
    ])
    XCTAssertEqual(hours.items.map(\.title), [
      "1 hour", "2 hours", "3 hours", "4 hours", "6 hours", "8 hours",
    ])
    XCTAssertEqual(
      (hours.item(at: 5)?.representedObject as? DeskFormInput)?.maximumProtectionMinutes, "480")
  }

  private func makeMenu(target: TimedMenuActionTarget) -> NSMenu {
    _ = NSApplication.shared
    return TimedSessionMenu.make(
      target: target,
      presetAction: #selector(TimedMenuActionTarget.startPreset(_:)),
      customAction: #selector(TimedMenuActionTarget.openCustom)
    )
  }

  private func assertEnabled(_ enabled: Bool, in menu: NSMenu) {
    XCTAssertFalse(menu.autoenablesItems)
    menu.update()
    for item in menu.items where !item.isSeparatorItem {
      XCTAssertEqual(item.isEnabled, enabled, item.title)
      if let submenu = item.submenu {
        assertEnabled(enabled, in: submenu)
      }
    }
  }

  private func status(
    phase: WireTripPhase,
    mode: WireSessionMode,
    verdict: WireProtectionVerdict
  ) -> SupervisorStatusWire {
    SupervisorStatusWire(
      phase: phase, mode: mode, sessionID: nil, verdict: verdict,
      remainingSeconds: nil, batteryPercent: nil, thermalLevel: nil, lidState: nil,
      detail: nil, updatedAt: Date()
    )
  }
}

@MainActor
private final class TimedMenuActionTarget: NSObject {
  var presetInputs: [DeskFormInput] = []
  var customInputCount = 0

  @objc func startPreset(_ sender: NSMenuItem) {
    if let input = sender.representedObject as? DeskFormInput {
      presetInputs.append(input)
    }
  }

  @objc func openCustom() {
    customInputCount += 1
  }
}
