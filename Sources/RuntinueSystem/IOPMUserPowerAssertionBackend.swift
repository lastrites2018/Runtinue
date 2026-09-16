import Foundation
import IOKit.pwr_mgt
import RuntinueCore

// Keep the synchronous IOKit boundary replaceable in tests without changing system power state.
struct IOPMAssertionOperations: Sendable {
  let create: @Sendable (CFDictionary, UnsafeMutablePointer<IOPMAssertionID>) -> IOReturn
  let copyProperties: @Sendable (IOPMAssertionID) -> CFDictionary?
  let release: @Sendable (IOPMAssertionID) -> IOReturn

  static let system = IOPMAssertionOperations(
    create: { properties, assertionID in
      IOPMAssertionCreateWithProperties(properties, assertionID)
    },
    copyProperties: { assertionID in
      IOPMAssertionCopyProperties(assertionID)?.takeRetainedValue()
    },
    release: { assertionID in IOPMAssertionRelease(assertionID) }
  )
}

/// Process-owned display and system idle-sleep prevention for open-lid timed sessions.
public actor IOPMUserPowerAssertionBackend: UserPowerAssertionBackend {
  private let operations: IOPMAssertionOperations
  private let clock: any MonotonicTimeSource
  private var activeAssertion: IOPMAssertionID?

  public init(clock: any MonotonicTimeSource = SystemContinuousClock()) {
    operations = .system
    self.clock = clock
  }

  init(operations: IOPMAssertionOperations, clock: any MonotonicTimeSource) {
    self.operations = operations
    self.clock = clock
  }

  public func acquire(
    reason: String, deadline: MonotonicInstant
  ) async throws -> UserPowerAssertionToken {
    guard activeAssertion == nil else {
      throw UserPowerAssertionError.alreadyActive
    }
    // Compute the remaining interval here, after waiting for this actor, rather
    // than restarting the caller's duration when the request finally arrives.
    guard let remaining = deadline.durationSince(clock.now()),
      remaining > .zero, remaining <= CommuteTripRequest.maximumHardCap
    else {
      throw UserPowerAssertionError.invalidDeadline
    }
    let parts = remaining.components
    // Power management schedules timeouts in whole seconds. Round up to avoid
    // turning a positive subsecond remainder into the API's zero/no-timeout value.
    let timeout = ceil(Double(parts.seconds) + Double(parts.attoseconds) / 1e18)
    guard timeout.isFinite, timeout > 0 else {
      throw UserPowerAssertionError.invalidDeadline
    }
    let properties: [String: Any] = [
      kIOPMAssertionTypeKey as String: kIOPMAssertionTypePreventUserIdleDisplaySleep,
      kIOPMAssertionLevelKey as String: NSNumber(value: kIOPMAssertionLevelOn),
      kIOPMAssertionNameKey as String: reason,
      kIOPMAssertionTimeoutKey as String: NSNumber(value: timeout),
      kIOPMAssertionTimeoutActionKey as String: kIOPMAssertionTimeoutActionTurnOff,
    ]
    var assertionID = IOPMAssertionID(0)
    // Register the effect and its timeout together. TurnOff leaves the token
    // owned so the existing release/recovery path can clean it up after expiry.
    let result = operations.create(properties as CFDictionary, &assertionID)
    guard result == kIOReturnSuccess else {
      throw UserPowerAssertionError.systemFailure(result)
    }
    activeAssertion = assertionID
    return UserPowerAssertionToken(rawValue: assertionID)
  }

  public func isActive(_ token: UserPowerAssertionToken) async throws -> Bool {
    guard activeAssertion == token.rawValue else {
      throw UserPowerAssertionError.invalidToken
    }
    guard let properties = operations.copyProperties(token.rawValue) as? [String: Any],
      let type = properties[kIOPMAssertionTypeKey as String] as? String,
      let level = properties[kIOPMAssertionLevelKey as String] as? NSNumber
    else {
      throw UserPowerAssertionError.unavailable
    }
    // Keep ownership even when readback fails or reports an inactive assertion.
    // Only the release path may relinquish our responsibility for this token.
    return type == kIOPMAssertionTypePreventUserIdleDisplaySleep as String
      && level.uint32Value == IOPMAssertionLevel(kIOPMAssertionLevelOn)
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
