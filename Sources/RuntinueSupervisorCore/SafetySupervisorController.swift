import Foundation
import RuntinueCore

public actor SafetySupervisorController {
  public static let heartbeatInterval: Duration = .seconds(30)
  public static let heartbeatFreshness: Duration = .seconds(45)

  private let tripCoordinator: CommuteTripCoordinator
  private let leaseBackend: any SupervisorLeaseBackend
  private let clock: any MonotonicTimeSource
  private let ownerUID: UInt32

  private var activeRequest: CommuteTripRequest?
  private var latestDevice: DeviceSafetySnapshot?
  private var latestSafetyVerdict: DeviceSafetyVerdict?
  private var safetyTracker: DeviceSafetyTracker?
  private var sessionID: UUID?
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
    self.tripCoordinator = CommuteTripCoordinator(
      leaseBackend: leaseBackend,
      clock: clock
    )
  }

  @discardableResult
  public func start(
    _ request: CommuteTripRequest,
    originNetwork: NetworkSnapshot,
    device: DeviceSafetySnapshot
  ) async throws -> SupervisorStatus {
    let trip = try await tripCoordinator.arm(
      request,
      originNetwork: originNetwork,
      device: device
    )
    activeRequest = request
    latestDevice = device
    latestSafetyVerdict = request.safetyPolicy.evaluate(device, at: clock.now())
    safetyTracker = DeviceSafetyTracker(policy: request.safetyPolicy)
    sessionID = trip.sessionID
    lastHeartbeat = nil
    lastHelperFault = nil
    return await makeStatus()
  }

  @discardableResult
  public func observe(
    network: NetworkSnapshot,
    device: DeviceSafetySnapshot
  ) async -> SupervisorStatus {
    latestDevice = device
    var tracker =
      safetyTracker
      ?? DeviceSafetyTracker(
        policy: activeRequest?.safetyPolicy ?? DeviceSafetyPolicy()
      )
    let safetyVerdict = tracker.evaluate(device, at: clock.now())
    safetyTracker = tracker
    latestSafetyVerdict = safetyVerdict
    _ = await tripCoordinator.observeDevice(
      device,
      verdict: safetyVerdict
    )
    let trip = await tripCoordinator.observeNetwork(network)
    if trip.phase == .active, lastHeartbeat == nil {
      lastHeartbeat = clock.now()
    }
    return await makeStatus()
  }

  @discardableResult
  public func tick() async -> SupervisorStatus {
    let trip = await tripCoordinator.tick()
    if trip.phase == .active, heartbeatIsDue(at: clock.now()) {
      await performHeartbeat(for: trip)
    }
    return await makeStatus()
  }

  @discardableResult
  public func heartbeat() async -> SupervisorStatus {
    await performHeartbeat(for: await tripCoordinator.status())
    return await makeStatus()
  }

  @discardableResult
  public func stop() async -> SupervisorStatus {
    _ = await tripCoordinator.stop()
    return await makeStatus()
  }

  public func status() async -> SupervisorStatus {
    await makeStatus()
  }

  @discardableResult
  public func reconcileRecovery() async -> SupervisorStatus {
    let trip = await tripCoordinator.status()
    guard trip.phase == .recoveryPending else {
      return await makeStatus()
    }
    if case .available(let helper) = await leaseBackend.liveStatus(),
      helper.phase == .idle,
      helper.sleepOverride == .normal
    {
      _ = await tripCoordinator.confirmRecovery()
      lastHelperFault = nil
    }
    return await makeStatus()
  }

  private func performHeartbeat(for trip: TripStatus) async {
    guard trip.phase == .active, let leaseID = trip.sessionID else {
      return
    }
    switch await leaseBackend.renew(
      leaseID: leaseID,
      ttl: .seconds(90)
    ) {
    case .renewed(let observation):
      guard observation.phase == .active,
        observation.leaseID == leaseID,
        observation.sleepOverride == .disabled
      else {
        lastHelperFault = "helper renewal returned a mismatched lease state"
        _ = await tripCoordinator.stop()
        return
      }
      lastHeartbeat = clock.now()
      lastHelperFault = nil
    case .rejected(let detail):
      lastHelperFault = detail
      _ = await tripCoordinator.stop()
    case .unavailable(let detail):
      lastHelperFault = detail
    }
  }

  private func heartbeatIsDue(at now: MonotonicInstant) -> Bool {
    guard let lastHeartbeat,
      let age = now.durationSince(lastHeartbeat)
    else {
      return true
    }
    return age >= Self.heartbeatInterval
  }

  private func makeStatus() async -> SupervisorStatus {
    let trip = await tripCoordinator.status()
    let verdict: SupervisorProtectionVerdict

    switch trip.phase {
    case .idle:
      verdict = .inactive
    case .waitingForHotspot:
      verdict = .waitingForHotspot(trip.hotspotWaitingReason)
    case .acquiringLease:
      verdict = .acquiring
    case .releasingLease:
      verdict = .releasing(trip.stopReason)
    case .recoveryPending:
      verdict = .recoveryPending(describe(trip.stopReason))
    case .ended:
      if case .safety = trip.stopReason {
        verdict = .unsafe(describe(trip.stopReason))
      } else if case .leaseRecoveryPending = trip.stopReason {
        verdict = .recoveryPending(describe(trip.stopReason))
      } else {
        verdict = .inactive
      }
    case .active:
      verdict = await protectedVerdict(for: trip)
    }

    return SupervisorStatus(
      trip: trip,
      verdict: verdict,
      lastHeartbeat: lastHeartbeat,
      latestDevice: latestDevice
    )
  }

  private func protectedVerdict(
    for trip: TripStatus
  ) async -> SupervisorProtectionVerdict {
    guard activeRequest != nil,
      let latestSafetyVerdict,
      let leaseID = sessionID,
      trip.sessionID == leaseID
    else {
      return .unknown("supervisor session state is incomplete")
    }

    let now = clock.now()
    switch latestSafetyVerdict {
    case .safe:
      break
    case .uncertain(let reason):
      return .unknown("device safety signal is uncertain: \(reason)")
    case .stop(let reason):
      return .unsafe("device safety: \(reason)")
    }
    guard let lastHeartbeat,
      let heartbeatAge = now.durationSince(lastHeartbeat),
      heartbeatAge <= Self.heartbeatFreshness
    else {
      return .unknown(lastHelperFault ?? "supervisor heartbeat is stale")
    }

    switch await leaseBackend.liveStatus() {
    case .unavailable(let detail):
      return .unknown(detail)
    case .available(let helper):
      guard helper.phase == .active else {
        if helper.phase == .recoveryPending {
          return .recoveryPending(helper.detail ?? "helper recovery is pending")
        }
        return .unknown(helper.detail ?? "helper lease is not active")
      }
      guard helper.leaseID == leaseID else {
        return .unknown("helper lease ID does not match the supervisor session")
      }
      guard helper.ownerUID == ownerUID else {
        return .unknown("helper lease owner does not match the supervisor user")
      }
      guard helper.sleepOverride == .disabled else {
        return .unknown("SleepDisabled read-back is not active")
      }
      guard let ttlDeadline = helper.ttlDeadline,
        let hardDeadline = helper.hardDeadline,
        ttlDeadline > now,
        hardDeadline > now,
        let remaining = hardDeadline.durationSince(now)
      else {
        return .unknown("helper lease deadline is missing or expired")
      }
      return .protected(remaining: remaining)
    }
  }

  private func describe(_ reason: TripStopReason?) -> String {
    reason.map(String.init(describing:)) ?? "unknown"
  }
}
