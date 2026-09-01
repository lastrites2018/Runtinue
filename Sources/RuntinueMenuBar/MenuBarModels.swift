import Foundation
import RuntinueIPC

enum MenuBarConfigurationError: Error, Equatable, LocalizedError {
  case hotspotRequired
  case hotspotConfirmationRequired
  case hotspotTooLong(maximumBytes: Int)
  case invalidMinutes(field: String, maximum: Double)

  var errorDescription: String? {
    switch self {
    case .hotspotRequired:
      "핫스팟 이름을 입력하세요."
    case .hotspotConfirmationRequired:
      "입력한 이름이 이동 중 사용할 휴대전화 핫스팟인지 확인하세요."
    case .hotspotTooLong(let maximumBytes):
      "핫스팟 이름은 UTF-8 기준 \(maximumBytes)바이트 이하여야 합니다."
    case .invalidMinutes(let field, let maximum):
      "\(field)은 0보다 크고 \(Self.minutes(maximum))분 이하여야 합니다."
    }
  }

  private static func minutes(_ value: Double) -> String {
    value.rounded() == value ? String(Int(value)) : String(value)
  }
}

enum TripTargetSelection: Int, Equatable, Sendable {
  case wifiHotspot
  case usbTethering
}

struct TripFormInput: Equatable, Sendable {
  static let maximumMinutes = 24 * 60.0
  static let maximumHotspotSSIDBytes = 32

  let target: TripTargetSelection
  let hotspotSSID: String
  let protectionMinutes: String
  let handoffTimeoutMinutes: String
  var hotspotConfirmed = false

  func makeRequest() throws -> StartTripWireRequest {
    let hardCapSeconds = try parseMinutes(
      protectionMinutes,
      field: "보호 시간",
      maximum: Self.maximumMinutes
    )
    let handoffTimeoutSeconds = try parseMinutes(
      handoffTimeoutMinutes,
      field: "연결 대기 시간",
      maximum: Self.maximumMinutes
    )

    switch target {
    case .wifiHotspot:
      let normalizedSSID = try Self.validatedHotspotSSID(hotspotSSID)
      guard hotspotConfirmed else { throw MenuBarConfigurationError.hotspotConfirmationRequired }
      return StartTripWireRequest(
        expectedHotspotSSID: normalizedSSID,
        hotspotHandoffTimeoutSeconds: handoffTimeoutSeconds,
        hardCapSeconds: hardCapSeconds,
        allowAlreadyConnected: true
      )
    case .usbTethering:
      return StartTripWireRequest(
        networkTargetKind: .usbTethering,
        hotspotHandoffTimeoutSeconds: handoffTimeoutSeconds,
        hardCapSeconds: hardCapSeconds
      )
    }
  }

  static func validatedHotspotSSID(_ value: String) throws -> String {
    let normalizedSSID = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedSSID.isEmpty else {
      throw MenuBarConfigurationError.hotspotRequired
    }
    guard normalizedSSID.utf8.count <= maximumHotspotSSIDBytes else {
      throw MenuBarConfigurationError.hotspotTooLong(maximumBytes: maximumHotspotSSIDBytes)
    }
    return normalizedSSID
  }
}

struct AdaptiveFormInput: Equatable, Sendable {
  static let maximumIdleGraceMinutes = 60.0
  static let maximumProtectionMinutes = 24 * 60.0

  let idleGraceMinutes: String
  let maximumProtectionMinutes: String

  func validatedSettings() throws -> AdaptiveSettings {
    AdaptiveSettings(
      idleGraceSeconds: try parseMinutes(
        idleGraceMinutes,
        field: "활동 종료 유예 시간",
        maximum: Self.maximumIdleGraceMinutes
      ),
      hardCapSeconds: try parseMinutes(
        maximumProtectionMinutes,
        field: "최대 보호 시간",
        maximum: Self.maximumProtectionMinutes
      )
    )
  }
}

struct AdaptiveSettings: Equatable, Sendable {
  let idleGraceSeconds: Double
  let hardCapSeconds: Double
}

struct DeskFormInput: Equatable, Sendable {
  static let maximumProtectionMinutes = 24 * 60.0

  let maximumProtectionMinutes: String
  let allowClosedLid: Bool

  func validatedSettings() throws -> DeskSettings {
    DeskSettings(
      hardCapSeconds: try parseMinutes(
        maximumProtectionMinutes,
        field: "최대 보호 시간",
        maximum: Self.maximumProtectionMinutes
      ),
      allowClosedLid: allowClosedLid
    )
  }
}

struct DeskSettings: Equatable, Sendable {
  let hardCapSeconds: Double
  let allowClosedLid: Bool
}

struct MenuBarActionAvailability: Equatable, Sendable {
  let canStart: Bool
  let canStop: Bool

  init(status: SupervisorStatusWire?, isCommandInFlight: Bool) {
    guard !isCommandInFlight, let status else {
      canStart = false
      canStop = false
      return
    }
    switch (status.phase, status.verdict) {
    case (.idle, .inactive), (.ended, .inactive), (.ended, .unsafe):
      canStart = status.mode == .none
    default:
      canStart = false
    }
    canStop = status.mode != .none
  }
}

struct MenuBarPresentation: Equatable, Sendable {
  let statusIndicator: String
  let summary: String
  let detail: String

  var buttonTitle: String {
    statusIndicator.isEmpty ? "Runtinue" : "Runtinue \(statusIndicator)"
  }

  init(status: SupervisorStatusWire?, isCommandInFlight: Bool = false) {
    guard !isCommandInFlight else {
      statusIndicator = "…"
      summary = "요청 처리 중, 덮개 닫기 금지"
      detail = "Supervisor의 최신 보호 상태를 기다리는 중"
      return
    }
    guard let status else {
      statusIndicator = "?"
      summary = "보호 상태 확인 불가, 덮개 닫기 금지"
      detail = "Supervisor 연결과 현재 상태를 다시 확인하세요."
      return
    }
    switch status.verdict {
    case .protected:
      statusIndicator = "✓"
      if status.closedLidAllowed {
        summary = "보호 중, 덮개 닫기 가능"
      } else {
        summary = "Desk 보호 중, 덮개 열기 필요"
      }
    case .waitingForHotspot:
      statusIndicator = "…"
      summary = "핫스팟 연결 확인 중, 덮개 닫기 금지"
    case .acquiring:
      statusIndicator = "…"
      summary = "보호 확인 중, 덮개 닫기 금지"
    case .releasing:
      statusIndicator = "…"
      summary = "정상 수면 복구 중, 덮개 닫기 금지"
    case .recoveryPending:
      statusIndicator = "!"
      summary = "정상 수면 복구 재시도 중, 덮개 닫기 금지"
    case .unsafe:
      statusIndicator = "!"
      summary = "기기 안전 우선 중단, 덮개 닫기 금지"
    case .unknown:
      statusIndicator = "?"
      summary = "보호 상태 확인 불가, 덮개 닫기 금지"
    case .inactive:
      statusIndicator = ""
      summary = status.mode == .adaptive ? "Adaptive 활동 대기" : "비활성"
    }

    var fields: [String] = []
    if let remaining = status.remainingSeconds {
      fields.append("남은 시간 \(Self.duration(remaining))")
    }
    if let battery = status.batteryPercent {
      fields.append("배터리 \(battery)%")
    }
    if let thermal = status.thermalLevel {
      fields.append("열 \(thermal)")
    }
    if let detail = status.detail, !detail.isEmpty {
      fields.append(detail)
    }
    self.detail = fields.joined(separator: " | ")
  }

  private static func duration(_ seconds: Double) -> String {
    let totalMinutes = max(0, Int(seconds) / 60)
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60
    return hours > 0 ? "\(hours)시간 \(minutes)분" : "\(minutes)분"
  }
}

private func parseMinutes(
  _ rawValue: String,
  field: String,
  maximum: Double
) throws -> Double {
  let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
  guard
    let minutes = Double(normalized),
    minutes.isFinite,
    minutes > 0,
    minutes <= maximum
  else {
    throw MenuBarConfigurationError.invalidMinutes(
      field: field,
      maximum: maximum
    )
  }
  return minutes * 60
}
