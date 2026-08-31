import IOKit.pwr_mgt
import SafeClamCore

public actor IOPMUserPowerAssertionBackend: UserPowerAssertionBackend {
  private var activeAssertion: IOPMAssertionID?

  public init() {}

  public func acquire(reason: String) async throws -> UserPowerAssertionToken {
    guard activeAssertion == nil else {
      throw UserPowerAssertionError.alreadyActive
    }
    var assertionID = IOPMAssertionID(0)
    let result = IOPMAssertionCreateWithName(
      kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
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
    let result = IOPMAssertionRelease(token.rawValue)
    guard result == kIOReturnSuccess else {
      throw UserPowerAssertionError.systemFailure(result)
    }
    activeAssertion = nil
  }
}
