public struct DeviceSafetyTracker: Sendable {
  public let policy: DeviceSafetyPolicy
  public let batteryFailureLimit: Int
  public let thermalUnavailableGrace: Duration

  private var consecutiveBatteryFailures = 0
  private var thermalUnavailableSince: MonotonicInstant?
  private var lastCountedBatterySnapshot: MonotonicInstant?
  private var lastChargingBatterySample: (time: MonotonicInstant, percent: Int)?
  private var consecutiveChargingDecreases = 0

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

    let batteryUnavailable = snapshot.batteryPercent.map { !(0...100).contains($0) } ?? true
    if batteryUnavailable {
      lastChargingBatterySample = nil
      consecutiveChargingDecreases = 0
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

    if batteryUnavailable {
      return .uncertain(
        .batteryUnavailable(
          consecutiveFailures: consecutiveBatteryFailures,
          releaseAfter: batteryFailureLimit
        )
      )
    }

    if snapshot.powerConnection == .acCharging, let percent = snapshot.batteryPercent {
      if let previous = lastChargingBatterySample,
        let elapsed = snapshot.capturedAt.durationSince(previous.time), elapsed > maximumAge
      {
        lastChargingBatterySample = nil
        consecutiveChargingDecreases = 0
      }
      if let previous = lastChargingBatterySample, snapshot.capturedAt > previous.time {
        if percent < previous.percent {
          consecutiveChargingDecreases = min(2, consecutiveChargingDecreases + 1)
        } else if percent > previous.percent {
          consecutiveChargingDecreases = 0
        }
      }
      if lastChargingBatterySample.map({ snapshot.capturedAt > $0.time }) ?? true {
        lastChargingBatterySample = (snapshot.capturedAt, percent)
      }
    } else {
      lastChargingBatterySample = nil
      consecutiveChargingDecreases = 0
    }
    return policy.evaluate(
      snapshot, at: now, batteryDepletingOnAC: consecutiveChargingDecreases >= 2
    )
  }
}
