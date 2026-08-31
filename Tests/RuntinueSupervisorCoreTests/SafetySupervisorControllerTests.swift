import Foundation
import XCTest

@testable import RuntinueCore
@testable import RuntinueSupervisorCore

@MainActor
final class SafetySupervisorControllerTests: XCTestCase {
  func testHotspotHandoffBecomesProtectedOnlyWithLiveHelperTruth() async throws {
    let clock = SupervisorManualClock()
    let backend = FakeSupervisorLeaseBackend(clock: clock)
    let controller = SafetySupervisorController(
      leaseBackend: backend,
      ownerUID: 501,
      clock: clock
    )

    let waiting = try await controller.start(
      request(),
      originNetwork: supervisorNetwork(ssid: "Office", clock: clock),
      device: supervisorDevice(clock: clock)
    )
    XCTAssertEqual(waiting.verdict, .waitingForHotspot(nil))

    let active = await controller.observe(
      network: supervisorNetwork(ssid: "iPhone", clock: clock),
      device: supervisorDevice(clock: clock)
    )

    guard case .protected = active.verdict else {
      return XCTFail("expected protected verdict, got \(active.verdict)")
    }
    let backendSnapshot = await backend.snapshot()
    XCTAssertEqual(backendSnapshot.acquireCount, 1)
  }

  func testNetworkLossAfterActivationDoesNotRelease() async throws {
    let fixture = try await activeFixture()

    let status = await fixture.controller.observe(
      network: supervisorNetwork(
        ssid: nil,
        clock: fixture.clock,
        reachable: false,
        internet: .unavailable
      ),
      device: supervisorDevice(clock: fixture.clock)
    )

    guard case .protected = status.verdict else {
      return XCTFail("expected lease continuity, got \(status.verdict)")
    }
    let backendSnapshot = await fixture.backend.snapshot()
    XCTAssertEqual(backendSnapshot.releaseCount, 0)
  }

  func testThermalTripReleasesAndReportsUnsafe() async throws {
    let fixture = try await activeFixture()

    let status = await fixture.controller.observe(
      network: supervisorNetwork(ssid: "iPhone", clock: fixture.clock),
      device: supervisorDevice(
        clock: fixture.clock,
        thermal: .fair,
        lid: .closed
      )
    )

    guard case .unsafe = status.verdict else {
      return XCTFail("expected unsafe verdict, got \(status.verdict)")
    }
    let backendSnapshot = await fixture.backend.snapshot()
    XCTAssertEqual(backendSnapshot.releaseCount, 1)
  }

  func testHelperUnreachableNeverReportsProtected() async throws {
    let fixture = try await activeFixture()
    await fixture.backend.setQueryOverride(.unavailable("xpc unavailable"))

    let status = await fixture.controller.status()

    XCTAssertEqual(status.verdict, .unknown("xpc unavailable"))
  }

  func testHeartbeatRenewsEveryThirtySeconds() async throws {
    let fixture = try await activeFixture()
    fixture.clock.advance(seconds: 30)

    let status = await fixture.controller.tick()

    guard case .protected = status.verdict else {
      return XCTFail("expected protected verdict after renewal, got \(status.verdict)")
    }
    let backendSnapshot = await fixture.backend.snapshot()
    XCTAssertEqual(backendSnapshot.renewCount, 1)
  }

  func testStaleHeartbeatMakesVerdictUnknown() async throws {
    let fixture = try await activeFixture()
    await fixture.backend.setHeartbeatOverride(.unavailable("helper timeout"))
    fixture.clock.advance(seconds: 30)
    _ = await fixture.controller.tick()
    fixture.clock.advance(seconds: 16)

    let status = await fixture.controller.status()

    XCTAssertEqual(status.verdict, .unknown("helper timeout"))
  }

  func testMismatchedLiveLeaseNeverReportsProtected() async throws {
    let fixture = try await activeFixture()
    let now = fixture.clock.now()
    await fixture.backend.setQueryOverride(
      .available(
        SupervisorHelperObservation(
          phase: .active,
          leaseID: UUID(),
          ownerUID: 501,
          sleepOverride: .disabled,
          ttlDeadline: now.adding(.seconds(90)),
          hardDeadline: now.adding(.seconds(5_400)),
          detail: nil
        )
      )
    )

    let status = await fixture.controller.status()

    XCTAssertEqual(
      status.verdict,
      .unknown("helper lease ID does not match the supervisor session")
    )
  }

  func testMismatchedOwnerNeverReportsProtected() async throws {
    let fixture = try await activeFixture()
    let now = fixture.clock.now()
    let sessionID = await fixture.controller.status().trip.sessionID
    await fixture.backend.setQueryOverride(
      .available(
        SupervisorHelperObservation(
          phase: .active,
          leaseID: sessionID,
          ownerUID: 502,
          sleepOverride: .disabled,
          ttlDeadline: now.adding(.seconds(90)),
          hardDeadline: now.adding(.seconds(5_400)),
          detail: nil
        )
      )
    )

    let status = await fixture.controller.status()

    XCTAssertEqual(
      status.verdict,
      .unknown("helper lease owner does not match the supervisor user")
    )
  }

  func testThermalUnknownStopsProtectedClaimThenReleasesAfterGrace() async throws {
    let fixture = try await activeFixture()

    let uncertain = await fixture.controller.observe(
      network: supervisorNetwork(ssid: "iPhone", clock: fixture.clock),
      device: supervisorDevice(
        clock: fixture.clock,
        thermal: .unknown,
        lid: .closed
      )
    )
    guard case .unknown = uncertain.verdict else {
      return XCTFail("expected unknown verdict during grace, got \(uncertain.verdict)")
    }
    let uncertainBackend = await fixture.backend.snapshot()
    XCTAssertEqual(uncertainBackend.releaseCount, 0)

    fixture.clock.advance(seconds: 30)
    let stopped = await fixture.controller.observe(
      network: supervisorNetwork(ssid: "iPhone", clock: fixture.clock),
      device: supervisorDevice(
        clock: fixture.clock,
        thermal: .unknown,
        lid: .closed
      )
    )
    guard case .unsafe = stopped.verdict else {
      return XCTFail("expected unsafe verdict after grace, got \(stopped.verdict)")
    }
    let stoppedBackend = await fixture.backend.snapshot()
    XCTAssertEqual(stoppedBackend.releaseCount, 1)
  }

  func testThirdBatteryFailureReleasesActiveLease() async throws {
    let fixture = try await activeFixture()

    for failure in 1...3 {
      fixture.clock.advance(seconds: 1)
      let status = await fixture.controller.observe(
        network: supervisorNetwork(ssid: "iPhone", clock: fixture.clock),
        device: supervisorDevice(
          clock: fixture.clock,
          battery: nil,
          lid: .closed
        )
      )
      if failure < 3 {
        guard case .unknown = status.verdict else {
          return XCTFail("expected unknown before failure limit, got \(status.verdict)")
        }
      } else {
        guard case .unsafe = status.verdict else {
          return XCTFail("expected unsafe at failure limit, got \(status.verdict)")
        }
      }
    }
    let backend = await fixture.backend.snapshot()
    XCTAssertEqual(backend.releaseCount, 1)
  }

  private func activeFixture() async throws -> (
    controller: SafetySupervisorController,
    backend: FakeSupervisorLeaseBackend,
    clock: SupervisorManualClock
  ) {
    let clock = SupervisorManualClock()
    let backend = FakeSupervisorLeaseBackend(clock: clock)
    let controller = SafetySupervisorController(
      leaseBackend: backend,
      ownerUID: 501,
      clock: clock
    )
    _ = try await controller.start(
      request(),
      originNetwork: supervisorNetwork(ssid: "Office", clock: clock),
      device: supervisorDevice(clock: clock)
    )
    _ = await controller.observe(
      network: supervisorNetwork(ssid: "iPhone", clock: clock),
      device: supervisorDevice(clock: clock)
    )
    return (controller, backend, clock)
  }

  private func request() -> CommuteTripRequest {
    CommuteTripRequest(
      expectedHotspotSSID: "iPhone",
      hardCap: .seconds(90 * 60)
    )
  }
}

@MainActor
final class DirectSafetyLeaseControllerTests: XCTestCase {
  func testImmediateLeaseIsProtectedOnlyAfterLiveHelperCheck() async throws {
    let clock = SupervisorManualClock()
    let backend = FakeSupervisorLeaseBackend(clock: clock)
    let controller = DirectSafetyLeaseController(
      leaseBackend: backend,
      ownerUID: 501,
      clock: clock
    )

    let status = try await controller.start(
      hardCap: .seconds(3_600),
      device: supervisorDevice(clock: clock)
    )

    guard case .protected = status.verdict else {
      return XCTFail("expected protected direct lease, got \(status.verdict)")
    }
  }

  func testDirectAcquisitionRecoveryPendingRemainsObservable() async throws {
    let clock = SupervisorManualClock()
    let backend = FakeSupervisorLeaseBackend(clock: clock)
    await backend.setAcquireOverride(
      .recoveryPending("acquisition rollback is pending")
    )
    let controller = DirectSafetyLeaseController(
      leaseBackend: backend,
      ownerUID: 501,
      clock: clock
    )

    let status = try await controller.start(
      hardCap: .seconds(3_600),
      device: supervisorDevice(clock: clock)
    )

    XCTAssertEqual(status.trip.phase, .recoveryPending)
    guard case .recoveryPending(let detail) = status.verdict else {
      return XCTFail("expected recovery pending, got \(status.verdict)")
    }
    XCTAssertTrue(detail.contains("acquisition rollback is pending"))
  }

  func testDirectLeaseDropsProtectedClaimDuringThermalGraceThenReleases() async throws {
    let clock = SupervisorManualClock()
    let backend = FakeSupervisorLeaseBackend(clock: clock)
    let controller = DirectSafetyLeaseController(
      leaseBackend: backend,
      ownerUID: 501,
      clock: clock
    )
    _ = try await controller.start(
      hardCap: .seconds(3_600),
      device: supervisorDevice(clock: clock)
    )

    let uncertain = await controller.observe(
      device: supervisorDevice(
        clock: clock,
        thermal: .unknown,
        lid: .closed
      )
    )
    guard case .unknown = uncertain.verdict else {
      return XCTFail("expected unknown verdict, got \(uncertain.verdict)")
    }

    clock.advance(seconds: 30)
    let stopped = await controller.observe(
      device: supervisorDevice(
        clock: clock,
        thermal: .unknown,
        lid: .closed
      )
    )
    guard case .unsafe = stopped.verdict else {
      return XCTFail("expected unsafe verdict, got \(stopped.verdict)")
    }
    let backendSnapshot = await backend.snapshot()
    XCTAssertEqual(backendSnapshot.releaseCount, 1)
  }

  func testDirectLeaseUserStopReleases() async throws {
    let clock = SupervisorManualClock()
    let backend = FakeSupervisorLeaseBackend(clock: clock)
    let controller = DirectSafetyLeaseController(
      leaseBackend: backend,
      ownerUID: 501,
      clock: clock
    )
    _ = try await controller.start(
      hardCap: .seconds(3_600),
      device: supervisorDevice(clock: clock)
    )

    let status = await controller.stop()

    XCTAssertEqual(status.trip.phase, .ended)
    let backendSnapshot = await backend.snapshot()
    XCTAssertEqual(backendSnapshot.releaseCount, 1)
  }
}

@MainActor
final class DeskModeControllerTests: XCTestCase {
  func testOpenDeskModeUsesProcessOwnedAssertion() async throws {
    let clock = SupervisorManualClock()
    let backend = FakeSupervisorLeaseBackend(clock: clock)
    let assertion = FakeUserPowerAssertionBackend()
    let controller = DeskModeController(
      directController: DirectSafetyLeaseController(
        leaseBackend: backend,
        ownerUID: 501,
        clock: clock
      ),
      assertionBackend: assertion,
      clock: clock
    )

    let status = try await controller.start(
      allowClosedLid: false,
      hardCap: .seconds(3_600),
      device: supervisorDevice(clock: clock, lid: .open)
    )

    guard case .protected = status.verdict else {
      return XCTFail("expected protected assertion, got \(status.verdict)")
    }
    let allowsClosedLid = await controller.allowsClosedLid()
    XCTAssertFalse(allowsClosedLid)
    let assertionSnapshot = await assertion.snapshot()
    let backendSnapshot = await backend.snapshot()
    XCTAssertEqual(assertionSnapshot.acquireCount, 1)
    XCTAssertEqual(backendSnapshot.acquireCount, 0)
  }

  func testOpenDeskModeReleasesIfLidCloses() async throws {
    let clock = SupervisorManualClock()
    let assertion = FakeUserPowerAssertionBackend()
    let controller = DeskModeController(
      directController: DirectSafetyLeaseController(
        leaseBackend: FakeSupervisorLeaseBackend(clock: clock),
        ownerUID: 501,
        clock: clock
      ),
      assertionBackend: assertion,
      clock: clock
    )
    _ = try await controller.start(
      allowClosedLid: false,
      hardCap: .seconds(3_600),
      device: supervisorDevice(clock: clock, lid: .open)
    )

    let status = await controller.observe(
      device: supervisorDevice(clock: clock, lid: .closed)
    )

    guard case .unsafe = status.verdict else {
      return XCTFail("expected unsafe closed-lid status, got \(status.verdict)")
    }
    let assertionSnapshot = await assertion.snapshot()
    XCTAssertEqual(assertionSnapshot.releaseCount, 1)
  }

  func testOpenDeskModeRetriesFailedAssertionRelease() async throws {
    let clock = SupervisorManualClock()
    let assertion = FlakyUserPowerAssertionBackend(releaseFailures: 1)
    let controller = DeskModeController(
      directController: DirectSafetyLeaseController(
        leaseBackend: FakeSupervisorLeaseBackend(clock: clock),
        ownerUID: 501,
        clock: clock
      ),
      assertionBackend: assertion,
      clock: clock
    )
    _ = try await controller.start(
      allowClosedLid: false,
      hardCap: .seconds(3_600),
      device: supervisorDevice(clock: clock, lid: .open)
    )

    let failed = await controller.stop()
    let pending = await controller.status()
    let afterFailure = await assertion.snapshot()

    XCTAssertEqual(failed.trip.phase, .recoveryPending)
    XCTAssertEqual(pending.trip.phase, .recoveryPending)
    XCTAssertEqual(afterFailure.releaseAttempts, 1)
    XCTAssertTrue(afterFailure.isActive)

    let recovered = await controller.retryPendingRelease()
    let afterRetry = await assertion.snapshot()

    XCTAssertEqual(recovered.trip.phase, .ended)
    XCTAssertEqual(afterRetry.releaseAttempts, 2)
    XCTAssertFalse(afterRetry.isActive)
  }

  func testClosedDeskModeUsesPrivilegedFiniteLease() async throws {
    let clock = SupervisorManualClock()
    let backend = FakeSupervisorLeaseBackend(clock: clock)
    let controller = DeskModeController(
      directController: DirectSafetyLeaseController(
        leaseBackend: backend,
        ownerUID: 501,
        clock: clock
      ),
      assertionBackend: FakeUserPowerAssertionBackend(),
      clock: clock
    )

    let status = try await controller.start(
      allowClosedLid: true,
      hardCap: .seconds(3_600),
      device: supervisorDevice(clock: clock, lid: .open)
    )

    guard case .protected = status.verdict else {
      return XCTFail("expected protected lease, got \(status.verdict)")
    }
    let allowsClosedLid = await controller.allowsClosedLid()
    let backendSnapshot = await backend.snapshot()
    XCTAssertTrue(allowsClosedLid)
    XCTAssertEqual(backendSnapshot.acquireCount, 1)
  }

  func testClosedDeskKeepsAcquisitionRecoveryVisible() async throws {
    let clock = SupervisorManualClock()
    let backend = FakeSupervisorLeaseBackend(clock: clock)
    await backend.setAcquireOverride(
      .recoveryPending("acquisition rollback is pending")
    )
    let controller = DeskModeController(
      directController: DirectSafetyLeaseController(
        leaseBackend: backend,
        ownerUID: 501,
        clock: clock
      ),
      assertionBackend: FakeUserPowerAssertionBackend(),
      clock: clock
    )

    let started = try await controller.start(
      allowClosedLid: true,
      hardCap: .seconds(3_600),
      device: supervisorDevice(clock: clock, lid: .open)
    )
    let current = await controller.status()
    let allowsClosedLid = await controller.allowsClosedLid()

    XCTAssertEqual(started.trip.phase, .recoveryPending)
    XCTAssertEqual(current.trip.phase, .recoveryPending)
    XCTAssertTrue(allowsClosedLid)
  }
}

private actor FakeUserPowerAssertionBackend: UserPowerAssertionBackend {
  struct Snapshot: Sendable {
    let acquireCount: Int
    let releaseCount: Int
  }

  private var acquireCount = 0
  private var releaseCount = 0
  private var active: UserPowerAssertionToken?

  func acquire(reason: String) async throws -> UserPowerAssertionToken {
    acquireCount += 1
    let token = UserPowerAssertionToken(rawValue: UInt32(acquireCount))
    active = token
    return token
  }

  func release(_ token: UserPowerAssertionToken) async throws {
    guard active == token else {
      throw UserPowerAssertionError.invalidToken
    }
    releaseCount += 1
    active = nil
  }

  func snapshot() -> Snapshot {
    Snapshot(acquireCount: acquireCount, releaseCount: releaseCount)
  }
}

private actor FlakyUserPowerAssertionBackend: UserPowerAssertionBackend {
  struct Snapshot: Sendable {
    let releaseAttempts: Int
    let isActive: Bool
  }

  private var remainingReleaseFailures: Int
  private var releaseAttempts = 0
  private var active: UserPowerAssertionToken?

  init(releaseFailures: Int) {
    self.remainingReleaseFailures = releaseFailures
  }

  func acquire(reason: String) async throws -> UserPowerAssertionToken {
    let token = UserPowerAssertionToken(rawValue: 1)
    active = token
    return token
  }

  func release(_ token: UserPowerAssertionToken) async throws {
    guard active == token else {
      throw UserPowerAssertionError.invalidToken
    }
    releaseAttempts += 1
    if remainingReleaseFailures > 0 {
      remainingReleaseFailures -= 1
      throw UserPowerAssertionError.systemFailure(-1)
    }
    active = nil
  }

  func snapshot() -> Snapshot {
    Snapshot(releaseAttempts: releaseAttempts, isActive: active != nil)
  }
}

private actor FakeSupervisorLeaseBackend: SupervisorLeaseBackend {
  struct Snapshot: Sendable {
    let acquireCount: Int
    let renewCount: Int
    let releaseCount: Int
  }

  private let clock: SupervisorManualClock
  private var observation: SupervisorHelperObservation
  private var queryOverride: SupervisorHelperQuery?
  private var heartbeatOverride: SupervisorHeartbeatResult?
  private var acquireOverride: LeaseAcquisitionOutcome?
  private var acquireCount = 0
  private var renewCount = 0
  private var releaseCount = 0

  init(clock: SupervisorManualClock) {
    self.clock = clock
    self.observation = SupervisorHelperObservation(
      phase: .idle,
      leaseID: nil,
      ownerUID: nil,
      sleepOverride: .normal,
      ttlDeadline: nil,
      hardDeadline: nil,
      detail: nil
    )
  }

  func acquire(sessionID: UUID, hardCap: Duration) async -> LeaseAcquisitionOutcome {
    acquireCount += 1
    if let acquireOverride {
      return acquireOverride
    }
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
    renewCount += 1
    if let heartbeatOverride {
      return heartbeatOverride
    }
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
    queryOverride ?? .available(observation)
  }

  func releaseExistingOwnedLease() async -> LeaseReleaseOutcome {
    guard let leaseID = observation.leaseID, observation.ownerUID == 501 else {
      return .released
    }
    return await release(
      sessionID: leaseID,
      lease: LeaseToken(id: leaseID),
      reason: .superseded
    )
  }

  func setQueryOverride(_ result: SupervisorHelperQuery?) {
    queryOverride = result
  }

  func setHeartbeatOverride(_ result: SupervisorHeartbeatResult?) {
    heartbeatOverride = result
  }

  func setAcquireOverride(_ result: LeaseAcquisitionOutcome?) {
    acquireOverride = result
  }

  func snapshot() -> Snapshot {
    Snapshot(
      acquireCount: acquireCount,
      renewCount: renewCount,
      releaseCount: releaseCount
    )
  }
}

private final class SupervisorManualClock: @unchecked Sendable, MonotonicTimeSource {
  private let lock = NSLock()
  private var nanoseconds: UInt64 = 1_000_000_000

  func now() -> MonotonicInstant {
    lock.lock()
    defer { lock.unlock() }
    return MonotonicInstant(uptimeNanoseconds: nanoseconds)
  }

  func advance(seconds: UInt64) {
    lock.lock()
    nanoseconds += seconds * 1_000_000_000
    lock.unlock()
  }
}

private func supervisorNetwork(
  ssid: String?,
  clock: SupervisorManualClock,
  reachable: Bool = true,
  internet: InternetReachability = .confirmed
) -> NetworkSnapshot {
  NetworkSnapshot(
    ssid: ssid,
    interfaceName: "en0",
    routeReachable: reachable,
    internetReachability: internet,
    capturedAt: clock.now()
  )
}

private func supervisorDevice(
  clock: SupervisorManualClock,
  battery: Int? = 80,
  thermal: ThermalLevel = .nominal,
  lid: LidState = .open
) -> DeviceSafetySnapshot {
  DeviceSafetySnapshot(
    batteryPercent: battery,
    powerConnection: .battery,
    thermalLevel: thermal,
    lidState: lid,
    externalDisplayState: .absent,
    lowPowerModeEnabled: false,
    capturedAt: clock.now()
  )
}
