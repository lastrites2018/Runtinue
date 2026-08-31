import XCTest

@testable import RuntinueCore

@MainActor
final class CommuteTripCoordinatorTests: XCTestCase {
  func testCoordinatorExecutesAcquireAndSafetyReleaseCommands() async throws {
    let now = instant(seconds: 100)
    let lease = LeaseToken()
    let backend = RecordingLeaseBackend(lease: lease)
    let coordinator = CommuteTripCoordinator(
      leaseBackend: backend,
      clock: FixedClock(now: now)
    )

    _ = try await coordinator.arm(
      CommuteTripRequest(expectedHotspotSSID: "Jaewan iPhone"),
      originNetwork: network(ssid: "Office", at: now),
      device: device(at: now)
    )
    let activeStatus = await coordinator.observeNetwork(
      network(ssid: "Jaewan iPhone", at: now)
    )
    XCTAssertEqual(activeStatus.phase, .active)

    let endedStatus = await coordinator.observeDevice(
      device(at: now, thermal: .fair, lid: .closed)
    )
    XCTAssertEqual(endedStatus.phase, .ended)
    XCTAssertEqual(
      endedStatus.stopReason,
      .safety(.thermalLimitReached(observed: .fair, cutoff: .fair))
    )

    let operations = await backend.operations
    XCTAssertEqual(operations, [.acquire, .release])
  }
}

private struct FixedClock: MonotonicTimeSource {
  let nowValue: MonotonicInstant

  init(now: MonotonicInstant) {
    self.nowValue = now
  }

  func now() -> MonotonicInstant {
    nowValue
  }
}

private actor RecordingLeaseBackend: PrivilegedLeaseBackend {
  enum Operation: Equatable {
    case acquire
    case release
  }

  let lease: LeaseToken
  private(set) var operations: [Operation] = []

  init(lease: LeaseToken) {
    self.lease = lease
  }

  func acquire(sessionID: UUID, hardCap: Duration) async -> LeaseAcquisitionOutcome {
    operations.append(.acquire)
    return .acquired(lease)
  }

  func release(
    sessionID: UUID,
    lease: LeaseToken,
    reason: TripStopReason
  ) async -> LeaseReleaseOutcome {
    operations.append(.release)
    return .released
  }
}
