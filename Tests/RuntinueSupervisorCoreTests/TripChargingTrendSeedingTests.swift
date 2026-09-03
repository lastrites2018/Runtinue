import Foundation
import XCTest

@testable import RuntinueCore
@testable import RuntinueSupervisorCore

@MainActor
final class TripChargingTrendSeedingTests: XCTestCase {
  func testTripSeedsChargingTrendBeforeTheFirstObservation() async throws {
    let clock = ChargingSeedClock()
    let backend = ChargingSeedLeaseBackend(clock: clock)
    let controller = SafetySupervisorController(
      leaseBackend: backend,
      ownerUID: 501,
      clock: clock
    )

    let waiting = try await controller.start(
      CommuteTripRequest(
        expectedHotspotSSID: "iPhone",
        hardCap: .seconds(90 * 60)
      ),
      originNetwork: network(ssid: "Office", clock: clock),
      device: device(battery: 31, clock: clock)
    )
    XCTAssertEqual(waiting.verdict, .waitingForHotspot(nil))

    clock.advance(seconds: 1)
    let firstDrop = await controller.observe(
      network: network(ssid: "iPhone", clock: clock),
      device: device(battery: 29, clock: clock)
    )
    guard case .protected = firstDrop.verdict else {
      return XCTFail("the first drop should become a candidate before release, got \(firstDrop.verdict)")
    }

    clock.advance(seconds: 1)
    let confirmedDrain = await controller.observe(
      network: network(ssid: "iPhone", clock: clock),
      device: device(battery: 29, clock: clock)
    )
    guard case .unsafe = confirmedDrain.verdict else {
      return XCTFail("the next fresh sample should confirm drain, got \(confirmedDrain.verdict)")
    }

    let backendSnapshot = await backend.snapshot()
    XCTAssertEqual(backendSnapshot.acquireCount, 1)
    XCTAssertEqual(backendSnapshot.releaseCount, 1)
  }

  private func network(
    ssid: String,
    clock: ChargingSeedClock
  ) -> NetworkSnapshot {
    NetworkSnapshot(
      ssid: ssid,
      interfaceName: "en0",
      routeReachable: true,
      internetReachability: .confirmed,
      capturedAt: clock.now()
    )
  }

  private func device(
    battery: Int,
    clock: ChargingSeedClock
  ) -> DeviceSafetySnapshot {
    DeviceSafetySnapshot(
      batteryPercent: battery,
      powerConnection: .acCharging,
      thermalLevel: .nominal,
      lidState: .closed,
      externalDisplayState: .absent,
      lowPowerModeEnabled: false,
      capturedAt: clock.now()
    )
  }
}

private actor ChargingSeedLeaseBackend: SupervisorLeaseBackend {
  struct Snapshot: Sendable {
    let acquireCount: Int
    let releaseCount: Int
  }

  private let clock: ChargingSeedClock
  private var observation = SupervisorHelperObservation(
    phase: .idle,
    leaseID: nil,
    ownerUID: nil,
    sleepOverride: .normal,
    ttlDeadline: nil,
    hardDeadline: nil,
    detail: nil
  )
  private var acquireCount = 0
  private var releaseCount = 0

  init(clock: ChargingSeedClock) {
    self.clock = clock
  }

  func acquire(sessionID: UUID, hardCap: Duration) async -> LeaseAcquisitionOutcome {
    acquireCount += 1
    let now = clock.now()
    observation = SupervisorHelperObservation(
      phase: .active,
      leaseID: sessionID,
      ownerUID: 501,
      sleepOverride: .disabled,
      ttlDeadline: now.adding(.seconds(90)),
      hardDeadline: now.adding(hardCap),
      detail: nil
    )
    return .acquired(LeaseToken(id: sessionID))
  }

  func release(
    sessionID: UUID,
    lease: LeaseToken,
    reason: TripStopReason
  ) async -> LeaseReleaseOutcome {
    releaseCount += 1
    observation = SupervisorHelperObservation(
      phase: .idle,
      leaseID: nil,
      ownerUID: nil,
      sleepOverride: .normal,
      ttlDeadline: nil,
      hardDeadline: nil,
      detail: nil
    )
    return .released
  }

  func renew(leaseID: UUID, ttl: Duration) async -> SupervisorHeartbeatResult {
    let now = clock.now()
    observation = SupervisorHelperObservation(
      phase: .active,
      leaseID: leaseID,
      ownerUID: 501,
      sleepOverride: .disabled,
      ttlDeadline: now.adding(ttl),
      hardDeadline: observation.hardDeadline,
      detail: nil
    )
    return .renewed(observation)
  }

  func liveStatus() async -> SupervisorHelperQuery {
    .available(observation)
  }

  func releaseExistingOwnedLease() async -> LeaseReleaseOutcome {
    .released
  }

  func snapshot() -> Snapshot {
    Snapshot(acquireCount: acquireCount, releaseCount: releaseCount)
  }
}

private final class ChargingSeedClock: @unchecked Sendable, MonotonicTimeSource {
  private let lock = NSLock()
  private var nanoseconds: UInt64 = 1_000_000_000

  func now() -> MonotonicInstant {
    lock.lock()
    defer { lock.unlock() }
    return MonotonicInstant(continuousNanoseconds: nanoseconds)
  }

  func advance(seconds: UInt64) {
    lock.lock()
    nanoseconds += seconds * 1_000_000_000
    lock.unlock()
  }
}
