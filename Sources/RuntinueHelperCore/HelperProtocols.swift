import Foundation
import RuntinueCore

public protocol SleepPowerBackend: Sendable {
  func readSleepOverride() async -> ObservedSleepOverride
  func writeAndVerify(_ state: SleepOverrideState) async throws
}

public protocol LeaseStateStore: Sendable {
  func load() async -> StoredLeaseLoadResult
  func save(_ lease: PersistedLease) async throws
  func remove() async throws
  func quarantineCorruptState() async throws
}

public protocol WallTimeSource: Sendable {
  func now() -> Date
}

public struct SystemWallClock: WallTimeSource {
  public init() {}

  public func now() -> Date {
    Date()
  }
}
