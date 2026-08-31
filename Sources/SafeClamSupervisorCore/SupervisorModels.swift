import Foundation
import SafeClamCore

public enum SupervisorHelperPhase: String, Equatable, Sendable {
  case idle
  case acquiring
  case active
  case releasing
  case recoveryPending
  case externalOwner
  case unknown
}

public enum SupervisorSleepOverride: String, Equatable, Sendable {
  case normal
  case disabled
  case unavailable
}

public struct SupervisorHelperObservation: Equatable, Sendable {
  public let phase: SupervisorHelperPhase
  public let leaseID: UUID?
  public let ownerUID: UInt32?
  public let sleepOverride: SupervisorSleepOverride
  public let ttlDeadline: MonotonicInstant?
  public let hardDeadline: MonotonicInstant?
  public let detail: String?

  public init(
    phase: SupervisorHelperPhase,
    leaseID: UUID?,
    ownerUID: UInt32?,
    sleepOverride: SupervisorSleepOverride,
    ttlDeadline: MonotonicInstant?,
    hardDeadline: MonotonicInstant?,
    detail: String?
  ) {
    self.phase = phase
    self.leaseID = leaseID
    self.ownerUID = ownerUID
    self.sleepOverride = sleepOverride
    self.ttlDeadline = ttlDeadline
    self.hardDeadline = hardDeadline
    self.detail = detail
  }
}

public enum SupervisorHelperQuery: Equatable, Sendable {
  case available(SupervisorHelperObservation)
  case unavailable(String)
}

public enum SupervisorHeartbeatResult: Equatable, Sendable {
  case renewed(SupervisorHelperObservation)
  case rejected(String)
  case unavailable(String)
}

public protocol SupervisorLeaseBackend: PrivilegedLeaseBackend {
  func renew(leaseID: UUID, ttl: Duration) async -> SupervisorHeartbeatResult
  func liveStatus() async -> SupervisorHelperQuery
  func releaseExistingOwnedLease() async -> LeaseReleaseOutcome
}

public enum SupervisorProtectionVerdict: Equatable, Sendable {
  case inactive
  case waitingForHotspot(HotspotWaitingReason?)
  case acquiring
  case protected(remaining: Duration)
  case releasing(TripStopReason?)
  case recoveryPending(String)
  case unsafe(String)
  case unknown(String)
}

public struct SupervisorStatus: Equatable, Sendable {
  public let trip: TripStatus
  public let verdict: SupervisorProtectionVerdict
  public let lastHeartbeat: MonotonicInstant?
  public let latestDevice: DeviceSafetySnapshot?

  public init(
    trip: TripStatus,
    verdict: SupervisorProtectionVerdict,
    lastHeartbeat: MonotonicInstant?,
    latestDevice: DeviceSafetySnapshot?
  ) {
    self.trip = trip
    self.verdict = verdict
    self.lastHeartbeat = lastHeartbeat
    self.latestDevice = latestDevice
  }
}
