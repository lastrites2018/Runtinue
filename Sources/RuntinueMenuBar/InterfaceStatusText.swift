import Foundation
import RuntinueIPC
import RuntinueUserSupport

enum InterfaceStatusText {
  static func mode(_ mode: WireSessionMode) -> String {
    switch mode {
    case .trip: L("이동 모드", "Travel")
    case .adaptive: L("작업 자동 모드", "Task activity")
    case .desk: L("시간 지정 모드", "Timed")
    case .none: L("꺼짐", "Off")
    }
  }

  static func value(_ value: String) -> String {
    switch value {
    case "protected": L("실행 유지 중", "Keeping awake")
    case "inactive": L("꺼짐", "Off")
    case "waitingForHotspot": L("연결 대기 중", "Waiting for connection")
    case "acquiring": L("실행 유지 확인 중", "Verifying keep-awake")
    case "releasing": L("수면 허용 중", "Allowing sleep")
    case "recoveryPending": L("수면 복구 재시도 중", "Retrying sleep recovery")
    case "unsafe", "safety": L("시스템 보호 기준에 따라 중단", "Stopped by system safety policy")
    case "unknown": L("확인 불가", "Unavailable")
    case "userRequested": L("사용자가 중단함", "Stopped by user")
    case "hardDeadlineReached": L("설정한 시간이 끝남", "Time limit reached")
    case "hotspotHandoffTimedOut": L("연결 대기 시간 초과", "Connection wait expired")
    case "leaseRejected": L("실행 유지 요청 거부됨", "Keep-awake request rejected")
    case "leaseRecoveryPending": L("수면 복구 확인 대기", "Sleep recovery pending")
    case "superseded": L("새 요청으로 교체됨", "Replaced by a new request")
    case "open": L("열림", "Open")
    case "closed": L("닫힘", "Closed")
    case "connected", "present": L("연결됨", "Connected")
    case "disconnected", "absent": L("연결 안 됨", "Disconnected")
    case "reachable": L("연결 확인됨", "Reachable")
    case "unreachable": L("연결할 수 없음", "Unreachable")
    case "nominal": L("제한 신호 없음", "No restriction reported")
    case "fair": L("약간 상승", "Elevated")
    case "serious": L("높음", "High")
    case "critical": L("매우 높음", "Critical")
    case "battery": L("배터리 사용", "On battery")
    case "acCharging": L("외부 전원, 충전 중", "External power, charging")
    case "acNotCharging": L("외부 전원, 충전 안 함", "External power, not charging")
    case "confirmed": L("연결 확인됨", "Connection verified")
    case "unavailable": L("연결 확인 실패", "Connection check failed")
    case "unchecked": L("확인하지 않음", "Not checked")
    default: value
    }
  }

  static func detail(_ status: SupervisorStatusWire) -> String? {
    if let reason = status.stopReason { return value(reason.rawValue) }
    guard let detail = status.detail else { return nil }
    if detail == "adaptive mode is waiting for activity" {
      return L("연동한 작업 도구에서 활동 신호를 기다립니다.", "Waiting for activity from an integrated tool.")
    }
    let prefix = "adaptive activity source="
    if detail.hasPrefix(prefix) {
      let parts = String(detail.dropFirst(prefix.count)).components(separatedBy: ", session=")
      let source = parts[0]
      let session =
        parts.count > 1
        ? L(
          ", 작업: \(parts.dropFirst().joined(separator: ", session="))",
          ", session: \(parts.dropFirst().joined(separator: ", session="))") : ""
      return L("활동 도구: \(source)\(session)", "Activity tool: \(source)\(session)")
    }
    // Technical free-form errors remain available in Diagnostics.
    return L(
      "서비스의 추가 상태 정보가 있습니다. 진단 정보를 확인하세요.",
      "Additional service details are available in Diagnostics.")
  }

  static func rejection(_ reason: String) -> String {
    switch reason {
    case "modeConflict":
      L(
        "다른 실행 유지 모드가 켜져 있습니다. 현재 모드를 중단한 뒤 다시 시작하세요.",
        "Another keep-awake mode is active. Stop it before starting a new mode.")
    case "startupRecoveryPending":
      L(
        "이전 실행의 수면 설정을 복구하고 있습니다. 덮개를 열어 두고 복구가 끝난 뒤 다시 시작하세요.",
        "Restoring sleep settings from a previous run. Keep the lid open and wait for recovery before starting."
      )
    case "sessionMismatch", "sessionNotRunning", "adaptiveNotEnabled", "deskNotEnabled",
      "adaptiveSessionUnavailable":
      L(
        "실행 상태가 바뀌었습니다. 새로 고침한 뒤 다시 시도하세요.",
        "The running mode has changed. Refresh and try again.")
    case "invalidAdaptiveConfiguration", "invalidDeskConfiguration":
      L(
        "시간 설정을 적용하지 못했습니다. 입력 범위를 확인하세요.",
        "Could not apply the time settings. Check the allowed range.")
    default:
      L(
        "현재 상태에서 요청을 적용하지 못했습니다. 덮개를 열어 두고 진단 정보를 확인하세요.",
        "Could not apply the request in the current state. Keep the lid open and check Diagnostics."
      )
    }
  }
}
