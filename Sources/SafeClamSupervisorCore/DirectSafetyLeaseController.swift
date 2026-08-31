import Foundation
import SafeClamCore

public enum DirectSafetyLeaseError: Error, Equatable, Sendable {
  case sessionAlreadyRunning
  case invalidHardCap
  case unsafe(String)
  case acquisitionRejected(String)
}

public actor DirectSafetyLeaseController {
  private let leaseBackend: any SupervisorLeaseBackend
  private let ownerUID: UInt32
  private let clock: any MonotonicTimeSource

  private var phase: TripPhase = .idle
  private var sessionID: UUID?
  private var lease: LeaseToken?
  private var hardDeadline: MonotonicInstant?
  private var stopReason: TripStopReason?
  private var pendingStopReason: TripStopReason?
  private var latestDevice: DeviceSafetySnapshot?
  private var latestSafetyVerdict: DeviceSafetyVerdict?
  private var safetyTracker = DeviceSafetyTracker()
  private var lastHeartbeat: MonotonicInstant?
  private var lastHelperFault: String?

  public init(
    leaseBackend: any SupervisorLeaseBackend,
    ownerUID: UInt32,
    clock: any MonotonicTimeSource = SystemUptimeClock()
  ) {
    self.leaseBackend = leaseBackend
    self.ownerUID = ownerUID
    self.clock = clock
  }

  @discardableResult
  public func start(
    hardCap: Duration,
    device: DeviceSafetySnapshot,
    safetyPolicy: DeviceSafetyPolicy = DeviceSafetyPolicy()
  ) async throws -> SupervisorStatus {
    guard !isRunning else {
      throw DirectSafetyLeaseError.sessionAlreadyRunning
    }
    guard hardCap > .zero, hardCap <= CommuteTripRequest.maximumHardCap else {
      throw DirectSafetyLeaseError.invalidHardCap
    }

    var tracker = DeviceSafetyTracker(policy: safetyPolicy)
    let safetyVerdict = tracker.evaluate(device, at: clock.now())
    guard case .safe = safetyVerdict else {
      throw DirectSafetyLeaseError.unsafe(String(describing: safetyVerdict))
    }

    let newSessionID = UUID()
    phase = .acquiringLease
    sessionID = newSessionID
    lease = nil
    hardDeadline = nil
    stopReason = nil
    pendingStopReason = nil
    latestDevice = device
    latestSafetyVerdict = safetyVerdict
    safetyTracker = tracker
    lastHeartbeat = nil
    lastHelperFault = nil

    let outcome = await leaseBackend.acquire(
      sessionID: newSessionID,
      hardCap: hardCap
    )
    guard sessionID == newSessionID else {
      if case .acquired(let unexpectedLease) = outcome {
        _ = await leaseBackend.release(
          sessionID: newSessionID,
          lease: unexpectedLease,
          reason: .superseded
        )
      }
      throw DirectSafetyLeaseError.acquisitionRejected("session was superseded")
    }

    switch outcome {
    case .acquired(let acquiredLease):
      lease = acquiredLease
      hardDeadline = clock.now().adding(hardCap)
      lastHeartbeat = clock.now()
      if phase == .acquiringLease {
        phase = .active
      } else {
        let reason = pendingStopReason ?? .superseded
        phase = .active
        _ = await releaseCurrent(reason: reason)
      }
    case .rejected(let detail):
      phase = .ended
      stopReason = pendingStopReason ?? .leaseRejected(detail)
      throw DirectSafetyLeaseError.acquisitionRejected(detail)
    case .recoveryPending(let detail):
      phase = .recoveryPending
      stopReason = .leaseRecoveryPending(detail)
      return await makeStatus()
    }
    return await makeStatus()
  }

  @discardableResult
  public func observe(device: DeviceSafetySnapshot) async -> SupervisorStatus {
    latestDevice = device
    let verdict = safetyTracker.evaluate(device, at: clock.now())
    latestSafetyVerdict = verdict

    if case .stop(let reason) = verdict,
      phase == .active || phase == .acquiringLease
    {
      return await releaseCurrent(reason: .safety(reason))
    }
    if phase == .active {
      if let hardDeadline, clock.now() >= hardDeadline {
        return await releaseCurrent(reason: .hardDeadlineReached)
      }
      if heartbeatIsDue() {
        await performHeartbeat()
      }
    }
    return await makeStatus()
  }

  @discardableResult
  public func heartbeat() async -> SupervisorStatus {
    await performHeartbeat()
    return await makeStatus()
  }

  @discardableResult
  public func stop(
    reason: TripStopReason = .userRequested
  ) async -> SupervisorStatus {
    await releaseCurrent(reason: reason)
  }

  public func status() async -> SupervisorStatus {
    await makeStatus()
  }

  @discardableResult
  public func reconcileRecovery() async -> SupervisorStatus {
    guard phase == .recoveryPending else {
      return await makeStatus()
    }
    if case .available(let helper) = await leaseBackend.liveStatus(),
      helper.phase == .idle,
      helper.sleepOverride == .normal
    {
      phase = .ended
      lease = nil
      stopReason = pendingStopReason ?? .userRequested
      lastHelperFault = nil
    }
    return await makeStatus()
  }

  private func releaseCurrent(reason: TripStopReason) async -> SupervisorStatus {
    switch phase {
    case .acquiringLease:
      phase = .releasingLease
      pendingStopReason = reason
      return await makeStatus()
    case .active:
      guard let sessionID, let lease else {
        phase = .recoveryPending
        stopReason = .leaseRecoveryPending("active direct session has no lease")
        return await makeStatus()
      }
      phase = .releasingLease
      pendingStopReason = reason
      switch await leaseBackend.release(
        sessionID: sessionID,
        lease: lease,
        reason: reason
      ) {
      case .released:
        phase = .ended
        self.lease = nil
        stopReason = reason
      case .recoveryPending(let detail):
        phase = .recoveryPending
        stopReason = .leaseRecoveryPending(detail)
      }
      return await makeStatus()
    case .idle, .releasingLease, .ended, .recoveryPending, .waitingForHotspot:
      return await makeStatus()
    }
  }

  private func performHeartbeat() async {
    guard phase == .active, let sessionID else {
      return
    }
    switch await leaseBackend.renew(leaseID: sessionID, ttl: .seconds(90)) {
    case .renewed(let observation):
      guard observation.phase == .active,
        observation.leaseID == sessionID,
        observation.ownerUID == ownerUID,
        observation.sleepOverride == .disabled
      else {
        lastHelperFault = "helper renewal returned a mismatched direct lease"
        _ = await releaseCurrent(reason: .superseded)
        return
      }
      lastHeartbeat = clock.now()
      lastHelperFault = nil
    case .rejected(let detail):
      lastHelperFault = detail
      _ = await releaseCurrent(reason: .superseded)
    case .unavailable(let detail):
      lastHelperFault = detail
    }
  }

  private func heartbeatIsDue() -> Bool {
    guard let lastHeartbeat,
      let age = clock.now().durationSince(lastHeartbeat)
    else {
      return true
    }
    return age >= SafetySupervisorController.heartbeatInterval
  }

  private func makeStatus() async -> SupervisorStatus {
    let verdict: SupervisorProtectionVerdict
    switch phase {
    case .idle:
      verdict = .inactive
    case .acquiringLease:
      verdict = .acquiring
    case .active:
      verdict = await protectedVerdict()
    case .releasingLease:
      verdict = .releasing(pendingStopReason)
    case .recoveryPending:
      verdict = .recoveryPending(String(describing: stopReason))
    case .ended:
      if case .safety = stopReason {
        verdict = .unsafe(String(describing: stopReason))
      } else {
        verdict = .inactive
      }
    case .waitingForHotspot:
      verdict = .unknown("direct session entered an invalid hotspot phase")
    }
    return SupervisorStatus(
      trip: TripStatus(
        phase: phase,
        sessionID: sessionID,
        hotspotDeadline: nil,
        hardDeadline: hardDeadline,
        stopReason: stopReason ?? pendingStopReason,
        hotspotWaitingReason: nil
      ),
      verdict: verdict,
      lastHeartbeat: lastHeartbeat,
      latestDevice: latestDevice
    )
  }

  private func protectedVerdict() async -> SupervisorProtectionVerdict {
    guard let sessionID, let latestSafetyVerdict else {
      return .unknown("direct session state is incomplete")
    }
    switch latestSafetyVerdict {
    case .safe:
      break
    case .uncertain(let reason):
      return .unknown("device safety signal is uncertain: \(reason)")
    case .stop(let reason):
      return .unsafe("device safety: \(reason)")
    }
    let now = clock.now()
    guard let lastHeartbeat,
      let age = now.durationSince(lastHeartbeat),
      age <= SafetySupervisorController.heartbeatFreshness
    else {
      return .unknown(lastHelperFault ?? "direct session heartbeat is stale")
    }
    switch await leaseBackend.liveStatus() {
    case .unavailable(let detail):
      return .unknown(detail)
    case .available(let helper):
      guard helper.phase == .active else {
        return helper.phase == .recoveryPending
          ? .recoveryPending(helper.detail ?? "helper recovery is pending")
          : .unknown(helper.detail ?? "helper lease is not active")
      }
      guard helper.leaseID == sessionID,
        helper.ownerUID == ownerUID,
        helper.sleepOverride == .disabled,
        let ttlDeadline = helper.ttlDeadline,
        let helperHardDeadline = helper.hardDeadline,
        ttlDeadline > now,
        helperHardDeadline > now,
        let remaining = helperHardDeadline.durationSince(now)
      else {
        return .unknown("helper direct lease truth does not match")
      }
      return .protected(remaining: remaining)
    }
  }

  private var isRunning: Bool {
    switch phase {
    case .acquiringLease, .active, .releasingLease, .recoveryPending:
      true
    case .idle, .waitingForHotspot, .ended:
      false
    }
  }
}
