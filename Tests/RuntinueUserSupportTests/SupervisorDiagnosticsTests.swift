import Foundation
import XCTest

@testable import RuntinueIPC
@testable import RuntinueUserSupport

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

  func testFreshTemperatureTelemetryNamesComponentsAndCoverage() {
    let now = Date(timeIntervalSince1970: 1_010)
    let telemetry = temperatureTelemetry(
      status: .available,
      sampledAt: Date(timeIntervalSince1970: 1_000),
      validUntil: Date(timeIntervalSince1970: 1_015)
    )

    XCTAssertEqual(
      SupervisorDiagnostics.temperatureSummaryFields(telemetry, now: now),
      [
        "내부 센서 최고: CPU 74.0°C, GPU 66.0°C"
      ]
    )
    let lines = SupervisorDiagnostics.temperatureDiagnosticLines(telemetry, now: now)
    XCTAssertTrue(lines.contains("CPU 센서 범위: 69.0°C–74.0°C, 유효 18/18"))
    XCTAssertTrue(lines.contains("측정: 10초 전"))
    XCTAssertTrue(lines.contains("매핑 검증: 동일 모델 실기기 1대"))
    XCTAssertTrue(lines.contains("예상 갱신 주기: 5초"))
    XCTAssertTrue(lines.contains("외장 표면 온도: 소프트웨어로 측정하지 않음"))
  }

  func testStaleTemperatureHidesOldNumbersAndReportsLastSuccess() {
    let telemetry = temperatureTelemetry(
      status: .available,
      sampledAt: Date(timeIntervalSince1970: 1_000),
      validUntil: Date(timeIntervalSince1970: 1_015)
    )
    let now = Date(timeIntervalSince1970: 1_100)

    XCTAssertEqual(
      SupervisorDiagnostics.temperatureSummaryFields(telemetry, now: now),
      ["직접 온도: 최신 측정 없음"]
    )
    let text = SupervisorDiagnostics.temperatureDiagnosticLines(telemetry, now: now)
      .joined(separator: "\n")
    XCTAssertTrue(text.contains("마지막 성공 측정: 1분 전"))
    XCTAssertFalse(text.contains("74.0°C"))
  }

  func testPartialAndUnavailableStatesNeverClaimNormalTemperature() {
    let now = Date(timeIntervalSince1970: 1_010)
    let partial = temperatureTelemetry(
      status: .partial,
      sampledAt: Date(timeIntervalSince1970: 1_000),
      validUntil: Date(timeIntervalSince1970: 1_015)
    )
    XCTAssertTrue(
      SupervisorDiagnostics.temperatureSummaryFields(partial, now: now)[0]
        .contains("부분 측정")
    )

    let unavailable = WireTemperatureTelemetry(
      status: .temporarilyUnavailable,
      source: .appleSMC,
      machineModel: "Mac17,8",
      operatingSystemBuild: "25F84",
      mappingRevision: "Mac17,8-apple-smc-r1",
      mappingQuality: .singleDeviceValidated,
      sampledAt: now,
      validUntil: nil,
      lastSuccessfulAt: Date(timeIntervalSince1970: 900),
      components: []
    )
    XCTAssertEqual(
      SupervisorDiagnostics.temperatureSummaryFields(unavailable, now: now),
      ["직접 온도: 현재 읽을 수 없음"]
    )
    XCTAssertEqual(
      SupervisorDiagnostics.temperatureSummaryFields(nil, now: now),
      ["직접 온도: 설치된 Supervisor에서 지원하지 않음"]
    )
  }

  private var allVerdicts: [WireProtectionVerdict] {
    [
      .inactive, .waitingForHotspot, .acquiring, .protected, .releasing, .recoveryPending, .unsafe,
      .unknown,
    ]
  }
}

private func temperatureTelemetry(
  status: WireTemperatureTelemetryStatus,
  sampledAt: Date,
  validUntil: Date?
) -> WireTemperatureTelemetry {
  WireTemperatureTelemetry(
    status: status,
    source: .appleSMC,
    machineModel: "Mac17,8",
    operatingSystemBuild: "25F84",
    mappingRevision: "Mac17,8-apple-smc-r1",
    mappingQuality: .singleDeviceValidated,
    samplingIntervalSeconds: 5,
    sampledAt: sampledAt,
    validUntil: validUntil,
    lastSuccessfulAt: sampledAt,
    components: [
      WireTemperatureComponentObservation(
        component: .cpuInternal,
        minimumCelsius: 69,
        maximumCelsius: 74,
        validSensorCount: 18,
        expectedSensorCount: 18,
        validSensorIDs: ["Tp00", "Tp04"]
      ),
      WireTemperatureComponentObservation(
        component: .gpuInternal,
        minimumCelsius: 61,
        maximumCelsius: 66,
        validSensorCount: 7,
        expectedSensorCount: 7,
        validSensorIDs: ["Tg0U", "Tg0X"]
      ),
    ]
  )
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
