import Foundation
import XCTest
import RuntinueCore
import RuntinueIPC

@testable import RuntinueSupervisorSystem

final class HelperAcquisitionConfirmationTests: XCTestCase {
  func testSuccessRequiresMatchingOwnerActiveReadbackAndUnexpiredOrderedDeadlines() {
    let leaseID = UUID()
    let now = MonotonicInstant(continuousNanoseconds: 10)
    let invalid: [HelperStatusWire?] = [
      nil,
      status(leaseID: nil),
      status(leaseID: UUID()),
      status(leaseID: leaseID, ownerUID: nil),
      status(leaseID: leaseID, ownerUID: 502),
      status(leaseID: leaseID, phase: .idle),
      status(leaseID: leaseID, phase: .recoveryPending),
      status(leaseID: leaseID, sleep: .normal),
      status(leaseID: leaseID, sleep: .unavailable),
      status(leaseID: leaseID, ttl: nil),
      status(leaseID: leaseID, hard: nil),
      status(leaseID: leaseID, ttl: 10),
      status(leaseID: leaseID, ttl: 9),
      status(leaseID: leaseID, ttl: 12, hard: 11),
    ]
    for invalidStatus in invalid {
      XCTAssertFalse(XPCPrivilegedLeaseBackend.confirmsActiveLease(
        HelperMutationWireResponse(outcome: .success, status: invalidStatus, rejection: nil),
        leaseID: leaseID, ownerUID: 501, at: now
      ))
    }
    let validStatus = status(leaseID: leaseID, ttl: 11, hard: 11)
    XCTAssertTrue(XPCPrivilegedLeaseBackend.confirmsActiveLease(
      HelperMutationWireResponse(outcome: .success, status: validStatus, rejection: nil),
      leaseID: leaseID, ownerUID: 501, at: now
    ))
    for response in [
      HelperMutationWireResponse(protocolVersion: 4, outcome: .success, status: validStatus, rejection: nil),
      HelperMutationWireResponse(outcome: .recoveryPending, status: validStatus, rejection: nil),
      HelperMutationWireResponse(outcome: .success, status: validStatus, rejection: "inconsistent reply"),
    ] {
      XCTAssertFalse(XPCPrivilegedLeaseBackend.confirmsActiveLease(response, leaseID: leaseID, ownerUID: 501, at: now))
    }
  }

  private func status(
    leaseID: UUID?, ownerUID: UInt32? = 501, phase: WireHelperPhase = .active,
    sleep: WireSleepOverride = .disabled, ttl: UInt64? = 11, hard: UInt64? = 12
  ) -> HelperStatusWire {
    HelperStatusWire(
      phase: phase, leaseID: leaseID, ownerUID: ownerUID, sleepOverride: sleep,
      ttlDeadlineContinuousNanoseconds: ttl, hardDeadlineContinuousNanoseconds: hard, detail: nil
    )
  }
}
