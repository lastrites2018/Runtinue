import Foundation

public enum DeviceSafetyStopReason: Equatable, Sendable {
  case snapshotFromFuture
  case staleSnapshot(age: Duration)
  case thermalUnavailable
  case thermalLimitReached(observed: ThermalLevel, cutoff: ThermalLevel)
  case batteryUnavailable
  case batteryBelowFloor(observed: Int, floor: Int)
  case lidClosedWithoutPermission
}

public enum DeviceSafetyVerdict: Equatable, Sendable {
  case safe
  case uncertain(DeviceSafetyUncertainty)
  case stop(DeviceSafetyStopReason)
}

public enum DeviceSafetyUncertainty: Equatable, Sendable {
  case thermalUnavailable(graceRemaining: Duration)
  case batteryUnavailable(consecutiveFailures: Int, releaseAfter: Int)
}

public struct DeviceSafetyPolicy: Equatable, Sendable {
  public static let safestMaximumSnapshotAge: Duration = .seconds(30)
  public static let safestClosedMaximumSnapshotAge: Duration = .seconds(60)
  public static let minimumClosedWithoutDisplayBatteryFloor = 30
  public static let minimumClosedWithDisplayBatteryFloor = 15
  public static let minimumOpenBatteryFloor = 10
  public static let minimumLowPowerModeBatteryPenalty = 10

  public let maximumSnapshotAge: Duration
  public let closedMaximumSnapshotAge: Duration
  public let closedWithoutDisplayBatteryFloor: Int
  public let closedWithDisplayBatteryFloor: Int
  public let openBatteryFloor: Int
  public let lowPowerModeBatteryPenalty: Int
  public let closedWithoutDisplayThermalCutoff: ThermalLevel
  public let otherThermalCutoff: ThermalLevel

  public init(
    maximumSnapshotAge: Duration = .seconds(30),
    closedMaximumSnapshotAge: Duration = .seconds(60),
    closedWithoutDisplayBatteryFloor: Int = 30,
    closedWithDisplayBatteryFloor: Int = 15,
    openBatteryFloor: Int = 10,
    lowPowerModeBatteryPenalty: Int = 10,
    closedWithoutDisplayThermalCutoff: ThermalLevel = .fair,
    otherThermalCutoff: ThermalLevel = .serious
  ) {
    self.maximumSnapshotAge = min(maximumSnapshotAge, Self.safestMaximumSnapshotAge)
    self.closedMaximumSnapshotAge = min(
      closedMaximumSnapshotAge,
      Self.safestClosedMaximumSnapshotAge
    )
    self.closedWithoutDisplayBatteryFloor = min(
      100,
      max(
        Self.minimumClosedWithoutDisplayBatteryFloor,
        closedWithoutDisplayBatteryFloor
      )
    )
    self.closedWithDisplayBatteryFloor = min(
      100,
      max(
        Self.minimumClosedWithDisplayBatteryFloor,
        closedWithDisplayBatteryFloor
      )
    )
    self.openBatteryFloor = min(
      100,
      max(Self.minimumOpenBatteryFloor, openBatteryFloor)
    )
    self.lowPowerModeBatteryPenalty = min(
      100,
      max(Self.minimumLowPowerModeBatteryPenalty, lowPowerModeBatteryPenalty)
    )
    self.closedWithoutDisplayThermalCutoff = Self.clampThermalCutoff(
      closedWithoutDisplayThermalCutoff,
      noLessStrictThan: .fair
    )
    self.otherThermalCutoff = Self.clampThermalCutoff(
      otherThermalCutoff,
      noLessStrictThan: .serious
    )
  }

  public func evaluate(
    _ snapshot: DeviceSafetySnapshot,
    at now: MonotonicInstant,
    batteryDepletingOnAC: Bool = false
  ) -> DeviceSafetyVerdict {
    guard let age = now.durationSince(snapshot.capturedAt) else {
      return .stop(.snapshotFromFuture)
    }
    let effectiveLidClosed = snapshot.lidState != .open
    let maximumAge = effectiveLidClosed ? closedMaximumSnapshotAge : maximumSnapshotAge
    guard age <= maximumAge else {
      return .stop(.staleSnapshot(age: age))
    }

    let effectiveExternalDisplayPresent = snapshot.externalDisplayState == .present
    var thermalCutoff =
      effectiveLidClosed && !effectiveExternalDisplayPresent
      ? closedWithoutDisplayThermalCutoff
      : otherThermalCutoff
    if snapshot.lowPowerModeEnabled {
      thermalCutoff = Self.oneStepStricter(than: thermalCutoff)
    }

    guard
      let observedThermalSeverity = snapshot.thermalLevel.severity,
      let cutoffThermalSeverity = thermalCutoff.severity
    else {
      return .stop(.thermalUnavailable)
    }
    guard observedThermalSeverity < cutoffThermalSeverity else {
      return .stop(
        .thermalLimitReached(
          observed: snapshot.thermalLevel,
          cutoff: thermalCutoff
        )
      )
    }

    guard let batteryPercent = snapshot.batteryPercent, (0...100).contains(batteryPercent) else {
      return .stop(.batteryUnavailable)
    }

    let baseFloor: Int
    if snapshot.powerConnection == .acCharging, !batteryDepletingOnAC {
      baseFloor = Self.minimumOpenBatteryFloor
    } else if effectiveLidClosed {
      baseFloor =
        effectiveExternalDisplayPresent
        ? closedWithDisplayBatteryFloor
        : closedWithoutDisplayBatteryFloor
    } else {
      baseFloor = openBatteryFloor
    }
    let floor = min(
      100,
      baseFloor + (snapshot.lowPowerModeEnabled ? lowPowerModeBatteryPenalty : 0)
    )

    guard batteryPercent >= floor else {
      return .stop(.batteryBelowFloor(observed: batteryPercent, floor: floor))
    }
    return .safe
  }

  private static func clampThermalCutoff(
    _ requested: ThermalLevel,
    noLessStrictThan safeMaximum: ThermalLevel
  ) -> ThermalLevel {
    guard let requestedSeverity = requested.severity,
      let maximumSeverity = safeMaximum.severity,
      requestedSeverity <= maximumSeverity
    else {
      return safeMaximum
    }
    return requested
  }

  private static func oneStepStricter(than cutoff: ThermalLevel) -> ThermalLevel {
    switch cutoff {
    case .critical:
      .serious
    case .serious:
      .fair
    case .fair, .nominal, .unknown:
      cutoff == .unknown ? .fair : cutoff
    }
  }
}
