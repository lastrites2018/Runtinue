import Foundation
import IOKit.pwr_mgt
import RuntinueCore
import RuntinueSupervisorCore
import XCTest

@testable import RuntinueSystem

// These tests run the production backend and Desk controller, replacing only the
// synchronous IOKit calls. They never create a real power assertion on the runner.
@MainActor
final class TimedDisplayAssertionTests: XCTestCase {
  func testOpenTimedSessionRequestsDisplayPreventionAndReleasesOnStop() async throws {
    let fixture = Fixture()
    let started = try await fixture.start()
    XCTAssertEqual(started.verdict, .protected(remaining: .seconds(60)))
    let calls = fixture.calls.snapshot()
    XCTAssertEqual(calls.creates.count, 1)
    XCTAssertEqual(calls.creates.first?.type, kIOPMAssertionTypePreventUserIdleDisplaySleep as String)
    XCTAssertEqual(calls.creates.first?.level, IOPMAssertionLevel(kIOPMAssertionLevelOn))
    XCTAssertEqual(calls.creates.first?.reason, "Runtinue desk mode")
    XCTAssertTrue(calls.releases.isEmpty)
    let privilegedAcquires = await fixture.lease.acquireCount
    XCTAssertEqual(privilegedAcquires, 0)

    let stopped = await fixture.controller.stop()
    XCTAssertEqual(stopped.trip.phase, .ended)
    XCTAssertEqual(stopped.trip.stopReason, .userRequested)
    XCTAssertEqual(stopped.verdict, .inactive)
    XCTAssertEqual(fixture.calls.snapshot().releases, [101])
    _ = await fixture.controller.stop()
    XCTAssertEqual(fixture.calls.snapshot().releases, [101])
  }

  func testDeadlineReleasesTheDisplayAssertionWithoutReleasingEarly() async throws {
    let fixture = Fixture()
    _ = try await fixture.start()
    fixture.clock.advance(seconds: 59)
    let active = await fixture.controller.observe(device: fixture.device())
    XCTAssertEqual(active.verdict, .protected(remaining: .seconds(1)))
    XCTAssertTrue(fixture.calls.snapshot().releases.isEmpty)

    fixture.clock.advance(seconds: 1)
    let ended = await fixture.controller.observe(device: fixture.device())
    XCTAssertEqual(ended.trip.phase, .ended)
    XCTAssertEqual(ended.trip.stopReason, .hardDeadlineReached)
    XCTAssertEqual(ended.verdict, .inactive)
    XCTAssertEqual(fixture.calls.snapshot().releases, [101])
  }

  func testMaximumTimedSessionDurationIsAccepted() async throws {
    let fixture = Fixture()
    let started = try await fixture.controller.start(
      allowClosedLid: false,
      hardCap: CommuteTripRequest.maximumHardCap,
      device: fixture.device()
    )

    XCTAssertEqual(
      started.verdict,
      .protected(remaining: CommuteTripRequest.maximumHardCap)
    )
    _ = await fixture.controller.stop()
  }

  func testOpenTimedSessionStopsWhenBatteryFallsBelowTheSafetyFloor() async throws {
    let fixture = Fixture()
    _ = try await fixture.start()
    fixture.clock.advance(seconds: 5)

    let stopped = await fixture.controller.observe(device: fixture.device(battery: 9))

    XCTAssertEqual(stopped.trip.phase, .ended)
    XCTAssertEqual(
      stopped.trip.stopReason,
      .safety(.batteryBelowFloor(observed: 9, floor: 10))
    )
    guard case .unsafe = stopped.verdict else {
      return XCTFail("expected unsafe battery status, got \(stopped.verdict)")
    }
    XCTAssertEqual(fixture.calls.snapshot().releases, [101])
  }

  func testSafetyStopAndLidClosureStillReleaseTheDisplayAssertion() async throws {
    let conditions: [(ThermalLevel, LidState)] = [(.critical, .open), (.nominal, .closed)]
    for (thermal, lid) in conditions {
      let fixture = Fixture()
      _ = try await fixture.start()
      fixture.clock.advance(seconds: 5)
      let stopped = await fixture.controller.observe(
        device: fixture.device(thermal: thermal, lid: lid))
      XCTAssertEqual(stopped.trip.phase, .ended)
      guard case .unsafe = stopped.verdict else {
        return XCTFail("expected safety stop, got \(stopped.verdict)")
      }
      XCTAssertEqual(fixture.calls.snapshot().releases, [101])
    }
  }

  func testFailedCreationIsNotReportedAsProtectedAndNeverFallsBackToSystemOnly() async throws {
    let fixture = Fixture(createResults: [kIOReturnError, kIOReturnSuccess])
    do {
      _ = try await fixture.start()
      XCTFail("creation failure must reject the session")
    } catch let error as DeskModeError {
      guard case .assertionFailure = error else { return XCTFail("unexpected error: \(error)") }
    }
    let failedStatus = await fixture.controller.status()
    XCTAssertEqual(failedStatus.verdict, .inactive)
    XCTAssertTrue(fixture.calls.snapshot().releases.isEmpty)

    let retry = try await fixture.start()
    XCTAssertEqual(retry.verdict, .protected(remaining: .seconds(60)))
    XCTAssertEqual(
      fixture.calls.snapshot().creates.map(\.type),
      Array(repeating: kIOPMAssertionTypePreventUserIdleDisplaySleep as String, count: 2))
    _ = await fixture.controller.stop()
    XCTAssertEqual(fixture.calls.snapshot().releases, [101])
  }

  func testFailedReleaseRetainsTheTokenUntilControllerRecoverySucceeds() async throws {
    let fixture = Fixture(releaseResults: [kIOReturnError, kIOReturnSuccess])
    _ = try await fixture.start()
    let failed = await fixture.controller.stop()
    XCTAssertEqual(failed.trip.phase, .recoveryPending)
    XCTAssertEqual(fixture.calls.snapshot().releases, [101])
    do {
      _ = try await fixture.backend.acquire(reason: "must not replace the pending assertion")
      XCTFail("pending assertion must block acquisition")
    } catch {
      XCTAssertEqual(error as? UserPowerAssertionError, .alreadyActive)
    }
    XCTAssertEqual(fixture.calls.snapshot().creates.count, 1)

    let recovered = await fixture.controller.retryPendingRelease()
    XCTAssertEqual(recovered.trip.phase, .ended)
    XCTAssertEqual(recovered.verdict, .inactive)
    XCTAssertEqual(fixture.calls.snapshot().releases, [101, 101])
    _ = try await fixture.start()
    _ = await fixture.controller.stop()
    XCTAssertEqual(fixture.calls.snapshot().releases, [101, 101, 102])
  }

  func testInvalidTokenCannotReleaseTheDisplayAssertion() async throws {
    let fixture = Fixture()
    let token = try await fixture.backend.acquire(reason: "token fixture")
    do {
      try await fixture.backend.release(UserPowerAssertionToken(rawValue: token.rawValue + 1))
      XCTFail("wrong token must not reach IOKit")
    } catch {
      XCTAssertEqual(error as? UserPowerAssertionError, .invalidToken)
    }
    XCTAssertTrue(fixture.calls.snapshot().releases.isEmpty)
    try await fixture.backend.release(token)
    XCTAssertEqual(fixture.calls.snapshot().releases, [token.rawValue])
  }

  func testClosedLidSessionKeepsUsingOnlyThePrivilegedLeasePath() async throws {
    let fixture = Fixture()
    let started = try await fixture.controller.start(
      allowClosedLid: true, hardCap: .seconds(60), device: fixture.device())
    XCTAssertEqual(started.verdict, .protected(remaining: .seconds(60)))
    let privilegedAcquires = await fixture.lease.acquireCount
    XCTAssertEqual(privilegedAcquires, 1)
    XCTAssertTrue(fixture.calls.snapshot().creates.isEmpty)
    _ = await fixture.controller.stop()
    XCTAssertTrue(fixture.calls.snapshot().releases.isEmpty)
  }

  func testClosedLidTimedSessionStopsForBatteryAndThermalSafetyLimits() async throws {
    let cases: [(battery: Int, thermal: ThermalLevel, reason: DeviceSafetyStopReason)] = [
      (29, .nominal, .batteryBelowFloor(observed: 29, floor: 30)),
      (80, .fair, .thermalLimitReached(observed: .fair, cutoff: .fair)),
    ]

    for testCase in cases {
      let fixture = Fixture()
      _ = try await fixture.controller.start(
        allowClosedLid: true,
        hardCap: .seconds(60),
        device: fixture.device(lid: .closed)
      )
      fixture.clock.advance(seconds: 5)

      let stopped = await fixture.controller.observe(
        device: fixture.device(
          battery: testCase.battery,
          thermal: testCase.thermal,
          lid: .closed
        )
      )

      XCTAssertEqual(stopped.trip.phase, .ended)
      XCTAssertEqual(stopped.trip.stopReason, .safety(testCase.reason))
      guard case .unsafe = stopped.verdict else {
        return XCTFail("expected unsafe safety status, got \(stopped.verdict)")
      }
      let releaseCount = await fixture.lease.releaseCount
      XCTAssertEqual(releaseCount, 1)
      XCTAssertTrue(fixture.calls.snapshot().releases.isEmpty)
    }
  }
}

private struct Fixture {
  let clock = DisplayTestClock()
  let calls: RecordingIOPMCalls
  let backend: IOPMUserPowerAssertionBackend
  let lease: DisplayTestLeaseBackend
  let controller: DeskModeController

  init(createResults: [IOReturn] = [], releaseResults: [IOReturn] = []) {
    calls = RecordingIOPMCalls(createResults: createResults, releaseResults: releaseResults)
    backend = IOPMUserPowerAssertionBackend(operations: calls.operations)
    lease = DisplayTestLeaseBackend(clock: clock)
    controller = DeskModeController(
      directController: DirectSafetyLeaseController(leaseBackend: lease, ownerUID: 501, clock: clock),
      assertionBackend: backend, clock: clock)
  }

  func start() async throws -> SupervisorStatus {
    try await controller.start(allowClosedLid: false, hardCap: .seconds(60), device: device())
  }

  func device(
    battery: Int? = 80,
    thermal: ThermalLevel = .nominal,
    lid: LidState = .open
  ) -> DeviceSafetySnapshot {
    DeviceSafetySnapshot(
      batteryPercent: battery, powerConnection: .battery, thermalLevel: thermal,
      lidState: lid, externalDisplayState: .absent, lowPowerModeEnabled: false,
      capturedAt: clock.now())
  }
}

private final class RecordingIOPMCalls: @unchecked Sendable {
  struct Creation: Sendable {
    let type: String
    let level: IOPMAssertionLevel
    let reason: String
  }

  struct Snapshot: Sendable {
    let creates: [Creation]
    let releases: [IOPMAssertionID]
  }

  private let lock = NSLock()
  private var creates: [Creation] = []
  private var releases: [IOPMAssertionID] = []
  private var createResults: [IOReturn]
  private var releaseResults: [IOReturn]
  private var nextID: IOPMAssertionID = 101

  init(createResults: [IOReturn], releaseResults: [IOReturn]) {
    self.createResults = createResults
    self.releaseResults = releaseResults
  }

  var operations: IOPMAssertionOperations {
    IOPMAssertionOperations(
      create: { [self] type, level, reason, id in
        lock.lock()
        defer { lock.unlock() }
        creates.append(Creation(type: type as String, level: level, reason: reason as String))
        let result = createResults.isEmpty ? kIOReturnSuccess : createResults.removeFirst()
        if result == kIOReturnSuccess {
          id.pointee = nextID
          nextID += 1
        }
        return result
      },
      release: { [self] id in
        lock.lock()
        defer { lock.unlock() }
        releases.append(id)
        return releaseResults.isEmpty ? kIOReturnSuccess : releaseResults.removeFirst()
      })
  }

  func snapshot() -> Snapshot {
    lock.lock()
    defer { lock.unlock() }
    return Snapshot(creates: creates, releases: releases)
  }
}

private final class DisplayTestClock: @unchecked Sendable, MonotonicTimeSource {
  private let lock = NSLock()
  private var nanoseconds: UInt64 = 1_000_000_000

  func now() -> MonotonicInstant {
    lock.lock()
    defer { lock.unlock() }
    return MonotonicInstant(continuousNanoseconds: nanoseconds)
  }

  func advance(seconds: UInt64) {
    lock.lock()
    defer { lock.unlock() }
    nanoseconds += seconds * 1_000_000_000
  }
}

private actor DisplayTestLeaseBackend: SupervisorLeaseBackend {
  private let clock: DisplayTestClock
  private var observation: SupervisorHelperObservation?
  private(set) var acquireCount = 0
  private(set) var releaseCount = 0

  init(clock: DisplayTestClock) { self.clock = clock }

  func acquire(sessionID: UUID, hardCap: Duration) async -> LeaseAcquisitionOutcome {
    acquireCount += 1
    observation = SupervisorHelperObservation(
      phase: .active, leaseID: sessionID, ownerUID: 501, sleepOverride: .disabled,
      ttlDeadline: clock.now().adding(.seconds(90)), hardDeadline: clock.now().adding(hardCap),
      detail: nil)
    return .acquired(LeaseToken(id: sessionID))
  }

  func release(sessionID: UUID, lease: LeaseToken, reason: TripStopReason) async -> LeaseReleaseOutcome {
    releaseCount += 1
    observation = nil
    return .released
  }

  func renew(leaseID: UUID, ttl: Duration) async -> SupervisorHeartbeatResult {
    .rejected("not used in this fixture")
  }

  func liveStatus() async -> SupervisorHelperQuery {
    .available(observation ?? SupervisorHelperObservation(
      phase: .idle, leaseID: nil, ownerUID: nil, sleepOverride: .normal,
      ttlDeadline: nil, hardDeadline: nil, detail: nil))
  }

  func releaseExistingOwnedLease() async -> LeaseReleaseOutcome {
    observation = nil
    return .released
  }
}
