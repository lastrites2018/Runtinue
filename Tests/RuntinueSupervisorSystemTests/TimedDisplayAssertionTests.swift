import Foundation
import IOKit.pwr_mgt
import RuntinueCore
import RuntinueIPC
import RuntinueSupervisorCore
import RuntinueSupervisorSystem
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
    XCTAssertEqual(calls.readbacks, [101])
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
    XCTAssertTrue(fixture.calls.snapshot().readbacks.isEmpty)

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

  func testCreationSuccessWithUnconfirmedReadbackRejectsStartAndReleasesOrRecovers() async throws {
    let unconfirmed: [RecordingIOPMCalls.Readback] = [
      .unavailable, .off, .wrongType, .missingType, .missingLevel,
    ]
    for readback in unconfirmed {
      for releaseFails in [false, true] {
        let fixture = Fixture(releaseResults: releaseFails ? [kIOReturnError] : [])
        fixture.calls.setReadback(readback)
        do {
          _ = try await fixture.controller.start(
            allowClosedLid: false, hardCap: CommuteTripRequest.maximumHardCap,
            device: fixture.device())
          XCTFail("an unconfirmed assertion must reject the start request")
        } catch let error as DeskModeError {
          XCTAssertEqual(error, .protectionNotConfirmed)
          // The controller must keep any remaining release responsibility after
          // rejecting activation.
        } catch {
          XCTFail("unexpected start error: \(error)")
        }
        let started = await fixture.controller.status()
        XCTAssertEqual(started.trip.phase, releaseFails ? .recoveryPending : .ended)
        XCTAssertEqual(fixture.calls.snapshot().readbacks, [101])
        XCTAssertEqual(fixture.calls.snapshot().releases, [101])
        if releaseFails {
          do {
            _ = try await fixture.backend.acquire(reason: "unreleased ownership cannot be replaced")
            XCTFail("failed release must retain the owned assertion")
          } catch {
            XCTAssertEqual(error as? UserPowerAssertionError, .alreadyActive)
          }
          do {
            _ = try await fixture.start()
            XCTFail("recovery must block a replacement session")
          } catch {
            XCTAssertEqual(error as? DeskModeError, .sessionAlreadyRunning)
          }
        }
        fixture.calls.setReadback(.created)
        let afterReadbackRecovers = await fixture.controller.status()
        XCTAssertEqual(afterReadbackRecovers.trip.phase, started.trip.phase)
        XCTAssertEqual(fixture.calls.snapshot().readbacks, [101])
        let ended = await fixture.controller.retryPendingRelease()
        XCTAssertEqual(ended.trip.phase, .ended)
        XCTAssertEqual(ended.verdict, .inactive)
        XCTAssertEqual(
          ended.trip.stopReason, .leaseRejected("desk display assertion is not confirmed active"))
        XCTAssertEqual(fixture.calls.snapshot().releases, releaseFails ? [101, 101] : [101])
        let restarted = try await fixture.start()
        XCTAssertNotEqual(restarted.trip.sessionID, started.trip.sessionID)
        XCTAssertEqual(restarted.verdict, .protected(remaining: .seconds(60)))
        _ = await fixture.controller.stop()
      }
    }
  }

  func testObservationAndStatusQueryReleaseInsteadOfReusingEarlierProtection() async throws {
    let unconfirmed: [RecordingIOPMCalls.Readback] = [
      .unavailable, .off, .wrongType, .missingType, .missingLevel,
    ]
    for readback in unconfirmed {
      for useObservation in [false, true] {
        for releaseFails in [false, true] {
          let fixture = Fixture(releaseResults: releaseFails ? [kIOReturnError] : [])
          _ = try await fixture.start()
          fixture.calls.setReadback(readback)
          let stopped = useObservation
            ? await fixture.controller.observe(device: fixture.device())
            : await fixture.controller.status()
          XCTAssertEqual(stopped.trip.phase, releaseFails ? .recoveryPending : .ended)
          XCTAssertEqual(fixture.calls.snapshot().readbacks, [101, 101])
          XCTAssertEqual(fixture.calls.snapshot().releases, [101])
          // Even a manual retry must preserve the original verification failure.
          let ended = await fixture.controller.stop()
          XCTAssertEqual(ended.trip.phase, .ended)
          XCTAssertEqual(ended.verdict, .inactive)
          XCTAssertEqual(
            ended.trip.stopReason, .leaseRejected("desk display assertion is not confirmed active"))
          XCTAssertEqual(fixture.calls.snapshot().releases, releaseFails ? [101, 101] : [101])
        }
      }
    }
  }

  func testInvalidReadbackTokenDoesNotQueryAnotherAssertion() async throws {
    let fixture = Fixture()
    let token = try await fixture.backend.acquire(reason: "readback ownership fixture")
    do {
      _ = try await fixture.backend.isActive(UserPowerAssertionToken(rawValue: token.rawValue + 1))
      XCTFail("an invalid token must not reach the readback boundary")
    } catch {
      XCTAssertEqual(error as? UserPowerAssertionError, .invalidToken)
    }
    XCTAssertTrue(fixture.calls.snapshot().readbacks.isEmpty)
    try await fixture.backend.release(token)
  }

  func testUnconfirmedReadbackCannotSuppressExpiryOrSafetyReleaseAndRecovery() async throws {
    for expires in [true, false] {
      let fixture = Fixture(releaseResults: [kIOReturnError, kIOReturnSuccess])
      _ = try await fixture.start()
      fixture.calls.setReadback(.unavailable)
      fixture.clock.advance(seconds: expires ? 60 : 5)
      let pending = await fixture.controller.observe(
        device: fixture.device(thermal: expires ? .nominal : .critical))
      XCTAssertEqual(pending.trip.phase, .recoveryPending)
      guard case .recoveryPending = pending.verdict else {
        return XCTFail("a failed release must remain visible")
      }
      XCTAssertEqual(fixture.calls.snapshot().releases, [101])
      let recovered = await fixture.controller.retryPendingRelease()
      XCTAssertEqual(recovered.trip.phase, .ended)
      if expires {
        XCTAssertEqual(recovered.trip.stopReason, .hardDeadlineReached)
        XCTAssertEqual(recovered.verdict, .inactive)
      } else {
        guard case .safety = recovered.trip.stopReason, case .unsafe = recovered.verdict else {
          return XCTFail("recovery must preserve the original safety stop")
        }
      }
      XCTAssertEqual(fixture.calls.snapshot().releases, [101, 101])
    }
  }

  func testLateReadbackCannotResurrectAStoppedSessionOrConfirmItsReplacement() async throws {
    for startsReplacement in [false, true] {
      let fixture = Fixture()
      let backend = DelayedReadbackBackend()
      let controller = DeskModeController(
        directController: DirectSafetyLeaseController(
          leaseBackend: fixture.lease, ownerUID: 501, clock: fixture.clock),
        assertionBackend: backend, clock: fixture.clock)
      let original = try await controller.start(
        allowClosedLid: false, hardCap: .seconds(60), device: fixture.device())
      await backend.blockNextReadback()
      let reading = Task { await controller.status() }
      await backend.waitUntilReadbackIsBlocked()
      _ = await controller.stop()
      if startsReplacement {
        await backend.setConfirmed(false)
        do {
          _ = try await controller.start(
            allowClosedLid: false, hardCap: .seconds(60), device: fixture.device())
          XCTFail("an unconfirmed replacement must reject the start request")
        } catch let error as DeskModeError {
          XCTAssertEqual(error, .protectionNotConfirmed)
        }
      }
      await backend.finishReadback()
      let result = await reading.value
      XCTAssertEqual(result.trip.phase, .ended)
      XCTAssertEqual(result.verdict, .inactive)
      if startsReplacement {
        XCTAssertNotEqual(result.trip.sessionID, original.trip.sessionID)
        XCTAssertEqual(
          result.trip.stopReason, .leaseRejected("desk display assertion is not confirmed active"))
      } else {
        XCTAssertEqual(result.trip.sessionID, original.trip.sessionID)
        XCTAssertEqual(result.trip.stopReason, .userRequested)
      }
    }
  }

  func testPositiveReadbackCannotOutliveAnInFlightRelease() async throws {
    for releaseFails in [false, true] {
      let fixture = Fixture()
      let backend = DelayedReadbackBackend()
      let controller = DeskModeController(
        directController: DirectSafetyLeaseController(
          leaseBackend: fixture.lease, ownerUID: 501, clock: fixture.clock),
        assertionBackend: backend, clock: fixture.clock)
      _ = try await controller.start(
        allowClosedLid: false, hardCap: .seconds(60), device: fixture.device())
      await backend.blockNextReadback()
      let reading = Task { await controller.status() }
      await backend.waitUntilReadbackIsBlocked()
      await backend.blockNextRelease(failing: releaseFails)
      let stopping = Task { await controller.stop() }
      await backend.waitUntilReleaseIsBlocked()

      // On success, the backend has already removed the assertion, but the
      // controller has not received the release response. Deliver the older read.
      await backend.finishReadback()
      let lateRead = await reading.value
      XCTAssertEqual(lateRead.trip.phase, .releasingLease)
      XCTAssertEqual(lateRead.verdict, .releasing(.userRequested))
      let concurrentResults = [
        await controller.status(),
        await controller.stop(),
        await controller.observe(device: fixture.device(thermal: .critical)),
        await controller.retryPendingRelease(),
        await controller.reconcileRecovery(),
      ]
      for result in concurrentResults {
        XCTAssertEqual(result.trip.phase, .releasingLease)
        XCTAssertEqual(result.verdict, .releasing(.userRequested))
      }
      let releaseAttempts = await backend.releaseAttempts
      XCTAssertEqual(releaseAttempts, 1)
      do {
        _ = try await controller.start(
          allowClosedLid: false, hardCap: .seconds(60), device: fixture.device())
        XCTFail("an in-flight release must block replacement")
      } catch {
        XCTAssertEqual(error as? DeskModeError, .sessionAlreadyRunning)
      }
      await backend.finishRelease()
      let released = await stopping.value
      XCTAssertEqual(released.trip.phase, releaseFails ? .recoveryPending : .ended)
      let recovered = await controller.retryPendingRelease()
      XCTAssertEqual(recovered.trip.phase, .ended)
      XCTAssertEqual(recovered.trip.stopReason, .userRequested)
      let finalAttempts = await backend.releaseAttempts
      XCTAssertEqual(finalAttempts, releaseFails ? 2 : 1)
    }
  }

  func testInFlightReleaseCannotPublishAnOldProtectedReadToWireOrCache() async throws {
    let fixture = Fixture()
    let backend = DelayedReadbackBackend()
    let cache = DisplayRuntimeCache()
    let runtime = SupervisorRuntime(
      backend: fixture.lease,
      sampler: DisplayRuntimeSampler(device: fixture.device(), clock: fixture.clock),
      statusCache: cache, powerAssertionBackend: backend, ownerUID: 501,
      clock: fixture.clock, automaticMonitoring: false)
    let started = try await runtime.enableDesk(allowClosedLid: false, hardCap: .seconds(60))
    XCTAssertEqual(started.verdict, .protected)
    await backend.blockNextReadback()
    let reading = Task { await runtime.currentStatus() }
    await backend.waitUntilReadbackIsBlocked()
    await backend.blockNextRelease()
    let stopping = Task { try await runtime.disableDesk() }
    await backend.waitUntilReleaseIsBlocked()
    await backend.finishReadback()
    let lateRead = await reading.value
    let cached = try await cache.load()
    XCTAssertEqual(lateRead.phase, .releasingLease)
    XCTAssertEqual(lateRead.verdict, .releasing)
    XCTAssertEqual(lateRead.sessionID, started.sessionID)
    XCTAssertFalse(lateRead.closedLidAllowed)
    XCTAssertEqual(cached?.phase, .releasingLease)
    XCTAssertEqual(cached?.verdict, .releasing)
    await backend.finishRelease()
    let stopped = try await stopping.value
    XCTAssertEqual(stopped.phase, .ended)
    XCTAssertEqual(stopped.mode, .none)
    XCTAssertEqual(stopped.verdict, .inactive)
    let attempts = await backend.releaseAttempts
    XCTAssertEqual(attempts, 1)
  }

  func testClosedLidSessionKeepsUsingOnlyThePrivilegedLeasePath() async throws {
    let fixture = Fixture()
    let started = try await fixture.controller.start(
      allowClosedLid: true, hardCap: .seconds(60), device: fixture.device())
    XCTAssertEqual(started.verdict, .protected(remaining: .seconds(60)))
    let privilegedAcquires = await fixture.lease.acquireCount
    XCTAssertEqual(privilegedAcquires, 1)
    XCTAssertTrue(fixture.calls.snapshot().creates.isEmpty)
    XCTAssertTrue(fixture.calls.snapshot().readbacks.isEmpty)
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
  enum Readback: Sendable {
    case created, unavailable, off, wrongType, missingType, missingLevel
  }

  struct Creation: Sendable {
    let type: String
    let level: IOPMAssertionLevel
    let reason: String
  }

  struct Snapshot: Sendable {
    let creates: [Creation]
    let releases: [IOPMAssertionID]
    let readbacks: [IOPMAssertionID]
  }

  private let lock = NSLock()
  private var creates: [Creation] = []
  private var releases: [IOPMAssertionID] = []
  private var readbacks: [IOPMAssertionID] = []
  private var assertions: [IOPMAssertionID: Creation] = [:]
  private var readback: Readback = .created
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
        let creation = Creation(type: type as String, level: level, reason: reason as String)
        creates.append(creation)
        let result = createResults.isEmpty ? kIOReturnSuccess : createResults.removeFirst()
        if result == kIOReturnSuccess {
          id.pointee = nextID
          assertions[nextID] = creation
          nextID += 1
        }
        return result
      },
      copyProperties: { [self] id in
        lock.lock()
        defer { lock.unlock() }
        readbacks.append(id)
        guard let creation = assertions[id] else { return nil }
        // Default readback is derived from the actual production create call.
        var properties: [String: Any] = [
          kIOPMAssertionTypeKey as String: creation.type,
          kIOPMAssertionLevelKey as String: NSNumber(value: creation.level),
        ]
        switch readback {
        case .created: break
        case .unavailable: return nil
        case .off:
          properties[kIOPMAssertionLevelKey as String] = NSNumber(value: kIOPMAssertionLevelOff)
        case .wrongType:
          properties[kIOPMAssertionTypeKey as String] = kIOPMAssertionTypePreventUserIdleSystemSleep
        case .missingType:
          properties.removeValue(forKey: kIOPMAssertionTypeKey as String)
        case .missingLevel:
          properties.removeValue(forKey: kIOPMAssertionLevelKey as String)
        }
        return properties as CFDictionary
      },
      release: { [self] id in
        lock.lock()
        defer { lock.unlock() }
        releases.append(id)
        let result = releaseResults.isEmpty ? kIOReturnSuccess : releaseResults.removeFirst()
        if result == kIOReturnSuccess { assertions.removeValue(forKey: id) }
        return result
      })
  }

  func setReadback(_ readback: Readback) {
    lock.lock()
    defer { lock.unlock() }
    self.readback = readback
  }

  func snapshot() -> Snapshot {
    lock.lock()
    defer { lock.unlock() }
    return Snapshot(creates: creates, releases: releases, readbacks: readbacks)
  }
}

// Separately exercise the asynchronous protocol boundary without blocking a thread.
private actor DelayedReadbackBackend: UserPowerAssertionBackend {
  private var token: UserPowerAssertionToken?
  private var nextID: UInt32 = 1
  private var confirmed = true
  private var shouldBlock = false
  private var blockedReadback: CheckedContinuation<Void, Never>?
  private var blockedObserver: CheckedContinuation<Void, Never>?
  private var shouldBlockRelease = false
  private var nextReleaseFails = false
  private var blockedRelease: CheckedContinuation<Void, Never>?
  private var releaseObserver: CheckedContinuation<Void, Never>?
  private(set) var releaseAttempts = 0

  func acquire(reason: String) async throws -> UserPowerAssertionToken {
    guard token == nil else { throw UserPowerAssertionError.alreadyActive }
    let acquired = UserPowerAssertionToken(rawValue: nextID)
    nextID += 1
    token = acquired
    return acquired
  }

  func isActive(_ token: UserPowerAssertionToken) async throws -> Bool {
    guard self.token == token else { throw UserPowerAssertionError.invalidToken }
    let result = confirmed
    if shouldBlock {
      shouldBlock = false
      await withCheckedContinuation { continuation in
        blockedReadback = continuation
        blockedObserver?.resume()
        blockedObserver = nil
      }
    }
    return result
  }

  func release(_ token: UserPowerAssertionToken) async throws {
    guard self.token == token else { throw UserPowerAssertionError.invalidToken }
    releaseAttempts += 1
    let fails = nextReleaseFails
    nextReleaseFails = false
    if !fails { self.token = nil }
    if shouldBlockRelease {
      shouldBlockRelease = false
      await withCheckedContinuation { continuation in
        blockedRelease = continuation
        releaseObserver?.resume()
        releaseObserver = nil
      }
    }
    if fails { throw UserPowerAssertionError.systemFailure(-1) }
  }

  func blockNextReadback() { shouldBlock = true }
  func setConfirmed(_ confirmed: Bool) { self.confirmed = confirmed }

  func waitUntilReadbackIsBlocked() async {
    if blockedReadback != nil { return }
    await withCheckedContinuation { blockedObserver = $0 }
  }

  func finishReadback() {
    blockedReadback?.resume()
    blockedReadback = nil
  }

  func blockNextRelease(failing: Bool = false) {
    shouldBlockRelease = true
    nextReleaseFails = failing
  }

  func waitUntilReleaseIsBlocked() async {
    if blockedRelease != nil { return }
    await withCheckedContinuation { releaseObserver = $0 }
  }

  func finishRelease() {
    blockedRelease?.resume()
    blockedRelease = nil
  }
}

private struct DisplayRuntimeSampler: SupervisorEnvironmentSampling {
  let device: DeviceSafetySnapshot
  let clock: DisplayTestClock

  func sample(
    commuteTarget: CommuteNetworkTarget?
  ) async -> (network: NetworkSnapshot, device: DeviceSafetySnapshot) {
    (
      NetworkSnapshot(
        ssid: nil, interfaceName: "en0", routeReachable: true,
        internetReachability: .confirmed, capturedAt: clock.now()),
      device
    )
  }
}

private actor DisplayRuntimeCache: SupervisorStatusCaching {
  private var status: SupervisorStatusWire?

  func save(_ status: SupervisorStatusWire) async throws { self.status = status }
  func load() async throws -> SupervisorStatusWire? { status }
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
