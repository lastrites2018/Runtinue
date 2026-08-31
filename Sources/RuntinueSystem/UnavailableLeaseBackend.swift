import Foundation
import RuntinueCore

/// A fail-closed backend for previews and tests that do not install the
/// signed root helper.
public struct UnavailableLeaseBackend: PrivilegedLeaseBackend {
  public init() {}

  public func acquire(sessionID: UUID, hardCap: Duration) async -> LeaseAcquisitionOutcome {
    .rejected("signed privileged lease helper is not installed")
  }

  public func release(
    sessionID: UUID,
    lease: LeaseToken,
    reason: TripStopReason
  ) async -> LeaseReleaseOutcome {
    .recoveryPending("no privileged helper is available to verify normal sleep")
  }
}
