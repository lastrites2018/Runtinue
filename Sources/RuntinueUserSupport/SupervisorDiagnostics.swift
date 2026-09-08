import Foundation
import RuntinueIPC

public enum SupervisorDiagnostics {
  public static func observationLines(_ observation: WireObservationStatus?) -> [String] {
    guard let observation else {
      return [
        L(
          "관찰 상태: 설치된 Supervisor가 빌드와 이벤트 기록 상태를 제공하지 않습니다.",
          "Observation: the installed service does not provide build or event-record status.")
      ]
    }
    var lines = [
      L(
        "Supervisor 빌드 SHA-256: \(observation.buildID ?? "확인 불가")",
        "Service build SHA-256: \(observation.buildID ?? L("확인 불가", "Unavailable"))")
    ]
    if observation.issues.isEmpty {
      lines.append(
        L("관찰 기록: 현재 프로세스에서 기록 실패를 감지하지 않음", "Records: no write failures detected in this process"))
    }
    for issue in observation.issues {
      switch issue {
      case .buildIdentityUnavailable:
        lines.append(
          L("경고: Supervisor 빌드를 식별하지 못했습니다.", "Warning: could not identify the service build."))
      case .eventsUnavailable:
        lines.append(
          L(
            "경고: 이벤트 기록에 실패했습니다. 이후 기록 성공으로 누락이 복구되지는 않습니다.",
            "Warning: an event could not be saved. Later successful writes do not restore missing events."
          ))
      case .historyUnavailable:
        lines.append(L("경고: 상태 기록을 저장하지 못했습니다.", "Warning: could not save status history."))
      case .statusCacheUnavailable:
        lines.append(
          L(
            "경고: 상태 캐시를 저장하지 못했습니다. 실시간 상태를 확인하세요.",
            "Warning: could not save cached status. Check the live status."))
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
      return L(
        "경고: Supervisor에 연결할 수 없고 SleepDisabled가 켜져 있습니다.",
        "Warning: the service is unreachable and system sleep is inhibited.")
    }

    switch status.verdict {
    case .protected, .releasing, .recoveryPending:
      return nil
    case .inactive, .waitingForHotspot, .acquiring, .unsafe, .unknown:
      return L(
        "경고: SleepDisabled가 켜져 있지만 Supervisor가 보호 또는 복구 상태를 확인하지 못했습니다.",
        "Warning: system sleep is inhibited and the service cannot confirm keep-awake or recovery status."
      )
    }
  }

  public static func temperatureSummaryFields(
    _ telemetry: WireTemperatureTelemetry?,
    now: Date = Date()
  ) -> [String] {
    guard let telemetry else {
      return [
        L("직접 온도: 설치된 Supervisor에서 지원하지 않음", "Temperature: unavailable from the installed service")
      ]
    }
    switch telemetry.status {
    case .unsupportedModel:
      return [L("직접 온도: 이 모델에서 아직 검증되지 않음", "Temperature: not yet verified on this model")]
    case .mappingUnverified:
      return [
        L("직접 온도: 이 모델의 센서 매핑이 검증되지 않음", "Temperature: sensor mapping not verified for this system")
      ]
    case .temporarilyUnavailable:
      return [L("직접 온도: 현재 읽을 수 없음", "Temperature: currently unavailable")]
    case .available, .partial:
      guard let validUntil = telemetry.validUntil, now <= validUntil else {
        return [L("직접 온도: 최신 측정 없음", "Temperature: no recent reading")]
      }
      let components = telemetry.components.compactMap { observation in
        summaryComponent(
          observation,
          includeCoverage: telemetry.status == .partial
        )
      }
      guard !components.isEmpty else {
        return [L("직접 온도: 현재 읽을 수 없음", "Temperature: currently unavailable")]
      }
      let partial = telemetry.status == .partial ? L(" (부분 측정)", " (partial reading)") : ""
      return [
        L(
          "내부 센서 최고: \(components.joined(separator: ", "))\(partial)",
          "Highest internal sensor: \(components.joined(separator: ", "))\(partial)")
      ]
    }
  }

  public static func temperatureDiagnosticLines(
    _ telemetry: WireTemperatureTelemetry?,
    now: Date = Date()
  ) -> [String] {
    var lines = [L("직접 내부 온도", "Internal temperature readings")]
    lines.append(contentsOf: temperatureSummaryFields(telemetry, now: now))
    guard let telemetry else {
      lines.append(
        L("외장 표면 온도: 소프트웨어로 측정하지 않음", "Case surface temperature: not measured by software"))
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
          L(
            "\(name) 센서 범위: \(celsius(minimum))–\(celsius(maximum)), ",
            "\(name) sensor range: \(celsius(minimum))–\(celsius(maximum)), ")
            + L(
              "유효 \(observation.validSensorCount)/\(observation.expectedSensorCount)",
              "valid \(observation.validSensorCount)/\(observation.expectedSensorCount)")
        )
        if !observation.validSensorIDs.isEmpty {
          lines.append(
            L(
              "\(name) 유효 센서: \(observation.validSensorIDs.joined(separator: ", "))",
              "\(name) valid sensors: \(observation.validSensorIDs.joined(separator: ", "))"))
        }
      }
      lines.append(
        L(
          "측정: \(ageDescription(telemetry.sampledAt, now: now))",
          "Sampled: \(ageDescription(telemetry.sampledAt, now: now))"))
    } else if let lastSuccessfulAt = telemetry.lastSuccessfulAt {
      lines.append(
        L(
          "마지막 성공 측정: \(ageDescription(lastSuccessfulAt, now: now))",
          "Last successful reading: \(ageDescription(lastSuccessfulAt, now: now))"))
    }

    var provenance: [String] = [L("소스 AppleSMC", "Source AppleSMC")]
    if let machineModel = telemetry.machineModel {
      provenance.append(L("모델 \(machineModel)", "Model \(machineModel)"))
    }
    if let operatingSystemBuild = telemetry.operatingSystemBuild {
      provenance.append(
        L("macOS 빌드 \(operatingSystemBuild)", "macOS build \(operatingSystemBuild)"))
    }
    if let mappingRevision = telemetry.mappingRevision {
      provenance.append(L("매핑 \(mappingRevision)", "Mapping \(mappingRevision)"))
    }
    lines.append(
      L(
        "관측 출처: \(provenance.joined(separator: ", "))",
        "Provenance: \(provenance.joined(separator: ", "))"))
    if telemetry.mappingQuality == .singleDeviceValidated {
      lines.append(L("매핑 검증: 동일 모델 실기기 1대", "Mapping verified on one device of this model"))
    }
    if let interval = telemetry.samplingIntervalSeconds,
      interval.isFinite,
      interval > 0
    {
      lines.append(
        L(
          "예상 갱신 주기: \(Int(interval.rounded()))초",
          "Expected update interval: \(Int(interval.rounded())) seconds"))
    }
    lines.append(
      L("외장 표면 온도: 소프트웨어로 측정하지 않음", "Case surface temperature: not measured by software"))
    return lines
  }

  private static func summaryComponent(
    _ observation: WireTemperatureComponentObservation,
    includeCoverage: Bool
  ) -> String? {
    guard let maximum = validCelsius(observation.maximumCelsius) else {
      return nil
    }
    let coverage =
      includeCoverage
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
      return L("\(seconds)초 전", "\(seconds) seconds ago")
    }
    let minutes = seconds / 60
    if minutes < 60 {
      return L("\(minutes)분 전", "\(minutes) minutes ago")
    }
    return L("\(minutes / 60)시간 전", "\(minutes / 60) hours ago")
  }
}
