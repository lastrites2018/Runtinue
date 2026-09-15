import IOKit.pwr_mgt
import RuntinueCore

// Keep the synchronous IOKit boundary replaceable in tests without changing system power state.
struct IOPMAssertionOperations: Sendable {
  let create: @Sendable (
    CFString, IOPMAssertionLevel, CFString, UnsafeMutablePointer<IOPMAssertionID>
  ) -> IOReturn
  let release: @Sendable (IOPMAssertionID) -> IOReturn

  static let system = IOPMAssertionOperations(
    create: { type, level, reason, assertionID in
      IOPMAssertionCreateWithName(type, level, reason, assertionID)
    },
    release: { assertionID in IOPMAssertionRelease(assertionID) }
  )
}

/// Process-owned display and system idle-sleep prevention for open-lid timed sessions.
public actor IOPMUserPowerAssertionBackend: UserPowerAssertionBackend {
  private let operations: IOPMAssertionOperations
  private var activeAssertion: IOPMAssertionID?

  public init() {
    operations = .system
  }

  init(operations: IOPMAssertionOperations) {
    self.operations = operations
  }

  public func acquire(reason: String) async throws -> UserPowerAssertionToken {
    guard activeAssertion == nil else {
      throw UserPowerAssertionError.alreadyActive
    }
    var assertionID = IOPMAssertionID(0)
    // Display idle-sleep prevention also prevents system idle sleep. It does not unlock
    // the screen, override a manual sleep request, or enable closed-lid operation.
    let result = operations.create(
      kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
      IOPMAssertionLevel(kIOPMAssertionLevelOn),
      reason as CFString,
      &assertionID
    )
    guard result == kIOReturnSuccess else {
      throw UserPowerAssertionError.systemFailure(result)
    }
    activeAssertion = assertionID
    return UserPowerAssertionToken(rawValue: assertionID)
  }

  public func release(_ token: UserPowerAssertionToken) async throws {
    guard activeAssertion == token.rawValue else {
      throw UserPowerAssertionError.invalidToken
    }
    let result = operations.release(token.rawValue)
    guard result == kIOReturnSuccess else {
      throw UserPowerAssertionError.systemFailure(result)
    }
    activeAssertion = nil
  }
}
