import Foundation
import RuntinueIPC
import RuntinueUserSupport

enum MenuBarConfigurationError: Error, Equatable, LocalizedError {
  case hotspotRequired
  case hotspotConfirmationRequired
  case hotspotTooLong(maximumBytes: Int)
  case invalidMinutes(field: String, maximum: Double)

  var errorDescription: String? {
    switch self {
    case .hotspotRequired:
      L("핫스팟 이름을 입력하세요.", "Enter the hotspot name.")
    case .hotspotConfirmationRequired:
      L(
        "입력한 이름이 이동 중 사용할 휴대전화 핫스팟인지 확인하세요.",
        "Confirm that this is the phone hotspot you will use on the go.")
    case .hotspotTooLong(let maximumBytes):
      L(
        "핫스팟 이름이 너무 깁니다. Wi-Fi 이름은 최대 \(maximumBytes)바이트까지 지원합니다.",
        "The hotspot name is too long. Wi-Fi names support up to \(maximumBytes) bytes.")
    case .invalidMinutes(let field, let maximum):
      L(
        "\(field): 1부터 \(Self.minutes(maximum))까지 정수로 입력하세요.",
        "\(field): enter a whole number from 1 to \(Self.minutes(maximum)).")
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
      field: L("실행 유지 시간", "Keep-awake time"),
      maximum: Self.maximumMinutes
    )
    let handoffTimeoutSeconds = try parseMinutes(
      handoffTimeoutMinutes,
      field: L("연결 대기 한도", "Connection wait"),
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
        field: L("활동 종료 후 대기", "Idle wait"),
        maximum: Self.maximumIdleGraceMinutes
      ),
      hardCapSeconds: try parseMinutes(
        maximumProtectionMinutes,
        field: L("실행 유지 한도", "Maximum time"),
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
        field: L("실행 유지 한도", "Maximum time"),
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

enum MenuBarIconStyle: Equatable, Sendable {
  case continuationMark
  case criticalWarning
}

enum MenuBarTone: Equatable, Sendable {
  case neutral
  case progress
  case verified
  case attention
  case stopped
  case unknown
}

enum SafetyCheckState: String, Equatable, Sendable {
  case pending
  case current
  case passed
  case failed
  case unknown
  case verified
}

struct SafetyCheckItem: Equatable, Sendable {
  let text: String
  let state: SafetyCheckState
}

struct SafetyChecklistPresentation: Equatable, Sendable {
  let title: String
  let items: [SafetyCheckItem]

  static func trip(status: SupervisorStatusWire) -> SafetyChecklistPresentation? {
    guard status.mode == .trip else { return nil }

    switch status.verdict {
    case .waitingForHotspot:
      return SafetyChecklistPresentation(
        title: L("안전 확인 중 0/4", "Checking 0/4"),
        items: [
          SafetyCheckItem(text: L("네트워크 연결 확인 중", "Checking network"), state: .current),
          SafetyCheckItem(text: L("인터넷 확인 대기", "Internet check pending"), state: .pending),
          SafetyCheckItem(text: L("기기 상태 확인 대기", "Device check pending"), state: .pending),
          SafetyCheckItem(text: L("수면 보호 확인 대기", "Awake check pending"), state: .pending),
        ]
      )
    case .acquiring:
      return SafetyChecklistPresentation(
        title: L("안전 확인 중 3/4", "Checking 3/4"),
        items: [
          SafetyCheckItem(text: L("시작 시 네트워크 확인", "Network at start"), state: .passed),
          SafetyCheckItem(text: L("시작 시 인터넷 확인", "Internet at start"), state: .passed),
          SafetyCheckItem(text: L("시스템 보호 기준 충족", "System checks passed"), state: .passed),
          SafetyCheckItem(text: L("수면 보호 확인 중", "Verifying keep-awake"), state: .current),
        ]
      )
    case .protected:
      return SafetyChecklistPresentation(
        title: status.closedLidAllowed
          ? L("안전 확인 4개 완료", "All 4 checks passed")
          : L("보호 적용, 덮개 닫기 미승인", "Keeping awake; leave lid open"),
        items: [
          SafetyCheckItem(text: L("시작 시 네트워크 확인", "Network at start"), state: .passed),
          SafetyCheckItem(text: L("시작 시 인터넷 확인", "Internet at start"), state: .passed),
          SafetyCheckItem(text: L("시스템 보호 기준 충족", "System checks passed"), state: .passed),
          SafetyCheckItem(
            text: L("수면 보호 적용됨", "Keep-awake verified"),
            state: status.closedLidAllowed ? .verified : .passed
          ),
        ]
      )
    case .releasing:
      return SafetyChecklistPresentation(
        title: L("복구 상태 확인 중", "Checking sleep recovery"),
        items: [
          SafetyCheckItem(text: L("수면 보호 해제 중", "Releasing keep-awake"), state: .current),
          SafetyCheckItem(text: L("정상 수면 확인 대기", "Sleep check pending"), state: .pending),
        ]
      )
    case .recoveryPending:
      return SafetyChecklistPresentation(
        title: L("복구 상태 확인 필요", "Sleep recovery unconfirmed"),
        items: [
          SafetyCheckItem(text: L("수면 보호 해제 미확인", "Release unconfirmed"), state: .failed),
          SafetyCheckItem(text: L("정상 수면 확인 재시도 중", "Retrying sleep check"), state: .current),
        ]
      )
    case .unsafe:
      guard status.phase == .ended else {
        return SafetyChecklistPresentation(
          title: L("안전 중단 처리 중", "Stopping for safety"),
          items: [
            SafetyCheckItem(text: L("기기 안전 기준 벗어남", "System safety limit reached"), state: .failed),
            SafetyCheckItem(text: L("정상 수면 복구 준비 중", "Preparing sleep recovery"), state: .current),
          ]
        )
      }
      return SafetyChecklistPresentation(
        title: L("안전 중단 완료", "Stopped for safety"),
        items: [
          SafetyCheckItem(text: L("기기 안전 기준 벗어남", "System safety limit reached"), state: .failed),
          SafetyCheckItem(text: L("정상 수면 상태 확인 필요", "Check sleep availability"), state: .unknown),
        ]
      )
    case .unknown:
      return SafetyChecklistPresentation(
        title: L("안전 상태 확인 불가", "Safety status unavailable"),
        items: [
          SafetyCheckItem(text: L("네트워크 연결 확인 불가", "Network unknown"), state: .unknown),
          SafetyCheckItem(text: L("인터넷 연결 확인 불가", "Internet unknown"), state: .unknown),
          SafetyCheckItem(text: L("기기 상태 확인 불가", "Device status unknown"), state: .unknown),
          SafetyCheckItem(text: L("수면 보호 확인 불가", "Keep-awake unconfirmed"), state: .unknown),
        ]
      )
    case .inactive:
      return nil
    }
  }
}

enum MenuBarCriticalWarningPolicy {
  static func shouldReplaceContinuationMark(
    currentStatus: SupervisorStatusWire?,
    lastKnownStatus: SupervisorStatusWire?,
    sleepOverrideUnavailable: Bool
  ) -> Bool {
    guard sleepOverrideUnavailable else { return false }
    guard let responsibility = currentStatus ?? lastKnownStatus else { return false }
    let hasProtectionResponsibility =
      responsibility.sessionID != nil
      || responsibility.mode != .none
      || responsibility.phase == .recoveryPending
      || responsibility.verdict == .recoveryPending
    guard hasProtectionResponsibility else { return false }

    let activeOrRecovering =
      [.active, .releasingLease, .recoveryPending].contains(responsibility.phase)
      || [.protected, .releasing, .recoveryPending, .unknown].contains(responsibility.verdict)
    let liveStateUnconfirmed =
      currentStatus == nil
      || currentStatus?.verdict == .unknown
      || currentStatus?.verdict == .recoveryPending
    return activeOrRecovering && liveStateUnconfirmed
  }
}

struct MenuBarPresentation: Equatable, Sendable {
  private static let supplementalDetailCharacterLimit = 160

  let statusIndicator: String
  let summary: String
  let headline: String
  let guidance: String
  let detail: String
  let iconStyle: MenuBarIconStyle
  let tone: MenuBarTone
  let safetyChecklist: SafetyChecklistPresentation?

  var buttonTitle: String {
    statusIndicator.isEmpty ? "Runtinue" : "Runtinue \(statusIndicator)"
  }

  init(
    status: SupervisorStatusWire?,
    isCommandInFlight: Bool = false,
    iconStyle: MenuBarIconStyle = .continuationMark,
    now: Date = Date()
  ) {
    self.iconStyle = iconStyle
    guard !isCommandInFlight else {
      statusIndicator = "…"
      summary = L("요청 처리 중, 덮개 닫기 금지", "Applying request; keep lid open")
      headline = L("요청 처리 중", "Applying request")
      guidance = L("덮개를 아직 닫지 마세요.", "Keep the lid open for now.")
      detail = L(
        "백그라운드 서비스에서 실행 유지 상태를 확인하고 있습니다.",
        "Waiting for the background service to confirm keep-awake status.")
      tone = .progress
      safetyChecklist = nil
      return
    }
    guard let status else {
      statusIndicator = "?"
      summary = L("보호 상태 확인 불가, 덮개 닫기 금지", "Keep-awake unknown; keep lid open")
      headline = L("보호 상태 확인 불가", "Keep-awake status unknown")
      guidance = L("덮개를 닫지 마세요.", "Keep the lid open.")
      detail = L(
        "백그라운드 서비스에 연결하지 못했습니다. 진단 정보를 확인하세요.",
        "Could not reach the background service. Check Diagnostics.")
      tone = .unknown
      safetyChecklist = nil
      return
    }
    safetyChecklist = SafetyChecklistPresentation.trip(status: status)
    switch status.verdict {
    case .protected:
      statusIndicator = "✓"
      if status.closedLidAllowed {
        summary = L("보호 중, 덮개 닫기 가능", "Keeping awake; lid may be closed")
        headline = L(
          "실행 유지 중, \(Self.mode(status.mode))", "Keeping awake: \(Self.mode(status.mode))")
        guidance = L("덮개 닫기 가능", "Lid may be closed")
        tone = .verified
      } else {
        summary = L(
          "\(Self.mode(status.mode)) 실행 유지 중, 덮개 열기 필요",
          "\(Self.mode(status.mode)): keeping awake; leave lid open")
        headline = L(
          "\(Self.mode(status.mode)) 실행 유지 중", "\(Self.mode(status.mode)): keeping awake")
        guidance = L("덮개를 열어 두세요.", "Leave the lid open.")
        tone = .progress
      }
    case .waitingForHotspot:
      statusIndicator = "…"
      summary = L("핫스팟 연결 확인 중, 덮개 닫기 금지", "Checking hotspot; keep lid open")
      headline = L("핫스팟 연결 확인 중", "Checking hotspot connection")
      guidance = L("덮개를 아직 닫지 마세요.", "Keep the lid open for now.")
      tone = .progress
    case .acquiring:
      statusIndicator = "…"
      summary = L("보호 확인 중, 덮개 닫기 금지", "Verifying keep-awake; keep lid open")
      headline = L("수면 보호 확인 중", "Verifying keep-awake")
      guidance = L("덮개를 아직 닫지 마세요.", "Keep the lid open for now.")
      tone = .progress
    case .releasing:
      statusIndicator = "!"
      summary = L("정상 수면 복구 중, 덮개 닫기 금지", "Restoring sleep; keep lid open")
      headline = L("정상 수면 복구 중", "Restoring normal sleep")
      guidance = L("덮개를 닫지 마세요.", "Keep the lid open.")
      tone = .attention
    case .recoveryPending:
      statusIndicator = "!"
      summary = L("정상 수면 복구 재시도 중, 덮개 닫기 금지", "Retrying sleep recovery; keep lid open")
      headline = L("정상 수면 복구 재시도 중", "Retrying sleep recovery")
      guidance = L("덮개를 닫지 마세요.", "Keep the lid open.")
      tone = .attention
    case .unsafe:
      statusIndicator = "!"
      summary = L("기기 안전 우선 중단, 덮개 닫기 금지", "Stopped for safety; keep lid open")
      headline = L("기기 안전 우선 중단", "Stopped for device safety")
      guidance = L("덮개를 닫지 마세요.", "Keep the lid open.")
      tone = .stopped
    case .unknown:
      statusIndicator = "?"
      summary = L("보호 상태 확인 불가, 덮개 닫기 금지", "Keep-awake unknown; keep lid open")
      headline = L("보호 상태 확인 불가", "Keep-awake status unknown")
      guidance = L("덮개를 닫지 마세요.", "Keep the lid open.")
      tone = .unknown
    case .inactive:
      statusIndicator = ""
      summary =
        status.mode == .adaptive
        ? L("작업 활동 대기 중", "Waiting for task activity") : L("실행 유지 꺼짐", "Not keeping awake")
      headline =
        status.mode == .adaptive
        ? L("작업 활동 대기 중", "Waiting for task activity") : L("실행 유지 꺼짐", "Not keeping awake")
      guidance = L("아래 메뉴에서 실행 유지 방식을 선택하세요.", "Choose how to keep awake from the menu below.")
      tone = .neutral
    }

    var statusFields: [String] = []
    if let remaining = status.remainingSeconds {
      statusFields.append(
        L("남은 시간 \(Self.duration(remaining))", "\(Self.duration(remaining)) remaining"))
    }
    if let battery = status.batteryPercent {
      statusFields.append(L("배터리 \(battery)%", "Battery \(battery)%"))
    }
    if let thermal = status.thermalLevel {
      statusFields.append(
        L(
          "macOS 열 압력: \(Self.thermal(thermal))", "macOS thermal pressure: \(Self.thermal(thermal))"
        ))
    }
    statusFields.append(
      contentsOf: SupervisorDiagnostics.temperatureSummaryFields(
        status.temperatureTelemetry,
        now: now
      )
    )

    var detailLines = [statusFields.joined(separator: " | ")]
    if let detail = Self.supplementalDetail(InterfaceStatusText.detail(status)) {
      detailLines.append(detail)
    }
    if let issues = status.observation?.issues, !issues.isEmpty {
      detailLines.append(
        L("일부 기록을 저장하지 못했습니다. 진단 정보를 확인하세요.", "Some records could not be saved. Check Diagnostics.")
      )
    }
    self.detail = detailLines.filter { !$0.isEmpty }.joined(separator: "\n")
  }

  private static func supplementalDetail(_ value: String?) -> String? {
    guard let value else {
      return nil
    }
    let singleLine =
      value
      .split(whereSeparator: { $0.isNewline })
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !singleLine.isEmpty else {
      return nil
    }
    guard singleLine.count > supplementalDetailCharacterLimit else {
      return singleLine
    }
    return String(singleLine.prefix(supplementalDetailCharacterLimit)) + "…"
  }

  private static func mode(_ mode: WireSessionMode) -> String {
    switch mode {
    case .trip: L("이동 모드", "Travel")
    case .adaptive: L("작업 자동 모드", "Task activity")
    case .desk: L("시간 지정 모드", "Timed")
    case .none: "Runtinue"
    }
  }

  private static func thermal(_ level: String) -> String {
    switch level {
    case "nominal": L("제한 신호 없음", "No restriction reported")
    case "fair": L("약간 상승", "Elevated")
    case "serious": L("높음", "High")
    case "critical": L("매우 높음", "Critical")
    case "unknown": L("확인 불가", "Unavailable")
    default: level
    }
  }

  private static func duration(_ seconds: Double) -> String {
    let totalMinutes = max(0, Int(seconds) / 60)
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60
    return hours > 0
      ? L("\(hours)시간 \(minutes)분", "\(hours)h \(minutes)m") : L("\(minutes)분", "\(minutes)m")
  }
}

private func parseMinutes(
  _ rawValue: String,
  field: String,
  maximum: Double
) throws -> Double {
  let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
  guard
    !normalized.isEmpty,
    normalized.utf8.allSatisfy({ (48...57).contains($0) }),
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
