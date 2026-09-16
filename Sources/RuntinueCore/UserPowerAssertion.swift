import Foundation

public struct UserPowerAssertionToken: Hashable, Sendable {
  public let rawValue: UInt32

  public init(rawValue: UInt32) {
    self.rawValue = rawValue
  }
}

public protocol UserPowerAssertionBackend: Sendable {
  /// The effect must expire without another call from this process. The deadline
  /// and the backend clock must use the same boot-scoped continuous time source.
  /// Expiry turns off the effect; ownership remains until release succeeds.
  func acquire(reason: String, deadline: MonotonicInstant) async throws -> UserPowerAssertionToken
  /// Reads the current state of this owned assertion, not a cached acquisition result.
  func isActive(_ token: UserPowerAssertionToken) async throws -> Bool
  func release(_ token: UserPowerAssertionToken) async throws
}

public enum UserPowerAssertionError: Error, Equatable, Sendable {
  case unavailable
  case alreadyActive
  case invalidToken
  case invalidDeadline
  case systemFailure(Int32)
}

public actor UnavailableUserPowerAssertionBackend: UserPowerAssertionBackend {
  public init() {}

  public func acquire(
    reason: String, deadline: MonotonicInstant
  ) async throws -> UserPowerAssertionToken {
    throw UserPowerAssertionError.unavailable
  }

  public func isActive(_ token: UserPowerAssertionToken) async throws -> Bool {
    throw UserPowerAssertionError.unavailable
  }

  public func release(_ token: UserPowerAssertionToken) async throws {
    throw UserPowerAssertionError.unavailable
  }
}
