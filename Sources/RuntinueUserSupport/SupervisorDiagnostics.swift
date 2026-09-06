import Foundation
import RuntinueIPC

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

  public static func temperatureSummaryFields(
    _ telemetry: WireTemperatureTelemetry?,
    now: Date = Date()
  ) -> [String] {
    guard let telemetry else {
      return ["직접 온도: 설치된 Supervisor에서 지원하지 않음"]
    }
    switch telemetry.status {
    case .unsupportedModel:
      return ["직접 온도: 이 모델에서 아직 검증되지 않음"]
    case .mappingUnverified:
      return ["직접 온도: 이 모델의 센서 매핑이 검증되지 않음"]
    case .temporarilyUnavailable:
      return ["직접 온도: 현재 읽을 수 없음"]
    case .available, .partial:
      guard let validUntil = telemetry.validUntil, now <= validUntil else {
        return ["직접 온도: 최신 측정 없음"]
      }
      let components = telemetry.components.compactMap { observation in
        summaryComponent(
          observation,
          includeCoverage: telemetry.status == .partial
        )
      }
      guard !components.isEmpty else {
        return ["직접 온도: 현재 읽을 수 없음"]
      }
      let partial = telemetry.status == .partial ? " (부분 측정)" : ""
      return ["내부 센서 최고: \(components.joined(separator: ", "))\(partial)"]
    }
  }

  public static func temperatureDiagnosticLines(
    _ telemetry: WireTemperatureTelemetry?,
    now: Date = Date()
  ) -> [String] {
    var lines = ["직접 내부 온도"]
    lines.append(contentsOf: temperatureSummaryFields(telemetry, now: now))
    guard let telemetry else {
      lines.append("외장 표면 온도: 소프트웨어로 측정하지 않음")
      return lines
    }

    let isFresh = telemetry.validUntil.map { now <= $0 } ?? false
    if isFresh && (telemetry.status == .available || telemetry.status == .partial) {
      for observation in telemetry.components {
        guard
          let minimum = validCelsius(observation.minimumCelsius),
          let maximum = validCelsius(observation.maximumCelsius)
        else {
          continue
        }
        let name = componentName(observation.component)
        lines.append(
          "\(name) 센서 범위: \(celsius(minimum))–\(celsius(maximum)), "
            + "유효 \(observation.validSensorCount)/\(observation.expectedSensorCount)"
        )
        if !observation.validSensorIDs.isEmpty {
          lines.append("\(name) 유효 센서: \(observation.validSensorIDs.joined(separator: ", "))")
        }
      }
      lines.append("측정: \(ageDescription(telemetry.sampledAt, now: now))")
    } else if let lastSuccessfulAt = telemetry.lastSuccessfulAt {
      lines.append("마지막 성공 측정: \(ageDescription(lastSuccessfulAt, now: now))")
    }

    var provenance: [String] = ["소스 AppleSMC"]
    if let machineModel = telemetry.machineModel {
      provenance.append("모델 \(machineModel)")
    }
    if let operatingSystemBuild = telemetry.operatingSystemBuild {
      provenance.append("macOS 빌드 \(operatingSystemBuild)")
    }
    if let mappingRevision = telemetry.mappingRevision {
      provenance.append("매핑 \(mappingRevision)")
    }
    lines.append("관측 출처: \(provenance.joined(separator: ", "))")
    if telemetry.mappingQuality == .singleDeviceValidated {
      lines.append("매핑 검증: 동일 모델 실기기 1대")
    }
    if let interval = telemetry.samplingIntervalSeconds,
      interval.isFinite,
      interval > 0
    {
      lines.append("예상 갱신 주기: \(Int(interval.rounded()))초")
    }
    lines.append("외장 표면 온도: 소프트웨어로 측정하지 않음")
    return lines
  }

  private static func summaryComponent(
    _ observation: WireTemperatureComponentObservation,
    includeCoverage: Bool
  ) -> String? {
    guard let maximum = validCelsius(observation.maximumCelsius) else {
      return nil
    }
    let coverage = includeCoverage
      ? " (\(observation.validSensorCount)/\(observation.expectedSensorCount))"
      : ""
    return "\(componentName(observation.component)) \(celsius(maximum))\(coverage)"
  }

  private static func componentName(_ component: WireTemperatureComponent) -> String {
    switch component {
    case .cpuInternal:
      "CPU"
    case .gpuInternal:
      "GPU"
    }
  }

  private static func validCelsius(_ value: Double?) -> Double? {
    guard let value, value.isFinite, value > 0, value <= 150 else {
      return nil
    }
    return value
  }

  private static func celsius(_ value: Double) -> String {
    String(format: "%.1f°C", locale: Locale(identifier: "en_US_POSIX"), value)
  }

  private static func ageDescription(_ date: Date, now: Date) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(date)))
    if seconds < 60 {
      return "\(seconds)초 전"
    }
    let minutes = seconds / 60
    if minutes < 60 {
      return "\(minutes)분 전"
    }
    return "\(minutes / 60)시간 전"
  }
}
