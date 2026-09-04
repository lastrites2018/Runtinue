public struct DeviceSafetyTracker: Sendable {
  public let policy: DeviceSafetyPolicy
  public let batteryFailureLimit: Int
  public let thermalUnavailableGrace: Duration

  private var consecutiveBatteryFailures = 0
  private var thermalUnavailableSince: MonotonicInstant?
  private var lastCountedBatterySnapshot: MonotonicInstant?
  private var lastChargingTrendObservation: MonotonicInstant?
  private var lastChargingBatterySample: (time: MonotonicInstant, percent: Int)?
  private var chargingDropCandidate: (time: MonotonicInstant, percent: Int)?
  private var persistentChargingDropOnAC = false

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
      if lastCountedBatterySnapshot != snapshot.capturedAt {
        consecutiveBatteryFailures += 1
        lastCountedBatterySnapshot = snapshot.capturedAt
      }
    } else {
      consecutiveBatteryFailures = 0
      lastCountedBatterySnapshot = nil
    }

    observeChargingTrend(
      snapshot,
      batteryUnavailable: batteryUnavailable,
      maximumAge: maximumAge
    )

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

    return policy.evaluate(
      snapshot,
      at: now,
      persistentChargingDropOnAC: persistentChargingDropOnAC
    )
  }

  private mutating func observeChargingTrend(
    _ snapshot: DeviceSafetySnapshot,
    batteryUnavailable: Bool,
    maximumAge: Duration
  ) {
    guard lastChargingTrendObservation.map({ snapshot.capturedAt > $0 }) ?? true else {
      return
    }
    lastChargingTrendObservation = snapshot.capturedAt
    guard snapshot.powerConnection == .acCharging else {
      resetChargingTrend()
      return
    }
    guard !batteryUnavailable, let percent = snapshot.batteryPercent else {
      resetChargingComparison()
      return
    }

    if let previous = lastChargingBatterySample,
      let elapsed = snapshot.capturedAt.durationSince(previous.time), elapsed > maximumAge
    {
      resetChargingTrend()
    }
    if let previous = lastChargingBatterySample {
      updateChargingTrend(
        percent: percent,
        at: snapshot.capturedAt,
        previous: previous
      )
    }
    lastChargingBatterySample = (snapshot.capturedAt, percent)
  }

  private mutating func updateChargingTrend(
    percent: Int,
    at time: MonotonicInstant,
    previous: (time: MonotonicInstant, percent: Int)
  ) {
    if persistentChargingDropOnAC {
      if percent > previous.percent {
        chargingDropCandidate = nil
        persistentChargingDropOnAC = false
      }
      return
    }

    if let candidate = chargingDropCandidate {
      if percent > candidate.percent {
        chargingDropCandidate = nil
      } else if time > candidate.time {
        // capturedAt proves a later app observation, not a fresh fuel-gauge
        // measurement. Treat persistence conservatively without claiming cause.
        persistentChargingDropOnAC = true
      }
      return
    }

    if percent < previous.percent {
      chargingDropCandidate = (time, percent)
    }
  }

  private mutating func resetChargingTrend() {
    resetChargingComparison()
    persistentChargingDropOnAC = false
  }

  private mutating func resetChargingComparison() {
    lastChargingBatterySample = nil
    chargingDropCandidate = nil
  }
}
