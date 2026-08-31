import Foundation

public struct UserPowerAssertionToken: Hashable, Sendable {
  public let rawValue: UInt32

  public init(rawValue: UInt32) {
    self.rawValue = rawValue
  }
}

public protocol UserPowerAssertionBackend: Sendable {
  func acquire(reason: String) async throws -> UserPowerAssertionToken
  func release(_ token: UserPowerAssertionToken) async throws
}

public enum UserPowerAssertionError: Error, Equatable, Sendable {
  case unavailable
  case alreadyActive
  case invalidToken
  case systemFailure(Int32)
}

public actor UnavailableUserPowerAssertionBackend: UserPowerAssertionBackend {
  public init() {}

  public func acquire(reason: String) async throws -> UserPowerAssertionToken {
    throw UserPowerAssertionError.unavailable
  }

  public func release(_ token: UserPowerAssertionToken) async throws {
    throw UserPowerAssertionError.unavailable
  }
}
