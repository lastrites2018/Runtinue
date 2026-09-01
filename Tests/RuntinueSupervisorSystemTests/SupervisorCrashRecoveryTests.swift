import Foundation
import XCTest

@testable import RuntinueCore
@testable import RuntinueHelperCore
@testable import RuntinueSupervisorCore

@MainActor
final class SupervisorCrashRecoveryTests: XCTestCase {
  func testMissingSupervisorHeartbeatLetsHelperRestoreNormalSleepAtTTL() async throws {
    let clock = CrashRecoveryClock()
    let power = CrashRecoveryPowerBackend()
    let store = CrashRecoveryLeaseStore()
    let helper = LeaseActor(
      powerBackend: power,
      store: store,
      monotonicClock: clock,
      wallClock: clock
    )
    _ = await helper.start()
    let backend = InProcessSupervisorBackend(
      helper: helper,
      ownerUID: 501
    )
    let controller = SafetySupervisorController(
      leaseBackend: backend,
      ownerUID: 501,
      clock: clock
    )

    _ = try await controller.start(
      CommuteTripRequest(expectedHotspotSSID: "iPhone"),
      originNetwork: crashNetwork(ssid: "Office", clock: clock),
      device: crashDevice(clock: clock)
    )
    let active = await controller.observe(
      network: crashNetwork(ssid: "iPhone", clock: clock),
      device: crashDevice(clock: clock)
    )
    XCTAssertEqual(active.trip.phase, .active)

    clock.advance(seconds: 90)
    let recovered = await helper.tick()
    let powerWrites = await power.writes()

    XCTAssertEqual(recovered.phase, .idle)
    XCTAssertEqual(powerWrites, [.disabled, .normal])
  }
}

private actor InProcessSupervisorBackend: SupervisorLeaseBackend {
  private let helper: LeaseActor
  private let ownerUID: UInt32

  init(helper: LeaseActor, ownerUID: UInt32) {
    self.helper = helper
    self.ownerUID = ownerUID
  }

  func acquire(sessionID: UUID, hardCap: Duration) async -> LeaseAcquisitionOutcome {
    switch await helper.acquire(
      LeaseAcquireRequest(
        leaseID: sessionID,
        ownerUID: ownerUID,
        ttl: .seconds(90),
        hardCap: hardCap,
        reason: "commute"
      )
    ) {
    case .success:
      return .acquired(LeaseToken(id: sessionID))
    case .rejected(let reason):
      return .rejected(String(describing: reason))
    case .recoveryPending(let status):
      return .recoveryPending(status.detail ?? "recovery pending")
    }
  }

  func release(
    sessionID: UUID,
    lease: LeaseToken,
    reason: TripStopReason
  ) async -> LeaseReleaseOutcome {
    switch await helper.release(
      leaseID: lease.id,
      ownerUID: ownerUID,
      reason: .safetyTrip
    ) {
    case .success:
      return .released
    case .rejected(let rejection):
      return .recoveryPending(String(describing: rejection))
    case .recoveryPending(let status):
      return .recoveryPending(status.detail ?? "recovery pending")
    }
  }

  func renew(leaseID: UUID, ttl: Duration) async -> SupervisorHeartbeatResult {
    switch await helper.renew(leaseID: leaseID, ownerUID: ownerUID, ttl: ttl) {
    case .success(let status):
      return .renewed(observation(status))
    case .rejected(let rejection):
      return .rejected(String(describing: rejection))
    case .recoveryPending(let status):
      return .rejected(status.detail ?? "recovery pending")
    }
  }

  func liveStatus() async -> SupervisorHelperQuery {
    .available(observation(await helper.status()))
  }

  func releaseExistingOwnedLease() async -> LeaseReleaseOutcome {
    let status = await helper.status()
    guard status.ownerUID == ownerUID, let leaseID = status.leaseID else {
      return .released
    }
    return await release(
      sessionID: leaseID,
      lease: LeaseToken(id: leaseID),
      reason: .superseded
    )
  }

  private func observation(_ status: HelperLeaseStatus) -> SupervisorHelperObservation {
    let sleepOverride: SupervisorSleepOverride
    switch status.observedSleepOverride {
    case .normal: sleepOverride = .normal
    case .disabled: sleepOverride = .disabled
    case .unavailable: sleepOverride = .unavailable
    }
    return SupervisorHelperObservation(
      phase: SupervisorHelperPhase(rawValue: status.phase.rawValue) ?? .unknown,
      leaseID: status.leaseID,
      ownerUID: status.ownerUID,
      sleepOverride: sleepOverride,
      ttlDeadline: status.ttlDeadline,
      hardDeadline: status.hardDeadline,
      detail: status.detail
    )
  }
}

private actor CrashRecoveryPowerBackend: SleepPowerBackend {
  private var state: SleepOverrideState = .normal
  private var recordedWrites: [SleepOverrideState] = []

  func readSleepOverride() async -> ObservedSleepOverride {
    state == .normal ? .normal : .disabled
  }

  func writeAndVerify(_ state: SleepOverrideState) async throws {
    self.state = state
    recordedWrites.append(state)
  }

  func writes() -> [SleepOverrideState] {
    recordedWrites
  }
}

private actor CrashRecoveryLeaseStore: LeaseStateStore {
  private var lease: PersistedLease?

  func load() async -> StoredLeaseLoadResult {
    lease.map(StoredLeaseLoadResult.valid) ?? .absent
  }

  func save(_ lease: PersistedLease) async throws {
    self.lease = lease
  }

  func remove() async throws {
    lease = nil
  }

  func quarantineCorruptState() async throws {
    lease = nil
  }
}

private final class CrashRecoveryClock: @unchecked Sendable, MonotonicTimeSource,
  WallTimeSource
{
  private let lock = NSLock()
  private var monotonic: UInt64 = 1_000_000_000
  private var wall = Date(timeIntervalSince1970: 1_000)

  func now() -> MonotonicInstant {
    lock.lock()
    defer { lock.unlock() }
    return MonotonicInstant(continuousNanoseconds: monotonic)
  }

  func now() -> Date {
    lock.lock()
    defer { lock.unlock() }
    return wall
  }

  func advance(seconds: UInt64) {
    lock.lock()
    monotonic += seconds * 1_000_000_000
    wall = wall.addingTimeInterval(TimeInterval(seconds))
    lock.unlock()
  }
}

private func crashNetwork(
  ssid: String,
  clock: CrashRecoveryClock
) -> NetworkSnapshot {
  NetworkSnapshot(
    ssid: ssid,
    interfaceName: "en0",
    routeReachable: true,
    internetReachability: .confirmed,
    capturedAt: clock.now()
  )
}

private func crashDevice(clock: CrashRecoveryClock) -> DeviceSafetySnapshot {
  DeviceSafetySnapshot(
    batteryPercent: 80,
    powerConnection: .battery,
    thermalLevel: .nominal,
    lidState: .open,
    externalDisplayState: .absent,
    lowPowerModeEnabled: false,
    capturedAt: clock.now()
  )
}
