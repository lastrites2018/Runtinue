public struct DeviceSafetyTracker: Sendable {
  public let policy: DeviceSafetyPolicy
  public let batteryFailureLimit: Int
  public let thermalUnavailableGrace: Duration

  private var consecutiveBatteryFailures = 0
  private var thermalUnavailableSince: MonotonicInstant?
  private var lastCountedBatterySnapshot: MonotonicInstant?
  private var lastChargingBatterySample: (time: MonotonicInstant, percent: Int)?
  private var chargingDropCandidate: (time: MonotonicInstant, percent: Int)?
  private var batteryDepletingOnAC = false

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
      resetChargingTrend()
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
        resetChargingTrend()
      }
      if let previous = lastChargingBatterySample, snapshot.capturedAt > previous.time {
        updateChargingTrend(
          percent: percent,
          at: snapshot.capturedAt,
          previous: previous
        )
      }
      if lastChargingBatterySample.map({ snapshot.capturedAt > $0.time }) ?? true {
        lastChargingBatterySample = (snapshot.capturedAt, percent)
      }
    } else {
      resetChargingTrend()
    }
    return policy.evaluate(
      snapshot,
      at: now,
      batteryDepletingOnAC: batteryDepletingOnAC
    )
  }

  private mutating func updateChargingTrend(
    percent: Int,
    at time: MonotonicInstant,
    previous: (time: MonotonicInstant, percent: Int)
  ) {
    if batteryDepletingOnAC {
      if percent > previous.percent {
        chargingDropCandidate = nil
        batteryDepletingOnAC = false
      }
      return
    }

    if let candidate = chargingDropCandidate {
      if percent > candidate.percent {
        chargingDropCandidate = nil
      } else if time > candidate.time {
        batteryDepletingOnAC = true
      }
      return
    }

    if percent < previous.percent {
      chargingDropCandidate = (time, percent)
    }
  }

  private mutating func resetChargingTrend() {
    lastChargingBatterySample = nil
    chargingDropCandidate = nil
    batteryDepletingOnAC = false
  }
}
