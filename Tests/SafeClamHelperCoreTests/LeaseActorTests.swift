import Foundation
import XCTest

@testable import SafeClamCore
@testable import SafeClamHelperCore

@MainActor
final class LeaseActorTests: XCTestCase {
  func testAcquirePersistsBeforeEnablingSleepOverride() async {
    let recorder = EventRecorder()
    let power = FakePowerBackend(recorder: recorder)
    let store = FakeLeaseStore(recorder: recorder)
    let clock = ManualHelperClock()
    let actor = LeaseActor(
      powerBackend: power,
      store: store,
      monotonicClock: clock,
      wallClock: clock
    )
    _ = await actor.start()

    let result = await actor.acquire(request())

    guard case .success(let status) = result else {
      return XCTFail("expected successful acquisition, got \(result)")
    }
    XCTAssertTrue(status.isProtected)
    let recordedEvents = await recorder.snapshot()
    let events = recordedEvents.filter {
      $0.hasPrefix("save:") || $0.hasPrefix("write:")
    }
    XCTAssertEqual(events, ["save:acquiring", "write:disabled", "save:active"])
  }

  func testPersistenceFailurePreventsPowerWrite() async {
    let power = FakePowerBackend()
    let store = FakeLeaseStore(saveFailures: [true])
    let actor = makeActor(power: power, store: store)
    _ = await actor.start()

    let result = await actor.acquire(request())

    guard case .rejected(.persistenceFailure) = result else {
      return XCTFail("expected persistence rejection, got \(result)")
    }
    let powerSnapshot = await power.snapshot()
    XCTAssertTrue(powerSnapshot.writes.isEmpty)
    XCTAssertEqual(powerSnapshot.state, .normal)
  }

  func testExistingExternalSleepOverrideRejectsAcquisition() async {
    let power = FakePowerBackend(initialState: .disabled)
    let store = FakeLeaseStore()
    let actor = makeActor(power: power, store: store)
    _ = await actor.start()

    let result = await actor.acquire(request())
    let storeSnapshot = await store.snapshot()
    let powerSnapshot = await power.snapshot()
    XCTAssertEqual(result, .rejected(.sleepOverrideAlreadyOwned))
    XCTAssertTrue(storeSnapshot.saved.isEmpty)
    XCTAssertTrue(powerSnapshot.writes.isEmpty)
  }

  func testExternalOwnerAppearingAfterPersistencePreventsEnable() async {
    let power = FakePowerBackend(readResults: [.normal, .normal, .disabled])
    let store = FakeLeaseStore()
    let actor = makeActor(power: power, store: store)
    _ = await actor.start()

    let result = await actor.acquire(request())
    let storeSnapshot = await store.snapshot()
    let powerSnapshot = await power.snapshot()

    XCTAssertEqual(result, .rejected(.sleepOverrideAlreadyOwned))
    XCTAssertNil(storeSnapshot.current)
    XCTAssertEqual(storeSnapshot.removeCount, 1)
    XCTAssertTrue(powerSnapshot.writes.isEmpty)
  }

  func testFailedEnableRollsBackAndRemovesLease() async {
    let power = FakePowerBackend(
      writeBehaviors: [.failWithoutChanging, .succeed]
    )
    let store = FakeLeaseStore()
    let actor = makeActor(power: power, store: store)
    _ = await actor.start()

    let result = await actor.acquire(request())

    guard case .rejected(.powerFailure) = result else {
      return XCTFail("expected power failure after successful rollback, got \(result)")
    }
    let powerSnapshot = await power.snapshot()
    let storeSnapshot = await store.snapshot()
    let status = await actor.status()
    XCTAssertEqual(powerSnapshot.writes, [.disabled, .normal])
    XCTAssertNil(storeSnapshot.current)
    XCTAssertEqual(status.phase, .idle)
  }

  func testEnableReadBackFailureStillRollsBack() async {
    let power = FakePowerBackend(
      writeBehaviors: [.failAfterChanging, .succeed]
    )
    let store = FakeLeaseStore()
    let actor = makeActor(power: power, store: store)
    _ = await actor.start()

    let result = await actor.acquire(request())
    let powerSnapshot = await power.snapshot()
    let storeSnapshot = await store.snapshot()

    guard case .rejected(.powerFailure) = result else {
      return XCTFail("expected read-back failure rejection, got \(result)")
    }
    XCTAssertEqual(powerSnapshot.writes, [.disabled, .normal])
    XCTAssertEqual(powerSnapshot.state, .normal)
    XCTAssertNil(storeSnapshot.current)
  }

  func testActivePhasePersistenceFailureRollsBack() async {
    let power = FakePowerBackend()
    let store = FakeLeaseStore(saveFailures: [false, true])
    let actor = makeActor(power: power, store: store)
    _ = await actor.start()

    let result = await actor.acquire(request())
    let powerSnapshot = await power.snapshot()
    let storeSnapshot = await store.snapshot()

    guard case .rejected = result else {
      return XCTFail("expected rejected acquisition, got \(result)")
    }
    XCTAssertEqual(powerSnapshot.writes, [.disabled, .normal])
    XCTAssertEqual(powerSnapshot.state, .normal)
    XCTAssertNil(storeSnapshot.current)
  }

  func testFailedReleaseRetainsRecoveryAndWatchdogRetries() async {
    let clock = ManualHelperClock()
    let power = FakePowerBackend(
      writeBehaviors: [.succeed, .failWithoutChanging, .succeed]
    )
    let store = FakeLeaseStore()
    let actor = makeActor(power: power, store: store, clock: clock)
    _ = await actor.start()
    let leaseID = UUID()
    _ = await actor.acquire(request(leaseID: leaseID))

    let release = await actor.release(
      leaseID: leaseID,
      ownerUID: 501,
      reason: .safetyTrip
    )
    guard case .recoveryPending(let pendingStatus) = release else {
      return XCTFail("expected recovery pending, got \(release)")
    }
    XCTAssertEqual(pendingStatus.phase, .recoveryPending)
    let pendingStoreSnapshot = await store.snapshot()
    XCTAssertEqual(pendingStoreSnapshot.current?.phase, .recoveryPending)

    let tooEarly = await actor.tick()
    let tooEarlyPowerSnapshot = await power.snapshot()
    XCTAssertEqual(tooEarly.phase, .recoveryPending)
    XCTAssertEqual(tooEarlyPowerSnapshot.writes, [.disabled, .normal])

    clock.advance(seconds: 1)
    let recovered = await actor.tick()
    XCTAssertEqual(recovered.phase, .idle)
    let recoveredStoreSnapshot = await store.snapshot()
    let recoveredPowerSnapshot = await power.snapshot()
    XCTAssertNil(recoveredStoreSnapshot.current)
    XCTAssertEqual(recoveredPowerSnapshot.state, .normal)
    XCTAssertEqual(recoveredPowerSnapshot.writes, [.disabled, .normal, .normal])
  }

  func testRecoveryRetryBackoffUsesOneTwoThenFiveSeconds() async {
    let clock = ManualHelperClock()
    let power = FakePowerBackend(
      writeBehaviors: [
        .succeed,
        .failWithoutChanging,
        .failWithoutChanging,
        .failWithoutChanging,
        .succeed,
      ]
    )
    let actor = makeActor(
      power: power,
      store: FakeLeaseStore(),
      clock: clock
    )
    let leaseID = UUID()
    _ = await actor.start()
    _ = await actor.acquire(request(leaseID: leaseID))
    _ = await actor.release(
      leaseID: leaseID,
      ownerUID: 501,
      reason: .safetyTrip
    )

    var powerSnapshot = await power.snapshot()
    XCTAssertEqual(powerSnapshot.writes.count, 2)
    clock.advance(seconds: 1)
    _ = await actor.tick()
    powerSnapshot = await power.snapshot()
    XCTAssertEqual(powerSnapshot.writes.count, 3)

    clock.advance(seconds: 1)
    _ = await actor.tick()
    powerSnapshot = await power.snapshot()
    XCTAssertEqual(powerSnapshot.writes.count, 3)
    clock.advance(seconds: 1)
    _ = await actor.tick()
    powerSnapshot = await power.snapshot()
    XCTAssertEqual(powerSnapshot.writes.count, 4)

    clock.advance(seconds: 4)
    _ = await actor.tick()
    powerSnapshot = await power.snapshot()
    XCTAssertEqual(powerSnapshot.writes.count, 4)
    clock.advance(seconds: 1)
    let recovered = await actor.tick()
    powerSnapshot = await power.snapshot()
    XCTAssertEqual(powerSnapshot.writes.count, 5)
    XCTAssertEqual(recovered.phase, .idle)
  }

  func testReleaseReadBackFailureRetainsLeaseUntilRetry() async {
    let clock = ManualHelperClock()
    let power = FakePowerBackend(
      writeBehaviors: [.succeed, .failAfterChanging, .succeed]
    )
    let store = FakeLeaseStore()
    let actor = makeActor(power: power, store: store, clock: clock)
    let leaseID = UUID()
    _ = await actor.start()
    _ = await actor.acquire(request(leaseID: leaseID))

    let release = await actor.release(
      leaseID: leaseID,
      ownerUID: 501,
      reason: .safetyTrip
    )
    let pendingStore = await store.snapshot()
    guard case .recoveryPending = release else {
      return XCTFail("expected recovery pending, got \(release)")
    }
    XCTAssertNotNil(pendingStore.current)

    clock.advance(seconds: 1)
    let recoveredStatus = await actor.tick()
    let recoveredStore = await store.snapshot()
    XCTAssertEqual(recoveredStatus.phase, .idle)
    XCTAssertNil(recoveredStore.current)
  }

  func testReleasePersistenceFailurePreventsPowerWriteUntilWatchdogRetry() async {
    let clock = ManualHelperClock()
    let power = FakePowerBackend()
    let store = FakeLeaseStore(
      saveFailures: [false, false, true, false]
    )
    let actor = makeActor(power: power, store: store, clock: clock)
    let leaseID = UUID()
    _ = await actor.start()
    _ = await actor.acquire(request(leaseID: leaseID))

    let release = await actor.release(
      leaseID: leaseID,
      ownerUID: 501,
      reason: .safetyTrip
    )

    guard case .recoveryPending = release else {
      return XCTFail("expected recovery pending, got \(release)")
    }
    let pendingPower = await power.snapshot()
    let pendingStore = await store.snapshot()
    XCTAssertEqual(pendingPower.writes, [.disabled])
    XCTAssertEqual(pendingStore.current?.phase, .recoveryPending)

    clock.advance(seconds: 1)
    let recovered = await actor.tick()
    let finalPower = await power.snapshot()
    XCTAssertEqual(recovered.phase, .idle)
    XCTAssertEqual(finalPower.writes, [.disabled, .normal])
  }

  func testStartupNeverResumesPersistedLease() async {
    let persisted = persistedLease(phase: .active)
    let power = FakePowerBackend(initialState: .disabled)
    let store = FakeLeaseStore(loadResult: .valid(persisted), current: persisted)
    let actor = makeActor(power: power, store: store)

    let status = await actor.start()

    XCTAssertEqual(status.phase, .idle)
    let powerSnapshot = await power.snapshot()
    let storeSnapshot = await store.snapshot()
    XCTAssertEqual(powerSnapshot.writes, [.normal])
    XCTAssertNil(storeSnapshot.current)
  }

  func testUnknownPersistedVersionUsesFailSafeRecovery() async {
    let persisted = persistedLease(phase: .active, version: 99)
    let power = FakePowerBackend(initialState: .disabled)
    let store = FakeLeaseStore(loadResult: .valid(persisted), current: persisted)
    let actor = makeActor(power: power, store: store)

    let status = await actor.start()
    let powerSnapshot = await power.snapshot()

    XCTAssertEqual(status.phase, .idle)
    XCTAssertEqual(powerSnapshot.writes, [.normal])
    let storeSnapshot = await store.snapshot()
    XCTAssertNil(storeSnapshot.current)
  }

  func testPersistedDisabledRollbackBaselineIsNeverReapplied() async {
    let persisted = persistedLease(
      phase: .active,
      rollbackBaseline: .disabled
    )
    let store = FakeLeaseStore(loadResult: .valid(persisted), current: persisted)
    let power = FakePowerBackend(initialState: .disabled)
    let actor = makeActor(power: power, store: store)

    let status = await actor.start()
    let powerSnapshot = await power.snapshot()
    let storeSnapshot = await store.snapshot()

    XCTAssertEqual(status.phase, .idle)
    XCTAssertEqual(powerSnapshot.state, .normal)
    XCTAssertEqual(powerSnapshot.writes, [.normal])
    XCTAssertEqual(storeSnapshot.quarantineCount, 1)
  }

  func testCorruptStateForcesNormalSleepThenQuarantines() async {
    let power = FakePowerBackend(initialState: .disabled)
    let store = FakeLeaseStore(loadResult: .corrupt("invalid json"))
    let actor = makeActor(power: power, store: store)

    let status = await actor.start()

    XCTAssertEqual(status.phase, .idle)
    let powerSnapshot = await power.snapshot()
    let storeSnapshot = await store.snapshot()
    XCTAssertEqual(powerSnapshot.writes, [.normal])
    XCTAssertEqual(storeSnapshot.quarantineCount, 1)
  }

  func testTTLExpiryReleasesLease() async {
    let clock = ManualHelperClock()
    let power = FakePowerBackend()
    let store = FakeLeaseStore()
    let actor = makeActor(power: power, store: store, clock: clock)
    _ = await actor.start()
    _ = await actor.acquire(request(ttl: .seconds(90), hardCap: .seconds(300)))

    clock.advance(seconds: 90)
    let status = await actor.tick()

    XCTAssertEqual(status.phase, .idle)
    let powerSnapshot = await power.snapshot()
    XCTAssertEqual(powerSnapshot.writes, [.disabled, .normal])
  }

  func testHardCapShorterThanTTLIsAllowedAndWins() async {
    let clock = ManualHelperClock()
    let power = FakePowerBackend()
    let store = FakeLeaseStore()
    let actor = makeActor(power: power, store: store, clock: clock)
    _ = await actor.start()

    let acquired = await actor.acquire(
      request(ttl: .seconds(90), hardCap: .seconds(30))
    )
    guard case .success(let active) = acquired else {
      return XCTFail("expected acquisition, got \(acquired)")
    }
    XCTAssertEqual(active.ttlDeadline, active.hardDeadline)

    clock.advance(seconds: 30)
    let ended = await actor.tick()
    let powerSnapshot = await power.snapshot()
    XCTAssertEqual(ended.phase, .idle)
    XCTAssertEqual(powerSnapshot.writes, [.disabled, .normal])
  }

  func testRenewCannotExtendHardDeadline() async {
    let clock = ManualHelperClock()
    let power = FakePowerBackend()
    let store = FakeLeaseStore()
    let actor = makeActor(power: power, store: store, clock: clock)
    let leaseID = UUID()
    _ = await actor.start()
    _ = await actor.acquire(
      request(leaseID: leaseID, ttl: .seconds(90), hardCap: .seconds(100))
    )

    clock.advance(seconds: 80)
    let renewed = await actor.renew(
      leaseID: leaseID,
      ownerUID: 501,
      ttl: .seconds(90)
    )
    guard case .success(let renewedStatus) = renewed else {
      return XCTFail("expected renewal, got \(renewed)")
    }
    XCTAssertEqual(renewedStatus.ttlDeadline, renewedStatus.hardDeadline)

    clock.advance(seconds: 20)
    let finalStatus = await actor.tick()
    let powerSnapshot = await power.snapshot()
    XCTAssertEqual(finalStatus.phase, .idle)
    XCTAssertEqual(powerSnapshot.writes, [.disabled, .disabled, .normal])
  }

  func testWallClockMovingBackwardDoesNotExtendHardDeadline() async {
    let clock = ManualHelperClock()
    let power = FakePowerBackend()
    let store = FakeLeaseStore()
    let actor = makeActor(power: power, store: store, clock: clock)
    _ = await actor.start()
    _ = await actor.acquire(
      request(ttl: .seconds(90), hardCap: .seconds(100))
    )

    clock.moveWallClock(seconds: -7_200)
    clock.advanceMonotonic(seconds: 100)
    let status = await actor.tick()
    let powerSnapshot = await power.snapshot()

    XCTAssertEqual(status.phase, .idle)
    XCTAssertEqual(powerSnapshot.writes, [.disabled, .normal])
  }

  func testUnavailableLiveStateIsNeverProtected() async {
    let power = FakePowerBackend()
    let store = FakeLeaseStore()
    let actor = makeActor(power: power, store: store)
    _ = await actor.start()
    _ = await actor.acquire(request())

    await power.setForcedRead(.unavailable("injected"))
    let status = await actor.status()

    XCTAssertEqual(status.phase, .unknown)
    XCTAssertFalse(status.isProtected)
  }

  func testShutdownReleasesActiveLease() async {
    let power = FakePowerBackend()
    let store = FakeLeaseStore()
    let actor = makeActor(power: power, store: store)
    _ = await actor.start()
    _ = await actor.acquire(request())

    let status = await actor.shutdown()
    let powerSnapshot = await power.snapshot()

    XCTAssertEqual(status.phase, .idle)
    XCTAssertEqual(powerSnapshot.writes, [.disabled, .normal])
  }

  func testMismatchedOwnerCannotReleaseLease() async {
    let power = FakePowerBackend()
    let store = FakeLeaseStore()
    let actor = makeActor(power: power, store: store)
    let leaseID = UUID()
    _ = await actor.start()
    _ = await actor.acquire(request(leaseID: leaseID))

    let result = await actor.release(
      leaseID: leaseID,
      ownerUID: 502,
      reason: .userRequested
    )
    let powerSnapshot = await power.snapshot()
    let status = await actor.status()
    XCTAssertEqual(result, .rejected(.leaseMismatch))
    XCTAssertEqual(powerSnapshot.writes, [.disabled])
    XCTAssertEqual(status.phase, .active)
  }

  private func request(
    leaseID: UUID = UUID(),
    ttl: Duration = .seconds(90),
    hardCap: Duration = .seconds(2 * 60 * 60)
  ) -> LeaseAcquireRequest {
    LeaseAcquireRequest(
      leaseID: leaseID,
      ownerUID: 501,
      ttl: ttl,
      hardCap: hardCap,
      reason: "commute"
    )
  }

  private func makeActor(
    power: FakePowerBackend,
    store: FakeLeaseStore,
    clock: ManualHelperClock = ManualHelperClock()
  ) -> LeaseActor {
    LeaseActor(
      powerBackend: power,
      store: store,
      monotonicClock: clock,
      wallClock: clock
    )
  }
}

private enum FakeFailure: Error {
  case injected
}

private enum FakeWriteBehavior: Sendable {
  case succeed
  case failWithoutChanging
  case failAfterChanging
}

private actor FakePowerBackend: SleepPowerBackend {
  struct Snapshot: Sendable {
    let state: SleepOverrideState
    let writes: [SleepOverrideState]
  }

  private(set) var state: SleepOverrideState
  private(set) var writes: [SleepOverrideState] = []
  private var writeBehaviors: [FakeWriteBehavior]
  private var readResults: [ObservedSleepOverride]
  private var forcedRead: ObservedSleepOverride?
  private let recorder: EventRecorder?

  init(
    initialState: SleepOverrideState = .normal,
    writeBehaviors: [FakeWriteBehavior] = [],
    readResults: [ObservedSleepOverride] = [],
    recorder: EventRecorder? = nil
  ) {
    self.state = initialState
    self.writeBehaviors = writeBehaviors
    self.readResults = readResults
    self.forcedRead = nil
    self.recorder = recorder
  }

  func readSleepOverride() async -> ObservedSleepOverride {
    if !readResults.isEmpty {
      return readResults.removeFirst()
    }
    if let forcedRead {
      return forcedRead
    }
    return state == .disabled ? ObservedSleepOverride.disabled : .normal
  }

  func writeAndVerify(_ state: SleepOverrideState) async throws {
    writes.append(state)
    await recorder?.record("write:\(state.rawValue)")
    let behavior = writeBehaviors.isEmpty ? .succeed : writeBehaviors.removeFirst()
    switch behavior {
    case .succeed:
      self.state = state
    case .failWithoutChanging:
      throw FakeFailure.injected
    case .failAfterChanging:
      self.state = state
      throw FakeFailure.injected
    }
  }

  func snapshot() -> Snapshot {
    Snapshot(state: state, writes: writes)
  }

  func setForcedRead(_ observed: ObservedSleepOverride?) {
    forcedRead = observed
  }
}

private actor FakeLeaseStore: LeaseStateStore {
  struct Snapshot: Sendable {
    let current: PersistedLease?
    let saved: [PersistedLease]
    let removeCount: Int
    let quarantineCount: Int
  }

  private var loadResult: StoredLeaseLoadResult
  private var saveFailures: [Bool]
  private(set) var current: PersistedLease?
  private(set) var saved: [PersistedLease] = []
  private(set) var removeCount = 0
  private(set) var quarantineCount = 0
  private let recorder: EventRecorder?

  init(
    loadResult: StoredLeaseLoadResult = .absent,
    current: PersistedLease? = nil,
    saveFailures: [Bool] = [],
    recorder: EventRecorder? = nil
  ) {
    self.loadResult = loadResult
    self.current = current
    self.saveFailures = saveFailures
    self.recorder = recorder
  }

  func load() async -> StoredLeaseLoadResult {
    loadResult
  }

  func save(_ lease: PersistedLease) async throws {
    let shouldFail = saveFailures.isEmpty ? false : saveFailures.removeFirst()
    if shouldFail {
      throw FakeFailure.injected
    }
    current = lease
    saved.append(lease)
    await recorder?.record("save:\(lease.phase.rawValue)")
  }

  func remove() async throws {
    current = nil
    removeCount += 1
  }

  func quarantineCorruptState() async throws {
    quarantineCount += 1
  }

  func snapshot() -> Snapshot {
    Snapshot(
      current: current,
      saved: saved,
      removeCount: removeCount,
      quarantineCount: quarantineCount
    )
  }
}

private actor EventRecorder {
  private(set) var events: [String] = []

  func record(_ event: String) {
    events.append(event)
  }

  func snapshot() -> [String] {
    events
  }
}

private final class ManualHelperClock: @unchecked Sendable, MonotonicTimeSource,
  WallTimeSource
{
  private let lock = NSLock()
  private var monotonicNanoseconds: UInt64
  private var wallDate: Date

  init(
    monotonicNanoseconds: UInt64 = 1_000_000_000,
    wallDate: Date = Date(timeIntervalSince1970: 1_000)
  ) {
    self.monotonicNanoseconds = monotonicNanoseconds
    self.wallDate = wallDate
  }

  func now() -> MonotonicInstant {
    lock.lock()
    defer { lock.unlock() }
    return MonotonicInstant(uptimeNanoseconds: monotonicNanoseconds)
  }

  func now() -> Date {
    lock.lock()
    defer { lock.unlock() }
    return wallDate
  }

  func advance(seconds: UInt64) {
    lock.lock()
    monotonicNanoseconds += seconds * 1_000_000_000
    wallDate = wallDate.addingTimeInterval(TimeInterval(seconds))
    lock.unlock()
  }

  func advanceMonotonic(seconds: UInt64) {
    lock.lock()
    monotonicNanoseconds += seconds * 1_000_000_000
    lock.unlock()
  }

  func moveWallClock(seconds: TimeInterval) {
    lock.lock()
    wallDate = wallDate.addingTimeInterval(seconds)
    lock.unlock()
  }
}

private func persistedLease(
  phase: PersistedLeasePhase,
  version: Int = PersistedLease.currentVersion,
  rollbackBaseline: SleepOverrideState = .normal
) -> PersistedLease {
  let now = Date(timeIntervalSince1970: 1_000)
  return PersistedLease(
    version: version,
    leaseID: UUID(),
    ownerUID: 501,
    createdAt: now,
    hardDeadline: now.addingTimeInterval(3_600),
    rollbackBaseline: rollbackBaseline,
    reason: "commute",
    phase: phase,
    lastRenewedAt: now,
    ttlExpiresAt: now.addingTimeInterval(90)
  )
}
