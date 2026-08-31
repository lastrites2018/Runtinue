import Foundation

public enum RuntinueIPCContract {
  public static let protocolVersion = 4
  public static let maximumRequestBytes = 64 * 1_024
  public static let helperMachServiceName = "io.github.lastrites2018.runtinue.helper"
  public static let supervisorMachServiceName = "io.github.lastrites2018.runtinue.supervisor"
  public static let supervisorActivityMachServiceName =
    "io.github.lastrites2018.runtinue.supervisor.activity"

  public static func acceptsRequest(
    protocolVersion: Int,
    byteCount: Int
  ) -> Bool {
    protocolVersion == self.protocolVersion
      && byteCount >= 0
      && byteCount <= maximumRequestBytes
  }

  public static func decodeRequest<T: Decodable>(
    _ type: T.Type,
    from data: Data
  ) -> T? {
    guard data.count <= maximumRequestBytes else {
      return nil
    }
    return try? JSONDecoder().decode(type, from: data)
  }
}

@objc public protocol PrivilegedLeaseXPCProtocol {
  func protocolVersion(withReply reply: @escaping (Int) -> Void)
  func acquire(_ request: Data, withReply reply: @escaping (Data) -> Void)
  func renew(_ request: Data, withReply reply: @escaping (Data) -> Void)
  func release(_ request: Data, withReply reply: @escaping (Data) -> Void)
  func status(withReply reply: @escaping (Data) -> Void)
  func recover(withReply reply: @escaping (Data) -> Void)
}

public struct AcquireLeaseWireRequest: Codable, Equatable, Sendable {
  public let protocolVersion: Int
  public let leaseID: UUID
  public let ttlSeconds: Double
  public let hardCapSeconds: Double
  public let reason: String

  public init(
    protocolVersion: Int = RuntinueIPCContract.protocolVersion,
    leaseID: UUID,
    ttlSeconds: Double,
    hardCapSeconds: Double,
    reason: String
  ) {
    self.protocolVersion = protocolVersion
    self.leaseID = leaseID
    self.ttlSeconds = ttlSeconds
    self.hardCapSeconds = hardCapSeconds
    self.reason = reason
  }
}

public struct RenewLeaseWireRequest: Codable, Equatable, Sendable {
  public let protocolVersion: Int
  public let leaseID: UUID
  public let ttlSeconds: Double

  public init(
    protocolVersion: Int = RuntinueIPCContract.protocolVersion,
    leaseID: UUID,
    ttlSeconds: Double
  ) {
    self.protocolVersion = protocolVersion
    self.leaseID = leaseID
    self.ttlSeconds = ttlSeconds
  }
}

public struct ReleaseLeaseWireRequest: Codable, Equatable, Sendable {
  public let protocolVersion: Int
  public let leaseID: UUID
  public let reason: WireReleaseReason

  public init(
    protocolVersion: Int = RuntinueIPCContract.protocolVersion,
    leaseID: UUID,
    reason: WireReleaseReason
  ) {
    self.protocolVersion = protocolVersion
    self.leaseID = leaseID
    self.reason = reason
  }
}

public enum WireReleaseReason: String, Codable, Equatable, Sendable {
  case userRequested
  case safetyTrip
  case supervisorShutdown
}

public enum WireMutationOutcome: String, Codable, Equatable, Sendable {
  case success
  case rejected
  case recoveryPending
  case invalidRequest
}

public enum WireHelperPhase: String, Codable, Equatable, Sendable {
  case idle
  case acquiring
  case active
  case releasing
  case recoveryPending
  case externalOwner
  case unknown
}

public enum WireSleepOverride: String, Codable, Equatable, Sendable {
  case normal
  case disabled
  case unavailable
}

public struct HelperStatusWire: Codable, Equatable, Sendable {
  public let phase: WireHelperPhase
  public let leaseID: UUID?
  public let ownerUID: UInt32?
  public let sleepOverride: WireSleepOverride
  public let ttlDeadlineUptimeNanoseconds: UInt64?
  public let hardDeadlineUptimeNanoseconds: UInt64?
  public let detail: String?

  public init(
    phase: WireHelperPhase,
    leaseID: UUID?,
    ownerUID: UInt32?,
    sleepOverride: WireSleepOverride,
    ttlDeadlineUptimeNanoseconds: UInt64?,
    hardDeadlineUptimeNanoseconds: UInt64?,
    detail: String?
  ) {
    self.phase = phase
    self.leaseID = leaseID
    self.ownerUID = ownerUID
    self.sleepOverride = sleepOverride
    self.ttlDeadlineUptimeNanoseconds = ttlDeadlineUptimeNanoseconds
    self.hardDeadlineUptimeNanoseconds = hardDeadlineUptimeNanoseconds
    self.detail = detail
  }
}

public struct HelperMutationWireResponse: Codable, Equatable, Sendable {
  public let protocolVersion: Int
  public let outcome: WireMutationOutcome
  public let status: HelperStatusWire?
  public let rejection: String?

  public init(
    protocolVersion: Int = RuntinueIPCContract.protocolVersion,
    outcome: WireMutationOutcome,
    status: HelperStatusWire?,
    rejection: String?
  ) {
    self.protocolVersion = protocolVersion
    self.outcome = outcome
    self.status = status
    self.rejection = rejection
  }
}
