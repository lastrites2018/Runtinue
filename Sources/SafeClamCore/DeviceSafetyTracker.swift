public struct DeviceSafetyTracker: Sendable {
  public let policy: DeviceSafetyPolicy
  public let batteryFailureLimit: Int
  public let thermalUnavailableGrace: Duration

  private var consecutiveBatteryFailures = 0
  private var thermalUnavailableSince: MonotonicInstant?
  private var lastCountedBatterySnapshot: MonotonicInstant?

  public init(
    policy: DeviceSafetyPolicy = DeviceSafetyPolicy(),
    batteryFailureLimit: Int = 3,
    thermalUnavailableGrace: Duration = .seconds(30)
  ) {
    self.policy = policy
    self.batteryFailureLimit = max(1, batteryFailureLimit)
    self.thermalUnavailableGrace = max(.zero, thermalUnavailableGrace)
  }

  public mutating func evaluate(
    _ snapshot: DeviceSafetySnapshot,
    at now: MonotonicInstant
  ) -> DeviceSafetyVerdict {
    guard let age = now.durationSince(snapshot.capturedAt) else {
      return .stop(.snapshotFromFuture)
    }
    let effectiveLidClosed = snapshot.lidState != .open
    let maximumAge =
      effectiveLidClosed
      ? policy.closedMaximumSnapshotAge
      : policy.maximumSnapshotAge
    guard age <= maximumAge else {
      return .stop(.staleSnapshot(age: age))
    }

    let batteryIsRequired: Bool
    switch snapshot.powerConnection {
    case .ac:
      batteryIsRequired = false
    case .battery:
      batteryIsRequired = true
    case .unknown:
      batteryIsRequired = effectiveLidClosed
    }

    if batteryIsRequired, snapshot.batteryPercent == nil {
      if lastCountedBatterySnapshot != snapshot.capturedAt {
        consecutiveBatteryFailures += 1
        lastCountedBatterySnapshot = snapshot.capturedAt
      }
    } else {
      consecutiveBatteryFailures = 0
      lastCountedBatterySnapshot = nil
    }

    if snapshot.thermalLevel == .unknown {
      if thermalUnavailableSince == nil {
        thermalUnavailableSince = now
      }
    } else {
      thermalUnavailableSince = nil
    }

    if consecutiveBatteryFailures >= batteryFailureLimit {
      return .stop(.batteryUnavailable)
    }

    if let thermalUnavailableSince,
      let elapsed = now.durationSince(thermalUnavailableSince)
    {
      if elapsed >= thermalUnavailableGrace {
        return .stop(.thermalUnavailable)
      }
      return .uncertain(
        .thermalUnavailable(
          graceRemaining: thermalUnavailableGrace - elapsed
        )
      )
    }

    if batteryIsRequired, snapshot.batteryPercent == nil {
      return .uncertain(
        .batteryUnavailable(
          consecutiveFailures: consecutiveBatteryFailures,
          releaseAfter: batteryFailureLimit
        )
      )
    }

    return policy.evaluate(snapshot, at: now)
  }
}
