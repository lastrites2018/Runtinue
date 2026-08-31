import Foundation
import XCTest

@testable import RuntinueIPC
@testable import RuntinueMenuBar

final class MenuBarModelsTests: XCTestCase {
  func testIconIndicatorsPreserveEveryProtectionState() {
    let cases: [(WireProtectionVerdict, String)] = [
      (.protected, "✓"),
      (.waitingForHotspot, "…"),
      (.acquiring, "…"),
      (.releasing, "…"),
      (.recoveryPending, "!"),
      (.unsafe, "!"),
      (.unknown, "?"),
      (.inactive, ""),
    ]
    for (verdict, indicator) in cases {
      let presentation = MenuBarPresentation(
        status: status(verdict: verdict, closedLidAllowed: verdict == .protected)
      )
      XCTAssertEqual(presentation.statusIndicator, indicator, verdict.rawValue)
      XCTAssertEqual(
        presentation.buttonTitle,
        indicator.isEmpty ? "Runtinue" : "Runtinue \(indicator)"
      )
    }
    XCTAssertEqual(MenuBarPresentation(status: nil).statusIndicator, "?")
    XCTAssertEqual(
      MenuBarPresentation(status: nil, isCommandInFlight: true).statusIndicator, "…"
    )
  }

  func testWiFiTripBuildsTheSameWireRequestAsCLI() throws {
    let request = try TripFormInput(
      target: .wifiHotspot,
      hotspotSSID: "  iPhone  ",
      protectionMinutes: "90",
      handoffTimeoutMinutes: "15"
    ).makeRequest()

    XCTAssertEqual(request.networkTargetKind, .wifiHotspot)
    XCTAssertEqual(request.expectedHotspotSSID, "iPhone")
    XCTAssertEqual(request.hardCapSeconds, 5_400)
    XCTAssertEqual(request.hotspotHandoffTimeoutSeconds, 900)
  }

  func testUSBTripDoesNotRequireOrForwardSSID() throws {
    let request = try TripFormInput(
      target: .usbTethering,
      hotspotSSID: "ignored",
      protectionMinutes: "60",
      handoffTimeoutMinutes: "10"
    ).makeRequest()

    XCTAssertEqual(request.networkTargetKind, .usbTethering)
    XCTAssertNil(request.expectedHotspotSSID)
  }

  func testWiFiTripRejectsMissingHotspotName() {
    XCTAssertThrowsError(
      try TripFormInput(
        target: .wifiHotspot,
        hotspotSSID: "  ",
        protectionMinutes: "90",
        handoffTimeoutMinutes: "15"
      ).makeRequest()
    ) { error in
      XCTAssertEqual(error as? MenuBarConfigurationError, .hotspotRequired)
    }
  }

  func testWiFiTripRejectsSSIDOverThirtyTwoBytes() {
    XCTAssertThrowsError(
      try TripFormInput(
        target: .wifiHotspot,
        hotspotSSID: String(repeating: "가", count: 11),
        protectionMinutes: "90",
        handoffTimeoutMinutes: "15"
      ).makeRequest()
    ) { error in
      XCTAssertEqual(
        error as? MenuBarConfigurationError,
        .hotspotTooLong(maximumBytes: 32)
      )
    }
  }

  func testTripRejectsProtectionBeyondHardLimit() {
    XCTAssertThrowsError(
      try TripFormInput(
        target: .usbTethering,
        hotspotSSID: "",
        protectionMinutes: "1441",
        handoffTimeoutMinutes: "15"
      ).makeRequest()
    )
  }

  func testAdaptiveSettingsConvertMinutesToSeconds() throws {
    let settings = try AdaptiveFormInput(
      idleGraceMinutes: "2",
      maximumProtectionMinutes: "480"
    ).validatedSettings()

    XCTAssertEqual(settings.idleGraceSeconds, 120)
    XCTAssertEqual(settings.hardCapSeconds, 28_800)
  }

  func testAdaptiveRejectsIdleGraceOverOneHour() {
    XCTAssertThrowsError(
      try AdaptiveFormInput(
        idleGraceMinutes: "61",
        maximumProtectionMinutes: "480"
      ).validatedSettings()
    )
  }

  func testDeskSettingsPreserveClosedLidChoice() throws {
    let settings = try DeskFormInput(
      maximumProtectionMinutes: "120",
      allowClosedLid: true
    ).validatedSettings()

    XCTAssertEqual(settings.hardCapSeconds, 7_200)
    XCTAssertTrue(settings.allowClosedLid)
  }

  func testInvalidDurationsAreRejectedBeforeIPC() {
    for value in ["", "0", "-1", "NaN", "inf", "abc"] {
      XCTAssertThrowsError(
        try DeskFormInput(
          maximumProtectionMinutes: value,
          allowClosedLid: false
        ).validatedSettings(),
        "unexpectedly accepted \(value)"
      )
    }
  }

  func testUnavailableStatusDisablesAllModeCommands() {
    XCTAssertEqual(
      MenuBarActionAvailability(status: nil, isCommandInFlight: false),
      MenuBarActionAvailability(status: nil, isCommandInFlight: true)
    )
    let availability = MenuBarActionAvailability(status: nil, isCommandInFlight: false)
    XCTAssertFalse(availability.canStart)
    XCTAssertFalse(availability.canStop)
  }

  func testIdleModeAllowsStarting() {
    let inactive = SupervisorStatusWire(
      phase: .idle,
      mode: .none,
      sessionID: nil,
      verdict: .inactive,
      remainingSeconds: nil,
      batteryPercent: nil,
      thermalLevel: nil,
      lidState: nil,
      detail: nil,
      updatedAt: Date(timeIntervalSince1970: 1)
    )
    let availability = MenuBarActionAvailability(
      status: inactive,
      isCommandInFlight: false
    )
    XCTAssertTrue(availability.canStart)
    XCTAssertFalse(availability.canStop)

    let busy = MenuBarActionAvailability(status: inactive, isCommandInFlight: true)
    XCTAssertFalse(busy.canStart)
    XCTAssertFalse(busy.canStop)
  }

  func testActiveModeAllowsStopButNotAnotherStart() {
    let availability = MenuBarActionAvailability(
      status: status(verdict: .protected, closedLidAllowed: true),
      isCommandInFlight: false
    )
    XCTAssertFalse(availability.canStart)
    XCTAssertTrue(availability.canStop)
  }

  func testCompletedSafetyStopAllowsRestartWithoutClaimingProtection() {
    let stopped = status(
      verdict: .unsafe,
      closedLidAllowed: false,
      phase: .ended,
      mode: .none
    )
    let availability = MenuBarActionAvailability(
      status: stopped,
      isCommandInFlight: false
    )

    XCTAssertTrue(availability.canStart)
    XCTAssertFalse(availability.canStop)
    XCTAssertTrue(MenuBarPresentation(status: stopped).summary.contains("덮개 닫기 금지"))
  }

  func testRecoveryAndUncertainStatesDoNotAllowRestart() {
    let cases: [(WireTripPhase, WireProtectionVerdict)] = [
      (.releasingLease, .releasing),
      (.recoveryPending, .recoveryPending),
      (.ended, .recoveryPending),
      (.ended, .unknown),
      (.active, .unsafe),
      (.idle, .unsafe),
    ]
    for (phase, verdict) in cases {
      let availability = MenuBarActionAvailability(
        status: status(
          verdict: verdict,
          closedLidAllowed: false,
          phase: phase,
          mode: .none
        ),
        isCommandInFlight: false
      )
      XCTAssertFalse(availability.canStart, "\(phase), \(verdict)")
      XCTAssertFalse(availability.canStop, "\(phase), \(verdict)")
    }
  }

  func testSafetyStopCannotStartOverAnEnabledMode() {
    for mode: WireSessionMode in [.trip, .adaptive, .desk] {
      let availability = MenuBarActionAvailability(
        status: status(
          verdict: .unsafe,
          closedLidAllowed: false,
          phase: .ended,
          mode: mode
        ),
        isCommandInFlight: false
      )
      XCTAssertFalse(availability.canStart, mode.rawValue)
      XCTAssertTrue(availability.canStop, mode.rawValue)
    }
  }

  func testCommandInFlightBlocksRestartAfterSafetyStop() {
    let availability = MenuBarActionAvailability(
      status: status(
        verdict: .unsafe,
        closedLidAllowed: false,
        phase: .ended,
        mode: .none
      ),
      isCommandInFlight: true
    )
    XCTAssertFalse(availability.canStart)
    XCTAssertFalse(availability.canStop)
  }

  func testPresentationNeverClaimsClosedLidWhenNotAllowed() {
    let presentation = MenuBarPresentation(
      status: status(verdict: .protected, closedLidAllowed: false)
    )

    XCTAssertEqual(presentation.summary, "Desk 보호 중, 덮개 열기 필요")
  }

  func testPendingCommandOverridesPreviouslyProtectedPresentation() {
    let presentation = MenuBarPresentation(
      status: status(verdict: .protected, closedLidAllowed: true),
      isCommandInFlight: true
    )

    XCTAssertEqual(presentation.buttonTitle, "Runtinue …")
    XCTAssertEqual(presentation.summary, "요청 처리 중, 덮개 닫기 금지")
    XCTAssertFalse(presentation.detail.contains("남은 시간"))
  }

  func testUnavailablePresentationExplicitlyForbidsClosingLid() {
    let presentation = MenuBarPresentation(status: nil)

    XCTAssertEqual(presentation.buttonTitle, "Runtinue ?")
    XCTAssertEqual(presentation.summary, "보호 상태 확인 불가, 덮개 닫기 금지")
  }

  func testWaitingPresentationExplicitlyForbidsClosingLid() {
    let presentation = MenuBarPresentation(
      status: status(verdict: .waitingForHotspot, closedLidAllowed: false)
    )

    XCTAssertEqual(presentation.summary, "핫스팟 연결 확인 중, 덮개 닫기 금지")
  }

  func testSafetyReleasePresentationsExplicitlyForbidClosingLid() {
    for verdict: WireProtectionVerdict in [.releasing, .recoveryPending, .unsafe] {
      let presentation = MenuBarPresentation(
        status: status(verdict: verdict, closedLidAllowed: false)
      )
      XCTAssertTrue(presentation.summary.contains("덮개 닫기 금지"))
    }
  }
}

private func status(
  verdict: WireProtectionVerdict,
  closedLidAllowed: Bool,
  phase: WireTripPhase? = nil,
  mode: WireSessionMode = .trip
) -> SupervisorStatusWire {
  SupervisorStatusWire(
    phase: phase ?? (verdict == .waitingForHotspot ? .waitingForHotspot : .active),
    mode: mode,
    sessionID: UUID(),
    verdict: verdict,
    closedLidAllowed: closedLidAllowed,
    remainingSeconds: 5_400,
    batteryPercent: 80,
    thermalLevel: "nominal",
    lidState: "open",
    detail: nil,
    updatedAt: Date(timeIntervalSince1970: 1)
  )
}
