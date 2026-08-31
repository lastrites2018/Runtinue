import Foundation
import XCTest

@testable import RuntinueCore
@testable import RuntinueHelperCore
@testable import RuntinueIPC
@testable import RuntinueSupervisorCore
@testable import RuntinueSupervisorSystem

@MainActor
final class CommuteJourneyTests: XCTestCase {
  func testTripWaitsForFreshTrustedSSIDRouteAndInternetBeforeEnablingLease() async throws {
    let clock = JourneyClock()
    let power = JourneyPowerBackend()
    let helper = LeaseActor(
      powerBackend: power,
      store: JourneyLeaseStore(),
      monotonicClock: clock,
      wallClock: clock
    )
    _ = await helper.start()

    let runtime = makeRuntime(
      helper: helper,
      power: power,
      clock: clock,
      snapshots: [
        journeySnapshot(
          ssid: "Office",
          routeReachable: true,
          internet: .confirmed,
          clock: clock
        ),
        journeySnapshot(
          ssid: nil,
          routeReachable: false,
          internet: .confirmed,
          clock: clock
        ),
        journeySnapshot(
          ssid: nil,
          routeReachable: true,
          internet: .unchecked,
          clock: clock
        ),
        journeySnapshot(
          ssid: nil,
          routeReachable: true,
          internet: .confirmed,
          clock: clock
        ),
      ]
    )

    await runtime.recordWiFiObservation(ssid: "Office", interfaceName: "en0")
    let armed = try await runtime.startTrip(
      expectedHotspotSSID: "iPhone",
      hotspotHandoffTimeout: .seconds(900),
      hardCap: .seconds(3_600)
    )
    XCTAssertEqual(armed.verdict, .waitingForHotspot)

    // The Menu Bar supplies the fresh SSID, while route and reachability remain
    // Supervisor-owned observations. The lease must wait for all three.
    await runtime.recordWiFiObservation(ssid: "iPhone", interfaceName: "en0")
    let routeUnavailable = await runtime.monitorOnce()
    XCTAssertEqual(routeUnavailable.verdict, .waitingForHotspot)
    XCTAssertEqual(
      routeUnavailable.detail,
      "routeUnavailable"
    )
    let routeHelperStatus = await helper.status()
    let routePowerWrites = await power.writes()
    XCTAssertEqual(routeHelperStatus.phase, .idle)
    XCTAssertEqual(routePowerWrites, [])

    let reachabilityUnchecked = await runtime.monitorOnce()
    XCTAssertEqual(reachabilityUnchecked.verdict, .waitingForHotspot)
    XCTAssertEqual(
      reachabilityUnchecked.detail,
      "internetUnchecked"
    )
    let uncheckedHelperStatus = await helper.status()
    let uncheckedPowerWrites = await power.writes()
    XCTAssertEqual(uncheckedHelperStatus.phase, .idle)
    XCTAssertEqual(uncheckedPowerWrites, [])

    let protected = await runtime.monitorOnce()
    XCTAssertEqual(protected.verdict, .protected)
    let protectedHelperStatus = await helper.status()
    let protectedPowerWrites = await power.writes()
    XCTAssertEqual(protectedHelperStatus.phase, .active)
    XCTAssertEqual(protectedPowerWrites, [.disabled])
  }

  func testClosedLidThermalCutoffReleasesLeaseAndReadsBackNormalSleep() async throws {
    let clock = JourneyClock()
    let power = JourneyPowerBackend()
    let helper = LeaseActor(
      powerBackend: power,
      store: JourneyLeaseStore(),
      monotonicClock: clock,
      wallClock: clock
    )
    _ = await helper.start()

    let runtime = makeRuntime(
      helper: helper,
      power: power,
      clock: clock,
      snapshots: [
        journeySnapshot(
          ssid: "Office",
          routeReachable: true,
          internet: .confirmed,
          clock: clock
        ),
        journeySnapshot(
          ssid: nil,
          routeReachable: true,
          internet: .confirmed,
          clock: clock
        ),
        journeySnapshot(
          ssid: nil,
          routeReachable: true,
          internet: .confirmed,
          thermal: .fair,
          lid: .closed,
          clock: clock
        ),
      ]
    )

    await runtime.recordWiFiObservation(ssid: "Office", interfaceName: "en0")
    _ = try await runtime.startTrip(
      expectedHotspotSSID: "iPhone",
      hotspotHandoffTimeout: .seconds(900),
      hardCap: .seconds(3_600)
    )
    await runtime.recordWiFiObservation(ssid: "iPhone", interfaceName: "en0")
    let protected = await runtime.monitorOnce()
    XCTAssertEqual(protected.verdict, .protected)
    let activeHelperStatus = await helper.status()
    XCTAssertEqual(activeHelperStatus.observedSleepOverride, .disabled)

    let stopped = await runtime.monitorOnce()
    XCTAssertEqual(stopped.phase, .ended)
    XCTAssertEqual(stopped.verdict, .unsafe)
    XCTAssertEqual(stopped.stopReason, .safety)
    XCTAssertEqual(stopped.thermalLevel, ThermalLevel.fair.rawValue)
    XCTAssertEqual(stopped.lidState, LidState.closed.rawValue)
    let stoppedHelperStatus = await helper.status()
    let stoppedPowerWrites = await power.writes()
    XCTAssertEqual(stoppedHelperStatus.phase, .idle)
    XCTAssertEqual(stoppedHelperStatus.observedSleepOverride, .normal)
    XCTAssertEqual(stoppedPowerWrites, [.disabled, .normal])
  }

  func testReleaseFailureBlocksNewTripUntilHelperRetryThenAllowsReentry() async throws {
    let clock = JourneyClock()
    let power = JourneyPowerBackend(
      writeBehaviors: [.succeed, .failWithoutChanging, .succeed, .succeed]
    )
    let helper = LeaseActor(
      powerBackend: power,
      store: JourneyLeaseStore(),
      monotonicClock: clock,
      wallClock: clock
    )
    _ = await helper.start()

    let runtime = makeRuntime(
      helper: helper,
      power: power,
      clock: clock,
      snapshots: [
        journeySnapshot(
          ssid: "Office",
          routeReachable: true,
          internet: .confirmed,
          clock: clock
        ),
        journeySnapshot(
          ssid: nil,
          routeReachable: true,
          internet: .confirmed,
          clock: clock
        ),
        journeySnapshot(
          ssid: "Office",
          routeReachable: true,
          internet: .confirmed,
          clock: clock
        ),
        journeySnapshot(
          ssid: nil,
          routeReachable: true,
          internet: .confirmed,
          clock: clock
        ),
      ]
    )

    await runtime.recordWiFiObservation(ssid: "Office", interfaceName: "en0")
    _ = try await runtime.startTrip(
      expectedHotspotSSID: "iPhone",
      hotspotHandoffTimeout: .seconds(900),
      hardCap: .seconds(3_600)
    )
    await runtime.recordWiFiObservation(ssid: "iPhone", interfaceName: "en0")
    let protected = await runtime.monitorOnce()
    let sessionID = try XCTUnwrap(protected.sessionID)
    XCTAssertEqual(protected.verdict, .protected)

    let pending = try await runtime.stop(expectedSessionID: sessionID)
    XCTAssertEqual(pending.phase, .recoveryPending)
    XCTAssertEqual(pending.verdict, .recoveryPending)
    let pendingHelperStatus = await helper.status()
    let pendingPowerWrites = await power.writes()
    XCTAssertEqual(pendingHelperStatus.phase, .recoveryPending)
    XCTAssertEqual(pendingPowerWrites, [.disabled])

    do {
      _ = try await runtime.startTrip(
        expectedHotspotSSID: "iPhone",
        hotspotHandoffTimeout: .seconds(900),
        hardCap: .seconds(3_600)
      )
      XCTFail("a recovery-pending trip must not be replaced")
    } catch {
      XCTAssertEqual(error as? SupervisorRuntimeError, .modeConflict)
    }

    clock.advance(seconds: 1)
    let recoveredHelper = await helper.tick()
    XCTAssertEqual(recoveredHelper.phase, .idle)
    XCTAssertEqual(recoveredHelper.observedSleepOverride, .normal)
    let recoveredPowerWrites = await power.writes()
    XCTAssertEqual(recoveredPowerWrites, [.disabled, .normal])

    let reconciled = await runtime.monitorOnce()
    XCTAssertEqual(reconciled.phase, .ended)
    XCTAssertEqual(reconciled.verdict, .inactive)
    let idle = await runtime.currentStatus()
    XCTAssertEqual(idle.mode, .none)
    XCTAssertEqual(idle.verdict, .inactive)

    await runtime.recordWiFiObservation(ssid: "Office", interfaceName: "en0")
    let rearmed = try await runtime.startTrip(
      expectedHotspotSSID: "iPhone",
      hotspotHandoffTimeout: .seconds(900),
      hardCap: .seconds(3_600)
    )
    await runtime.recordWiFiObservation(ssid: "iPhone", interfaceName: "en0")
    let reentered = await runtime.monitorOnce()
    XCTAssertEqual(rearmed.verdict, .waitingForHotspot)
    XCTAssertEqual(reentered.verdict, .protected)
    XCTAssertNotEqual(reentered.sessionID, sessionID)
    let reenteredHelperStatus = await helper.status()
    let reenteredPowerWrites = await power.writes()
    XCTAssertEqual(reenteredHelperStatus.phase, .active)
    XCTAssertEqual(reenteredPowerWrites, [.disabled, .normal, .disabled])

    _ = try await runtime.stop(expectedSessionID: reentered.sessionID)
    let finalHelperStatus = await helper.status()
    XCTAssertEqual(finalHelperStatus.phase, .idle)
  }

  private func makeRuntime(
    helper: LeaseActor,
    power: JourneyPowerBackend,
    clock: JourneyClock,
    snapshots: [(network: NetworkSnapshot, device: DeviceSafetySnapshot)]
  ) -> SupervisorRuntime {
    SupervisorRuntime(
      backend: JourneySupervisorBackend(helper: helper, ownerUID: 501),
      sampler: JourneySampler(snapshots: snapshots),
      statusCache: JourneyStatusCache(),
      ownerUID: 501,
      clock: clock,
      automaticMonitoring: false
    )
  }
}

private actor JourneySupervisorBackend: SupervisorLeaseBackend {
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
    case .rejected(let rejection):
      return .rejected(String(describing: rejection))
    case .recoveryPending(let status):
      return .recoveryPending(status.detail ?? "helper recovery is pending")
    }
  }

  func release(
    sessionID: UUID,
    lease: LeaseToken,
    reason: TripStopReason
  ) async -> LeaseReleaseOutcome {
    switch await helper.release(
      leaseID: sessionID,
      ownerUID: ownerUID,
      reason: helperReleaseReason(for: reason)
    ) {
    case .success:
      return .released
    case .rejected(let rejection):
      return .recoveryPending(String(describing: rejection))
    case .recoveryPending(let status):
      return .recoveryPending(status.detail ?? "helper recovery is pending")
    }
  }

  func renew(leaseID: UUID, ttl: Duration) async -> SupervisorHeartbeatResult {
    switch await helper.renew(leaseID: leaseID, ownerUID: ownerUID, ttl: ttl) {
    case .success(let status):
      return .renewed(observation(status))
    case .rejected(let rejection):
      return .rejected(String(describing: rejection))
    case .recoveryPending(let status):
      return .rejected(status.detail ?? "helper recovery is pending")
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

  private func helperReleaseReason(for reason: TripStopReason) -> HelperReleaseReason {
    switch reason {
    case .userRequested:
      return .userRequested
    case .hardDeadlineReached:
      return .hardDeadlineReached
    case .safety:
      return .safetyTrip
    case .hotspotHandoffTimedOut, .leaseRejected, .leaseRecoveryPending, .superseded:
      return .shutdown
    }
  }

  private func observation(_ status: HelperLeaseStatus) -> SupervisorHelperObservation {
    let sleepOverride: SupervisorSleepOverride
    switch status.observedSleepOverride {
    case .normal:
      sleepOverride = .normal
    case .disabled:
      sleepOverride = .disabled
    case .unavailable:
      sleepOverride = .unavailable
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

private actor JourneyPowerBackend: SleepPowerBackend {
  enum WriteBehavior: Sendable {
    case succeed
    case failWithoutChanging
    case failAfterChanging
  }

  private var state: SleepOverrideState = .normal
  private var recordedWrites: [SleepOverrideState] = []
  private var writeBehaviors: [WriteBehavior]

  init(writeBehaviors: [WriteBehavior] = []) {
    self.writeBehaviors = writeBehaviors
  }

  func readSleepOverride() async -> ObservedSleepOverride {
    state == .normal ? .normal : .disabled
  }

  func writeAndVerify(_ requested: SleepOverrideState) async throws {
    let behavior =
      writeBehaviors.isEmpty
      ? .succeed
      : writeBehaviors.removeFirst()
    switch behavior {
    case .succeed:
      state = requested
      recordedWrites.append(requested)
    case .failWithoutChanging:
      throw JourneyPowerError.injected
    case .failAfterChanging:
      state = requested
      recordedWrites.append(requested)
      throw JourneyPowerError.injected
    }
  }

  func writes() -> [SleepOverrideState] {
    recordedWrites
  }
}

private enum JourneyPowerError: Error {
  case injected
}

private actor JourneyLeaseStore: LeaseStateStore {
  private var current: PersistedLease?

  func load() async -> StoredLeaseLoadResult {
    current.map(StoredLeaseLoadResult.valid) ?? .absent
  }

  func save(_ lease: PersistedLease) async throws {
    current = lease
  }

  func remove() async throws {
    current = nil
  }

  func quarantineCorruptState() async throws {
    current = nil
  }
}

private actor JourneySampler: SupervisorEnvironmentSampling {
  private var snapshots: [(network: NetworkSnapshot, device: DeviceSafetySnapshot)]

  init(snapshots: [(network: NetworkSnapshot, device: DeviceSafetySnapshot)]) {
    self.snapshots = snapshots
  }

  func sample(
    commuteTarget: CommuteNetworkTarget?
  ) async -> (network: NetworkSnapshot, device: DeviceSafetySnapshot) {
    precondition(!snapshots.isEmpty, "missing commute journey snapshot")
    if snapshots.count == 1 {
      return snapshots[0]
    }
    return snapshots.removeFirst()
  }
}

private actor JourneyStatusCache: SupervisorStatusCaching {
  private var current: SupervisorStatusWire?

  func save(_ status: SupervisorStatusWire) async throws {
    current = status
  }

  func load() async throws -> SupervisorStatusWire? {
    current
  }
}

private final class JourneyClock: @unchecked Sendable, MonotonicTimeSource,
  WallTimeSource
{
  private let lock = NSLock()
  private var nanoseconds: UInt64 = 1_000_000_000
  private var wall = Date(timeIntervalSince1970: 1_000)

  func now() -> MonotonicInstant {
    lock.lock()
    defer { lock.unlock() }
    return MonotonicInstant(uptimeNanoseconds: nanoseconds)
  }

  func now() -> Date {
    lock.lock()
    defer { lock.unlock() }
    return wall
  }

  func advance(seconds: UInt64) {
    lock.lock()
    nanoseconds += seconds * 1_000_000_000
    wall = wall.addingTimeInterval(TimeInterval(seconds))
    lock.unlock()
  }
}

private func journeySnapshot(
  ssid: String?,
  routeReachable: Bool,
  internet: InternetReachability,
  thermal: ThermalLevel = .nominal,
  lid: LidState = .open,
  clock: JourneyClock
) -> (network: NetworkSnapshot, device: DeviceSafetySnapshot) {
  (
    NetworkSnapshot(
      ssid: ssid,
      interfaceName: "en0",
      gateway: ssid == "Office" ? "office-gateway" : "hotspot-gateway",
      routeReachable: routeReachable,
      internetReachability: internet,
      capturedAt: clock.now()
    ),
    DeviceSafetySnapshot(
      batteryPercent: 80,
      powerConnection: .battery,
      thermalLevel: thermal,
      lidState: lid,
      externalDisplayState: .absent,
      lowPowerModeEnabled: false,
      capturedAt: clock.now()
    )
  )
}
