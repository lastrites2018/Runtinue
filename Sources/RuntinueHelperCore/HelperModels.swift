import Foundation
import RuntinueCore

public enum SleepOverrideState: String, Codable, Equatable, Sendable {
  case normal
  case disabled
}

public enum ObservedSleepOverride: Equatable, Sendable {
  case normal
  case disabled
  case unavailable(String)
}

public enum PersistedLeasePhase: String, Codable, Equatable, Sendable {
  case acquiring
  case active
  case releasing
  case recoveryPending
}

public struct PersistedLease: Codable, Equatable, Sendable {
  public static let currentVersion = 1

  public let version: Int
  public let leaseID: UUID
  public let ownerUID: UInt32
  public let createdAt: Date
  public let hardDeadline: Date
  public let rollbackBaseline: SleepOverrideState
  public let reason: String
  public var phase: PersistedLeasePhase
  public var lastRenewedAt: Date
  public var ttlExpiresAt: Date
  public var recoveryDetail: String?

  public init(
    version: Int = Self.currentVersion,
    leaseID: UUID,
    ownerUID: UInt32,
    createdAt: Date,
    hardDeadline: Date,
    rollbackBaseline: SleepOverrideState,
    reason: String,
    phase: PersistedLeasePhase,
    lastRenewedAt: Date,
    ttlExpiresAt: Date,
    recoveryDetail: String? = nil
  ) {
    self.version = version
    self.leaseID = leaseID
    self.ownerUID = ownerUID
    self.createdAt = createdAt
    self.hardDeadline = hardDeadline
    self.rollbackBaseline = rollbackBaseline
    self.reason = reason
    self.phase = phase
    self.lastRenewedAt = lastRenewedAt
    self.ttlExpiresAt = ttlExpiresAt
    self.recoveryDetail = recoveryDetail
  }
}

public enum StoredLeaseLoadResult: Equatable, Sendable {
  case absent
  case valid(PersistedLease)
  case corrupt(String)
}

public struct LeaseAcquireRequest: Equatable, Sendable {
  public static let defaultTTL: Duration = .seconds(90)
  public static let maximumTTL: Duration = .seconds(90)
  public static let maximumHardCap: Duration = .seconds(24 * 60 * 60)

  public let leaseID: UUID
  public let ownerUID: UInt32
  public let ttl: Duration
  public let hardCap: Duration
  public let reason: String

  public init(
    leaseID: UUID = UUID(),
    ownerUID: UInt32,
    ttl: Duration = Self.defaultTTL,
    hardCap: Duration,
    reason: String
  ) {
    self.leaseID = leaseID
    self.ownerUID = ownerUID
    self.ttl = ttl
    self.hardCap = hardCap
    self.reason = reason
  }
}

public enum HelperLeasePhase: String, Equatable, Sendable {
  case idle
  case acquiring
  case active
  case releasing
  case recoveryPending
  case externalOwner
  case unknown
}

public struct HelperLeaseStatus: Equatable, Sendable {
  public let phase: HelperLeasePhase
  public let leaseID: UUID?
  public let ownerUID: UInt32?
  public let observedSleepOverride: ObservedSleepOverride
  public let ttlDeadline: MonotonicInstant?
  public let hardDeadline: MonotonicInstant?
  public let detail: String?

  public init(
    phase: HelperLeasePhase,
    leaseID: UUID?,
    ownerUID: UInt32?,
    observedSleepOverride: ObservedSleepOverride,
    ttlDeadline: MonotonicInstant?,
    hardDeadline: MonotonicInstant?,
    detail: String?
  ) {
    self.phase = phase
    self.leaseID = leaseID
    self.ownerUID = ownerUID
    self.observedSleepOverride = observedSleepOverride
    self.ttlDeadline = ttlDeadline
    self.hardDeadline = hardDeadline
    self.detail = detail
  }

  public var isProtected: Bool {
    phase == .active && observedSleepOverride == .disabled
  }
}

public enum HelperLeaseRejection: Equatable, Sendable {
  case invalidTTL
  case invalidHardCap
  case invalidReason
  case leaseAlreadyExists
  case leaseMismatch
  case sleepOverrideAlreadyOwned
  case stateUnavailable(String)
  case persistenceFailure(String)
  case powerFailure(String)
}

public enum HelperLeaseMutationResult: Equatable, Sendable {
  case success(HelperLeaseStatus)
  case rejected(HelperLeaseRejection)
  case recoveryPending(HelperLeaseStatus)
}

public enum HelperReleaseReason: String, Codable, Equatable, Sendable {
  case userRequested
  case supervisorHeartbeatExpired
  case hardDeadlineReached
  case safetyTrip
  case startupRecovery
  case corruptStateRecovery
  case shutdown
}
