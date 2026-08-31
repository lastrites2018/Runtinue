import Foundation
import XCTest

@testable import SafeClamIPC
@testable import SafeClamSupervisorSystem

final class HelperReleaseConfirmationTests: XCTestCase {
  func testSuccessWithoutPowerReadbackDoesNotConfirmRelease() {
    XCTAssertFalse(
      XPCPrivilegedLeaseBackend.confirmsNormalSleep(
        HelperMutationWireResponse(outcome: .success, status: nil, rejection: nil)
      ))
    XCTAssertFalse(
      XPCPrivilegedLeaseBackend.confirmsNormalSleep(
        response(phase: .idle, sleep: .disabled)
      ))
    XCTAssertFalse(
      XPCPrivilegedLeaseBackend.confirmsNormalSleep(
        response(phase: .active, sleep: .normal)
      ))
    XCTAssertFalse(
      XPCPrivilegedLeaseBackend.confirmsNormalSleep(
        response(phase: .idle, sleep: .normal, leaseID: UUID())
      ))
    XCTAssertTrue(
      XPCPrivilegedLeaseBackend.confirmsNormalSleep(
        response(phase: .idle, sleep: .normal)
      ))
  }

  private func response(
    phase: WireHelperPhase, sleep: WireSleepOverride, leaseID: UUID? = nil
  ) -> HelperMutationWireResponse {
    HelperMutationWireResponse(
      outcome: .success,
      status: HelperStatusWire(
        phase: phase, leaseID: leaseID, ownerUID: nil, sleepOverride: sleep,
        ttlDeadlineUptimeNanoseconds: nil, hardDeadlineUptimeNanoseconds: nil, detail: nil
      ),
      rejection: nil
    )
  }
}
