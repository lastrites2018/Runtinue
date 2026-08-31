import SafeClamIPC

public enum SupervisorDiagnostics {
  public static func observationLines(_ observation: WireObservationStatus?) -> [String] {
    guard let observation else {
      return ["관찰 상태: 설치된 Supervisor가 빌드와 이벤트 기록 상태를 제공하지 않습니다."]
    }
    var lines = ["Supervisor 빌드 SHA-256: \(observation.buildID ?? "확인 불가")"]
    if observation.issues.isEmpty {
      lines.append("관찰 기록: 현재 프로세스에서 기록 실패를 감지하지 않음")
    }
    for issue in observation.issues {
      switch issue {
      case .buildIdentityUnavailable:
        lines.append("경고: Supervisor 빌드를 식별하지 못했습니다.")
      case .eventsUnavailable:
        lines.append("경고: 이벤트 기록에 실패했습니다. 이후 기록 성공으로 누락이 복구되지는 않습니다.")
      case .historyUnavailable:
        lines.append("경고: 상태 기록을 저장하지 못했습니다.")
      case .statusCacheUnavailable:
        lines.append("경고: 상태 캐시를 저장하지 못했습니다. 실시간 상태를 확인하세요.")
      }
    }
    return lines
  }

  public static func sleepOverrideWarning(
    isSleepDisabled: Bool,
    status: SupervisorStatusWire?
  ) -> String? {
    guard isSleepDisabled else {
      return nil
    }

    guard let status else {
      return "경고: Supervisor에 연결할 수 없고 SleepDisabled가 켜져 있습니다."
    }

    switch status.verdict {
    case .protected, .releasing, .recoveryPending:
      return nil
    case .inactive, .waitingForHotspot, .acquiring, .unsafe, .unknown:
      return "경고: SleepDisabled가 켜져 있지만 Supervisor가 보호 또는 복구 상태를 확인하지 못했습니다."
    }
  }
}
