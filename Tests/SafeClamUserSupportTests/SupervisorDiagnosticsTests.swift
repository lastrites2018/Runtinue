import Foundation
import XCTest

@testable import SafeClamIPC
@testable import SafeClamUserSupport

final class SupervisorDiagnosticsTests: XCTestCase {
  func testSleepOverrideWarningIsNilWhenSleepIsEnabledForEveryVerdict() {
    for verdict in allVerdicts {
      XCTAssertNil(
        SupervisorDiagnostics.sleepOverrideWarning(
          isSleepDisabled: false,
          status: status(verdict: verdict)
        ),
        "unexpected warning for verdict \(verdict)"
      )
    }
  }

  func testSleepOverrideWarningWhenSleepIsDisabledAndStatusIsUnavailable() {
    XCTAssertEqual(
      SupervisorDiagnostics.sleepOverrideWarning(
        isSleepDisabled: true,
        status: nil
      ),
      "경고: Supervisor에 연결할 수 없고 SleepDisabled가 켜져 있습니다."
    )
    XCTAssertNil(
      SupervisorDiagnostics.sleepOverrideWarning(
        isSleepDisabled: false,
        status: nil
      )
    )
  }

  func testSleepOverrideWarningAllowsProtectedOrRecoveryStates() {
    for verdict: WireProtectionVerdict in [.protected, .releasing, .recoveryPending] {
      XCTAssertNil(
        SupervisorDiagnostics.sleepOverrideWarning(
          isSleepDisabled: true,
          status: status(verdict: verdict)
        ),
        "unexpected warning for verdict \(verdict)"
      )
    }
  }

  func testSleepOverrideWarningForEveryNonProtectedState() {
    for verdict in allVerdicts where ![.protected, .releasing, .recoveryPending].contains(verdict) {
      XCTAssertEqual(
        SupervisorDiagnostics.sleepOverrideWarning(
          isSleepDisabled: true,
          status: status(verdict: verdict)
        ),
        "경고: SleepDisabled가 켜져 있지만 Supervisor가 보호 또는 복구 상태를 확인하지 못했습니다.",
        "missing warning for verdict \(verdict)"
      )
    }
  }

  private var allVerdicts: [WireProtectionVerdict] {
    [
      .inactive, .waitingForHotspot, .acquiring, .protected, .releasing, .recoveryPending, .unsafe,
      .unknown,
    ]
  }
}

private func status(verdict: WireProtectionVerdict) -> SupervisorStatusWire {
  SupervisorStatusWire(
    phase: verdict == .inactive ? .idle : .active,
    mode: verdict == .inactive ? .none : .trip,
    sessionID: verdict == .inactive ? nil : UUID(),
    verdict: verdict,
    closedLidAllowed: verdict == .protected,
    remainingSeconds: verdict == .protected ? 600 : nil,
    batteryPercent: 80,
    thermalLevel: "nominal",
    lidState: "open",
    detail: nil,
    updatedAt: Date(timeIntervalSince1970: 1)
  )
}
