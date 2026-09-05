import Darwin
import Foundation
import XCTest

@testable import RuntinueCore
@testable import RuntinueIPC
@testable import RuntinueSupervisorCore
@testable import RuntinueSupervisorSystem
@testable import RuntinueSystem
@testable import RuntinueUserSupport

@MainActor
final class SupervisorRuntimeTests: XCTestCase {
  func testBlockedTemperatureTelemetryCannotDelayTheNextSafetyObservation() async throws {
    let clock = RuntimeManualClock()
    let backend = RuntimeFakeBackend(clock: clock)
    let temperatureSampler = RuntimeBlockingTemperatureSampler()
    let runtime = SupervisorRuntime(
      backend: backend,
      sampler: RuntimeFakeSampler(snapshots: [
        runtimeSnapshot(ssid: "Office", clock: clock),
        runtimeSnapshot(ssid: "iPhone", clock: clock),
        runtimeSnapshot(ssid: "iPhone", clock: clock, thermal: .fair, lid: .closed),
      ]),
      temperatureSampler: temperatureSampler,
      statusCache: RuntimeFakeCache(),
      ownerUID: 501,
      clock: clock,
      monitorInterval: .milliseconds(1),
      automaticMonitoring: false
    )
    await runtime.recordWiFiObservation(ssid: "Office", interfaceName: "en0")
    _ = try await runtime.startTrip(
      expectedHotspotSSID: "iPhone",
      hotspotHandoffTimeout: .seconds(900),
      hardCap: .seconds(3_600)
    )
    await runtime.recordWiFiObservation(ssid: "iPhone", interfaceName: "en0")
    let active = await runtime.monitorOnce()
    XCTAssertEqual(active.verdict, .protected)

    await temperatureSampler.blockNextSample()
    for _ in 0..<1_000 {
      if await temperatureSampler.isBlocked { break }
      try? await Task.sleep(for: .milliseconds(1))
    }
    let sampleCountWhileBlocked = await temperatureSampler.sampleCount
    let completion = RuntimeTemperatureMonitorCompletion()
    let monitoring = Task {
      let status = await runtime.monitorOnce()
      await completion.finish()
      return status
    }
    for _ in 0..<1_000 {
      if await completion.isFinished { break }
      try? await Task.sleep(for: .milliseconds(1))
    }
    let completedWhileTemperatureBlocked = await completion.isFinished
    let temperatureRemainedBlocked = await temperatureSampler.isBlocked
    let sampleCountAfterSafetyObservation = await temperatureSampler.sampleCount
    let beforeTemperatureCompletion = await backend.snapshot()
    await temperatureSampler.unblock()
    let stopped = await monitoring.value

    XCTAssertTrue(temperatureRemainedBlocked, "temperature fault injection must remain active")
    XCTAssertTrue(
      completedWhileTemperatureBlocked,
      "a blocked informational sensor must not delay the next safety observation"
    )
    XCTAssertEqual(
      sampleCountAfterSafetyObservation,
      sampleCountWhileBlocked,
      "the temperature loop must keep only one sample in flight"
    )
    XCTAssertEqual(
      beforeTemperatureCompletion.releaseCount,
      1,
      "unsafe thermal pressure must release while direct temperature sampling is blocked"
    )
    XCTAssertEqual(stopped.verdict, .unsafe)
    XCTAssertEqual(stopped.temperatureTelemetry?.status, .temporarilyUnavailable)
  }

  func testShutdownCancelsTheIndependentTemperatureMonitor() async {
    let clock = RuntimeManualClock()
    let temperatureSampler = RuntimeCancellableTemperatureSampler()
    let runtime = SupervisorRuntime(
      backend: RuntimeFakeBackend(clock: clock),
      sampler: RuntimeFakeSampler(snapshots: [
        runtimeSnapshot(ssid: "Office", clock: clock),
      ]),
      temperatureSampler: temperatureSampler,
      statusCache: RuntimeFakeCache(),
      ownerUID: 501,
      clock: clock,
      automaticMonitoring: false
    )

    _ = await runtime.startup()
    for _ in 0..<1_000 {
      if await temperatureSampler.isSampling { break }
      try? await Task.sleep(for: .milliseconds(1))
    }
    let started = await temperatureSampler.isSampling

    _ = await runtime.shutdown()
    for _ in 0..<1_000 {
      if await temperatureSampler.observedCancellation { break }
      try? await Task.sleep(for: .milliseconds(1))
    }
    let observedCancellation = await temperatureSampler.observedCancellation

    XCTAssertTrue(started, "temperature monitor must start with the Supervisor")
    XCTAssertTrue(
      observedCancellation,
      "Supervisor shutdown must cancel the independent temperature monitor"
    )
  }

  func testSafetyReleaseDoesNotWaitForLidConflictEventPersistence() async throws {
    let clock = RuntimeManualClock()
    let backend = RuntimeFakeBackend(clock: clock)
    let sink = RuntimeBlockingLidEventSink()
    let runtime = SupervisorRuntime(
      backend: backend,
      sampler: RuntimeFakeSampler(snapshots: [
        runtimeSnapshot(ssid: "Office", clock: clock),
        runtimeSnapshot(ssid: "iPhone", clock: clock),
        runtimeSnapshot(
          ssid: "iPhone", clock: clock, thermal: .fair, lid: .closed, lidConflict: true
        ),
      ]),
      statusCache: RuntimeFakeCache(),
      eventRecorder: SupervisorEventRecorder(sink: sink, buildID: nil),
      ownerUID: 501, clock: clock, automaticMonitoring: false
    )
    await runtime.recordWiFiObservation(ssid: "Office", interfaceName: "en0")
    _ = try await runtime.startTrip(
      expectedHotspotSSID: "iPhone", hotspotHandoffTimeout: .seconds(900),
      hardCap: .seconds(3_600)
    )
    await runtime.recordWiFiObservation(ssid: "iPhone", interfaceName: "en0")
    let active = await runtime.monitorOnce()
    XCTAssertEqual(active.verdict, .protected)

    let monitoring = Task { await runtime.monitorOnce() }
    for _ in 0..<1_000 {
      if await sink.isBlocked { break }
      await Task.yield()
    }
    let blocked = await sink.isBlocked
    let beforeLogCompletion = await backend.snapshot()
    await sink.unblock()
    let stopped = await monitoring.value
    let afterLogCompletion = await backend.snapshot()

    XCTAssertTrue(blocked, "fault injection must suspend the diagnostic write")
    XCTAssertEqual(
      beforeLogCompletion.releaseCount, 1,
      "unsafe closed-lid thermal sample must release before diagnostic I/O completes"
    )
    XCTAssertEqual(stopped.phase, .ended)
    XCTAssertEqual(afterLogCompletion.releaseCount, 1)
  }

  func testLidConflictRecordsOneEventPerDisagreementEpisode() async throws {
    let clock = RuntimeManualClock()
    let backend = RuntimeFakeBackend(clock: clock)
    let events = RuntimeFakeEventSink()
    let runtime = SupervisorRuntime(
      backend: backend,
      sampler: RuntimeFakeSampler(snapshots: [
        runtimeSnapshot(ssid: "Office", clock: clock, lidConflict: true),
        runtimeSnapshot(ssid: "iPhone", clock: clock, lidConflict: true),
        runtimeSnapshot(ssid: "iPhone", clock: clock),
        runtimeSnapshot(ssid: "iPhone", clock: clock, lidConflict: true),
      ]),
      statusCache: RuntimeFakeCache(),
      eventRecorder: SupervisorEventRecorder(sink: events, buildID: nil),
      ownerUID: 501, clock: clock, automaticMonitoring: false
    )
    await runtime.recordWiFiObservation(ssid: "Office", interfaceName: "en0")
    _ = try await runtime.startTrip(
      expectedHotspotSSID: "iPhone", hotspotHandoffTimeout: .seconds(900), hardCap: .seconds(3_600)
    )
    await runtime.recordWiFiObservation(ssid: "iPhone", interfaceName: "en0")
    _ = await runtime.monitorOnce()
    _ = await runtime.monitorOnce()
    _ = await runtime.monitorOnce()
    let recorded = await events.snapshot()
    XCTAssertEqual(recorded.filter { $0.kind == .lidStateConflict }.count, 2)
  }

  func testObservationStorageFailuresRemainVisibleWithoutBlockingPowerRelease() async throws {
    let clock = RuntimeManualClock()
    let backend = RuntimeFakeBackend(clock: clock)
    let failedStores = RuntimeFailedObservationStores()
    let runtime = SupervisorRuntime(
      backend: backend,
      sampler: RuntimeFakeSampler(snapshots: [
        runtimeSnapshot(ssid: "Office", clock: clock),
        runtimeSnapshot(ssid: "iPhone", clock: clock),
      ]),
      statusCache: failedStores,
      historyRecorder: failedStores,
      eventRecorder: SupervisorEventRecorder(
        sink: failedStores, buildID: String(repeating: "a", count: 64)
      ),
      ownerUID: 501, clock: clock, automaticMonitoring: false
    )
    await runtime.recordWiFiObservation(ssid: "Office", interfaceName: "en0")
    _ = try await runtime.startTrip(
      expectedHotspotSSID: "iPhone", hotspotHandoffTimeout: .seconds(900), hardCap: .seconds(3_600)
    )
    await runtime.recordWiFiObservation(ssid: "iPhone", interfaceName: "en0")
    let active = await runtime.monitorOnce()
    XCTAssertEqual(active.verdict, .protected)
    let stopped = try await runtime.stop(expectedSessionID: active.sessionID)
    XCTAssertEqual(stopped.phase, .ended)
    XCTAssertEqual(
      stopped.observation?.issues,
      [
        .eventsUnavailable, .historyUnavailable, .statusCacheUnavailable,
      ])
    let calls = await backend.snapshot()
    XCTAssertEqual(calls.releaseCount, 1)
    guard case .available(let live) = await backend.liveStatus() else {
      return XCTFail("missing helper observation")
    }
    XCTAssertEqual(live.sleepOverride, .normal)
  }

  func testHotspotMonitorAcquiresAndCachesProtectedTruth() async throws {
    let clock = RuntimeManualClock()
    let backend = RuntimeFakeBackend(clock: clock)
    let cache = RuntimeFakeCache()
    let sampler = RuntimeFakeSampler(
      snapshots: [
        runtimeSnapshot(ssid: "Office", clock: clock),
        runtimeSnapshot(ssid: "iPhone", clock: clock),
      ]
    )
    let runtime = makeRuntime(
      backend: backend,
      sampler: sampler,
      cache: cache,
      clock: clock
    )

    await runtime.recordWiFiObservation(ssid: "Office", interfaceName: "en0")
    let waiting = try await runtime.startTrip(
      expectedHotspotSSID: "iPhone",
      hotspotHandoffTimeout: .seconds(900),
      hardCap: .seconds(5_400)
    )
    XCTAssertEqual(waiting.verdict, .waitingForHotspot)

    await runtime.recordWiFiObservation(ssid: "iPhone", interfaceName: "en0")
    let active = await runtime.monitorOnce()
    let backendSnapshot = await backend.snapshot()
    let cached = try await cache.load()
    XCTAssertEqual(active.verdict, .protected)
    XCTAssertEqual(backendSnapshot.acquireCount, 1)
    XCTAssertEqual(cached?.verdict, .protected)
  }

  func testSupervisorSSIDAloneCannotAuthorizeWiFiHandoff() async throws {
    let clock = RuntimeManualClock()
    let backend = RuntimeFakeBackend(clock: clock)
    let runtime = makeRuntime(
      backend: backend,
      sampler: RuntimeFakeSampler(
        snapshots: [
          runtimeSnapshot(ssid: "Office", clock: clock),
          runtimeSnapshot(ssid: "iPhone", clock: clock),
        ]
      ),
      cache: RuntimeFakeCache(),
      clock: clock
    )

    _ = try await runtime.startTrip(
      expectedHotspotSSID: "iPhone",
      hotspotHandoffTimeout: .seconds(900),
      hardCap: .seconds(5_400)
    )
    let waiting = await runtime.monitorOnce()
    let backendSnapshot = await backend.snapshot()

    XCTAssertEqual(waiting.verdict, .waitingForHotspot)
    XCTAssertEqual(backendSnapshot.acquireCount, 0)
  }

  func testTrustedMenuBarSSIDAllowsHandoffWhenSupervisorSSIDIsUnavailable() async throws {
    let clock = RuntimeManualClock()
    let backend = RuntimeFakeBackend(clock: clock)
    let runtime = makeRuntime(
      backend: backend,
      sampler: RuntimeFakeSampler(
        snapshots: [
          runtimeSnapshot(ssid: nil, interface: "en0", clock: clock),
          runtimeSnapshot(ssid: nil, interface: "en0", clock: clock),
        ]
      ),
      cache: RuntimeFakeCache(),
      clock: clock
    )
    await runtime.recordWiFiObservation(ssid: "Office", interfaceName: "en0")
    _ = try await runtime.startTrip(
      expectedHotspotSSID: "iPhone",
      hotspotHandoffTimeout: .seconds(900),
      hardCap: .seconds(5_400)
    )
    await runtime.recordWiFiObservation(ssid: "iPhone", interfaceName: "en0")

    let active = await runtime.monitorOnce()
    let backendSnapshot = await backend.snapshot()

    XCTAssertEqual(active.verdict, .protected)
    XCTAssertEqual(backendSnapshot.acquireCount, 1)
  }

  func testStaleMenuBarSSIDCannotAuthorizeHandoff() async throws {
    let clock = RuntimeManualClock()
    let backend = RuntimeFakeBackend(clock: clock)
    let runtime = makeRuntime(
      backend: backend,
      sampler: RuntimeFakeSampler(
        snapshots: [
          runtimeSnapshot(ssid: nil, interface: "en0", clock: clock),
          runtimeSnapshot(ssid: nil, interface: "en0", clock: clock),
        ]
      ),
      cache: RuntimeFakeCache(),
      clock: clock
    )
    await runtime.recordWiFiObservation(ssid: "Office", interfaceName: "en0")
    _ = try await runtime.startTrip(
      expectedHotspotSSID: "iPhone",
      hotspotHandoffTimeout: .seconds(900),
      hardCap: .seconds(5_400)
    )
    await runtime.recordWiFiObservation(ssid: "iPhone", interfaceName: "en0")
    clock.advance(seconds: 16)

    let waiting = await runtime.monitorOnce()
    let backendSnapshot = await backend.snapshot()

    XCTAssertEqual(waiting.verdict, .waitingForHotspot)
    XCTAssertEqual(backendSnapshot.acquireCount, 0)
  }

  func testUSBTetheringMonitorAcquiresAfterInterfaceHandoff() async throws {
    let clock = RuntimeManualClock()
    let backend = RuntimeFakeBackend(clock: clock)
    let runtime = makeRuntime(
      backend: backend,
      sampler: RuntimeFakeSampler(
        snapshots: [
          runtimeSnapshot(ssid: "Office", interface: "en0", clock: clock),
          runtimeSnapshot(ssid: nil, interface: "en5", clock: clock),
        ]
      ),
      cache: RuntimeFakeCache(),
      clock: clock
    )

    let waiting = try await runtime.startTrip(
      networkTarget: .usbTethering,
      hotspotHandoffTimeout: .seconds(900),
      hardCap: .seconds(5_400)
    )
    let active = await runtime.monitorOnce()
    let backendSnapshot = await backend.snapshot()

    XCTAssertEqual(waiting.verdict, .waitingForHotspot)
    XCTAssertEqual(active.verdict, .protected)
    XCTAssertEqual(backendSnapshot.acquireCount, 1)
  }

  func testThermalTripReleasesAndAllowsANewTripAfterDeviceRecovery() async throws {
    let clock = RuntimeManualClock()
    let backend = RuntimeFakeBackend(clock: clock)
    let cache = RuntimeFakeCache()
    let sampler = RuntimeFakeSampler(
      snapshots: [
        runtimeSnapshot(ssid: "Office", clock: clock),
        runtimeSnapshot(ssid: "iPhone", clock: clock),
        runtimeSnapshot(
          ssid: "iPhone",
          clock: clock,
          thermal: .fair,
          lid: .closed
        ),
        runtimeSnapshot(ssid: "Office", clock: clock),
      ]
    )
    let runtime = makeRuntime(
      backend: backend,
      sampler: sampler,
      cache: cache,
      clock: clock
    )
    await runtime.recordWiFiObservation(ssid: "Office", interfaceName: "en0")
    _ = try await runtime.startTrip(
      expectedHotspotSSID: "iPhone",
      hotspotHandoffTimeout: .seconds(900),
      hardCap: .seconds(5_400)
    )
    await runtime.recordWiFiObservation(ssid: "iPhone", interfaceName: "en0")
    _ = await runtime.monitorOnce()

    let stopped = await runtime.monitorOnce()
    let backendSnapshot = await backend.snapshot()

    XCTAssertEqual(stopped.verdict, .unsafe)
    XCTAssertEqual(backendSnapshot.releaseCount, 1)

    let terminal = await runtime.currentStatus()
    XCTAssertEqual(terminal.phase, .ended)
    XCTAssertEqual(terminal.mode, .none)
    XCTAssertEqual(terminal.verdict, .unsafe)
    XCTAssertFalse(terminal.closedLidAllowed)

    await runtime.recordWiFiObservation(ssid: "Office", interfaceName: "en0")
    let restarted = try await runtime.startTrip(
      expectedHotspotSSID: "iPhone",
      hotspotHandoffTimeout: .seconds(900),
      hardCap: .seconds(5_400)
    )
    XCTAssertEqual(restarted.verdict, .waitingForHotspot)
    XCTAssertNotEqual(restarted.sessionID, terminal.sessionID)
    XCTAssertFalse(restarted.closedLidAllowed)
    let afterRestart = await backend.snapshot()
    XCTAssertEqual(afterRestart.acquireCount, 1)
  }

  func testStartupReleasesOwnedOldLeaseAndOverwritesStaleCache() async {
    let clock = RuntimeManualClock()
    let backend = RuntimeFakeBackend(clock: clock, activeLeaseID: UUID())
    let cache = RuntimeFakeCache(
      initial: SupervisorStatusWire(
        phase: .active,
        sessionID: UUID(),
        verdict: .protected,
        remainingSeconds: 600,
        batteryPercent: 80,
        thermalLevel: "nominal",
        lidState: "closed",
        detail: nil,
        updatedAt: Date(timeIntervalSince1970: 1)
      )
    )
    let runtime = makeRuntime(
      backend: backend,
      sampler: RuntimeFakeSampler(snapshots: []),
      cache: cache,
      clock: clock
    )

    let status = await runtime.startup()
    let backendSnapshot = await backend.snapshot()
    let cached = try? await cache.load()

    XCTAssertEqual(status.verdict, .inactive)
    XCTAssertEqual(backendSnapshot.releaseCount, 1)
    XCTAssertEqual(cached?.verdict, .inactive)
  }

  func testStartupRecoveryStaysVisibleAndBlocksNewLeaseUntilHelperIsNormal() async throws {
    let clock = RuntimeManualClock()
    let backend = RuntimeFakeBackend(clock: clock, activeLeaseID: UUID())
    await backend.setReleaseOverride(
      .recoveryPending("normal sleep read-back is pending")
    )
    let cache = RuntimeFakeCache()
    let runtime = makeRuntime(
      backend: backend,
      sampler: RuntimeFakeSampler(snapshots: []),
      cache: cache,
      clock: clock
    )

    let pending = await runtime.startup()
    XCTAssertEqual(pending.phase, .recoveryPending)
    XCTAssertEqual(pending.verdict, .recoveryPending)
    XCTAssertFalse(pending.closedLidAllowed)
    XCTAssertEqual(
      pending.detail,
      "normal sleep read-back is pending"
    )

    do {
      _ = try await runtime.startTrip(
        expectedHotspotSSID: "iPhone",
        hotspotHandoffTimeout: .seconds(900),
        hardCap: .seconds(5_400)
      )
      XCTFail("expected startup recovery rejection")
    } catch {
      XCTAssertEqual(
        error as? SupervisorRuntimeError,
        .startupRecoveryPending
      )
    }

    await backend.completeRecovery()
    let recovered = await runtime.monitorOnce()
    let cached = try await cache.load()
    XCTAssertEqual(recovered.phase, .idle)
    XCTAssertEqual(recovered.verdict, .inactive)
    XCTAssertEqual(cached?.verdict, .inactive)
  }

  func testStopRejectsMismatchedSessionID() async throws {
    let clock = RuntimeManualClock()
    let runtime = makeRuntime(
      backend: RuntimeFakeBackend(clock: clock),
      sampler: RuntimeFakeSampler(
        snapshots: [runtimeSnapshot(ssid: "Office", clock: clock)]
      ),
      cache: RuntimeFakeCache(),
      clock: clock
    )
    _ = try await runtime.startTrip(
      expectedHotspotSSID: "iPhone",
      hotspotHandoffTimeout: .seconds(900),
      hardCap: .seconds(5_400)
    )

    do {
      _ = try await runtime.stop(expectedSessionID: UUID())
      XCTFail("expected session mismatch")
    } catch {
      XCTAssertEqual(error as? SupervisorRuntimeError, .sessionMismatch)
    }
  }

  func testFileCacheRoundTripUsesPrivatePermissions() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "runtinue-supervisor-cache-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("session.json")
    let cache = FileSupervisorStatusCache(fileURL: fileURL)
    let status = SupervisorStatusWire(
      phase: .waitingForHotspot,
      sessionID: UUID(),
      verdict: .waitingForHotspot,
      remainingSeconds: nil,
      batteryPercent: 80,
      thermalLevel: "nominal",
      lidState: "open",
      detail: nil,
      updatedAt: Date(timeIntervalSince1970: 2)
    )

    try await cache.save(status)
    let loaded = try await cache.load()

    XCTAssertEqual(loaded, status)
    let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
  }

  func testAdaptiveActivityAcquiresThenIdleGraceReleases() async throws {
    let clock = RuntimeManualClock()
    let backend = RuntimeFakeBackend(clock: clock)
    let cache = RuntimeFakeCache()
    let config = RuntimeFakeConfigurationStore()
    let runtime = makeRuntime(
      backend: backend,
      sampler: RuntimeFakeSampler(
        snapshots: [runtimeSnapshot(ssid: "Office", clock: clock)]
      ),
      cache: cache,
      configurationStore: config,
      clock: clock
    )

    let enabled = try await runtime.enableAdaptive(
      idleGrace: .seconds(10),
      hardCap: .seconds(3_600)
    )
    XCTAssertEqual(enabled.mode, .adaptive)
    XCTAssertEqual(enabled.verdict, .inactive)

    let active = try await runtime.activityPing(
      source: "codex",
      namedSession: "commute"
    )
    XCTAssertEqual(active.verdict, .protected)
    XCTAssertEqual(
      active.detail,
      "adaptive activity source=codex, session=commute"
    )

    clock.advance(seconds: 10)
    let idle = await runtime.monitorOnce()
    let backendSnapshot = await backend.snapshot()
    XCTAssertEqual(idle.mode, .adaptive)
    XCTAssertEqual(idle.verdict, .inactive)
    XCTAssertEqual(backendSnapshot.releaseCount, 1)
  }

  func testAdaptiveDisableKeepsModeVisibleUntilHelperRecoveryCompletes() async throws {
    let clock = RuntimeManualClock()
    let backend = RuntimeFakeBackend(clock: clock)
    let configurationStore = RuntimeFakeConfigurationStore()
    let runtime = makeRuntime(
      backend: backend,
      sampler: RuntimeFakeSampler(
        snapshots: [runtimeSnapshot(ssid: "Office", clock: clock)]
      ),
      cache: RuntimeFakeCache(),
      configurationStore: configurationStore,
      clock: clock
    )
    _ = try await runtime.enableAdaptive(
      idleGrace: .seconds(120),
      hardCap: .seconds(3_600)
    )
    _ = try await runtime.activityPing()
    await backend.setReleaseOverride(
      .recoveryPending("normal sleep read-back is pending")
    )

    let pending = try await runtime.disableAdaptive()
    let persisted = try await configurationStore.load()

    XCTAssertEqual(pending.mode, .adaptive)
    XCTAssertEqual(pending.verdict, .recoveryPending)
    XCTAssertNil(persisted)

    await backend.completeRecovery()
    let recovered = await runtime.monitorOnce()
    let current = await runtime.currentStatus()

    XCTAssertEqual(recovered.mode, .none)
    XCTAssertEqual(recovered.verdict, .inactive)
    XCTAssertEqual(current.mode, .none)
    XCTAssertEqual(current.verdict, .inactive)
  }

  func testTripStopKeepsModeVisibleUntilHelperRecoveryCompletes() async throws {
    let clock = RuntimeManualClock()
    let backend = RuntimeFakeBackend(clock: clock)
    let runtime = makeRuntime(
      backend: backend,
      sampler: RuntimeFakeSampler(
        snapshots: [
          runtimeSnapshot(ssid: "Office", clock: clock),
          runtimeSnapshot(ssid: "iPhone", clock: clock),
        ]
      ),
      cache: RuntimeFakeCache(),
      clock: clock
    )
    await runtime.recordWiFiObservation(ssid: "Office", interfaceName: "en0")
    _ = try await runtime.startTrip(
      expectedHotspotSSID: "iPhone",
      hotspotHandoffTimeout: .seconds(900),
      hardCap: .seconds(3_600)
    )
    await runtime.recordWiFiObservation(ssid: "iPhone", interfaceName: "en0")
    _ = await runtime.monitorOnce()
    await backend.setReleaseOverride(
      .recoveryPending("normal sleep read-back is pending")
    )

    let pending = try await runtime.stop(expectedSessionID: nil)

    XCTAssertEqual(pending.mode, .trip)
    XCTAssertEqual(pending.verdict, .recoveryPending)

    await backend.completeRecovery()
    let recovered = await runtime.monitorOnce()
    let current = await runtime.currentStatus()

    XCTAssertEqual(recovered.phase, .ended)
    XCTAssertEqual(recovered.verdict, .inactive)
    XCTAssertEqual(current.mode, .none)
    XCTAssertEqual(current.verdict, .inactive)
  }

  func testAdaptiveConfigurationRestoresWithoutTrustingOldSession() async {
    let clock = RuntimeManualClock()
    let config = RuntimeFakeConfigurationStore(
      initial: PersistedSupervisorConfiguration(
        adaptiveIdleGraceSeconds: 120,
        adaptiveHardCapSeconds: 3_600
      )
    )
    let runtime = makeRuntime(
      backend: RuntimeFakeBackend(clock: clock),
      sampler: RuntimeFakeSampler(snapshots: []),
      cache: RuntimeFakeCache(),
      configurationStore: config,
      clock: clock
    )

    let status = await runtime.startup()

    XCTAssertEqual(status.mode, .adaptive)
    XCTAssertEqual(status.verdict, .inactive)
  }

  func testTripCannotStartWhileAdaptiveModeIsEnabled() async throws {
    let clock = RuntimeManualClock()
    let runtime = makeRuntime(
      backend: RuntimeFakeBackend(clock: clock),
      sampler: RuntimeFakeSampler(snapshots: []),
      cache: RuntimeFakeCache(),
      configurationStore: RuntimeFakeConfigurationStore(),
      clock: clock
    )
    _ = try await runtime.enableAdaptive(
      idleGrace: .seconds(120),
      hardCap: .seconds(3_600)
    )

    do {
      _ = try await runtime.startTrip(
        expectedHotspotSSID: "iPhone",
        hotspotHandoffTimeout: .seconds(900),
        hardCap: .seconds(3_600)
      )
      XCTFail("expected mode conflict")
    } catch {
      XCTAssertEqual(error as? SupervisorRuntimeError, .modeConflict)
    }
  }

  func testOpenDeskModeNeverClaimsClosedLidProtection() async throws {
    let clock = RuntimeManualClock()
    let assertion = RuntimeFakePowerAssertionBackend()
    let runtime = makeRuntime(
      backend: RuntimeFakeBackend(clock: clock),
      sampler: RuntimeFakeSampler(
        snapshots: [
          runtimeSnapshot(ssid: "Office", clock: clock),
          runtimeSnapshot(ssid: "Office", clock: clock, lid: .closed),
        ]
      ),
      cache: RuntimeFakeCache(),
      configurationStore: RuntimeFakeConfigurationStore(),
      powerAssertionBackend: assertion,
      clock: clock
    )

    let active = try await runtime.enableDesk(
      allowClosedLid: false,
      hardCap: .seconds(3_600)
    )
    XCTAssertEqual(active.mode, .desk)
    XCTAssertEqual(active.verdict, .protected)
    XCTAssertFalse(active.closedLidAllowed)

    let stopped = await runtime.monitorOnce()
    let assertionSnapshot = await assertion.snapshot()
    XCTAssertEqual(stopped.verdict, .unsafe)
    XCTAssertEqual(assertionSnapshot.releaseCount, 1)
  }

  func testClosedDeskModeUsesLivePrivilegedLeaseTruth() async throws {
    let clock = RuntimeManualClock()
    let backend = RuntimeFakeBackend(clock: clock)
    let runtime = makeRuntime(
      backend: backend,
      sampler: RuntimeFakeSampler(
        snapshots: [runtimeSnapshot(ssid: "Office", clock: clock)]
      ),
      cache: RuntimeFakeCache(),
      configurationStore: RuntimeFakeConfigurationStore(),
      powerAssertionBackend: RuntimeFakePowerAssertionBackend(),
      clock: clock
    )

    let active = try await runtime.enableDesk(
      allowClosedLid: true,
      hardCap: .seconds(3_600)
    )
    let backendSnapshot = await backend.snapshot()

    XCTAssertEqual(active.mode, .desk)
    XCTAssertEqual(active.verdict, .protected)
    XCTAssertTrue(active.closedLidAllowed)
    XCTAssertEqual(backendSnapshot.acquireCount, 1)
  }

  func testDisableAdaptiveRejectsDeskModeWithoutHidingAssertion() async throws {
    let clock = RuntimeManualClock()
    let assertion = RuntimeFakePowerAssertionBackend()
    let runtime = makeRuntime(
      backend: RuntimeFakeBackend(clock: clock),
      sampler: RuntimeFakeSampler(
        snapshots: [runtimeSnapshot(ssid: "Office", clock: clock)]
      ),
      cache: RuntimeFakeCache(),
      configurationStore: RuntimeFakeConfigurationStore(),
      powerAssertionBackend: assertion,
      clock: clock
    )
    _ = try await runtime.enableDesk(
      allowClosedLid: false,
      hardCap: .seconds(3_600)
    )

    do {
      _ = try await runtime.disableAdaptive()
      XCTFail("expected mode conflict")
    } catch {
      XCTAssertEqual(error as? SupervisorRuntimeError, .modeConflict)
    }

    let status = await runtime.currentStatus()
    let assertionSnapshot = await assertion.snapshot()
    XCTAssertEqual(status.mode, .desk)
    XCTAssertEqual(status.verdict, .protected)
    XCTAssertEqual(assertionSnapshot.releaseCount, 0)
    XCTAssertTrue(assertionSnapshot.isActive)
  }

  func testDisableDeskRejectsTripWithoutHidingTrip() async throws {
    let clock = RuntimeManualClock()
    let runtime = makeRuntime(
      backend: RuntimeFakeBackend(clock: clock),
      sampler: RuntimeFakeSampler(
        snapshots: [runtimeSnapshot(ssid: "Office", clock: clock)]
      ),
      cache: RuntimeFakeCache(),
      clock: clock
    )
    _ = try await runtime.startTrip(
      expectedHotspotSSID: "iPhone",
      hotspotHandoffTimeout: .seconds(900),
      hardCap: .seconds(3_600)
    )

    do {
      _ = try await runtime.disableDesk()
      XCTFail("expected mode conflict")
    } catch {
      XCTAssertEqual(error as? SupervisorRuntimeError, .modeConflict)
    }

    let status = await runtime.currentStatus()
    XCTAssertEqual(status.mode, .trip)
    XCTAssertEqual(status.verdict, .waitingForHotspot)
  }

  func testDeskModeIsNotPersistedAcrossSupervisorRestart() async throws {
    let clock = RuntimeManualClock()
    let configurationStore = RuntimeFakeConfigurationStore()
    let runtime = makeRuntime(
      backend: RuntimeFakeBackend(clock: clock),
      sampler: RuntimeFakeSampler(
        snapshots: [runtimeSnapshot(ssid: "Office", clock: clock)]
      ),
      cache: RuntimeFakeCache(),
      configurationStore: configurationStore,
      clock: clock
    )

    _ = try await runtime.enableDesk(
      allowClosedLid: false,
      hardCap: .seconds(3_600)
    )

    let persisted = try await configurationStore.load()
    XCTAssertNil(persisted)
  }

  private func makeRuntime(
    backend: RuntimeFakeBackend,
    sampler: RuntimeFakeSampler,
    cache: RuntimeFakeCache,
    configurationStore: RuntimeFakeConfigurationStore? = nil,
    powerAssertionBackend: any UserPowerAssertionBackend =
      RuntimeFakePowerAssertionBackend(),
    clock: RuntimeManualClock
  ) -> SupervisorRuntime {
    SupervisorRuntime(
      backend: backend,
      sampler: sampler,
      statusCache: cache,
      configurationStore: configurationStore,
      powerAssertionBackend: powerAssertionBackend,
      ownerUID: 501,
      clock: clock,
      automaticMonitoring: false
    )
  }
}

private actor RuntimeFakeBackend: SupervisorLeaseBackend {
  struct Snapshot: Sendable {
    let acquireCount: Int
    let releaseCount: Int
    let renewCount: Int
  }

  private let clock: RuntimeManualClock
  private var observation: SupervisorHelperObservation
  private var releaseOverride: LeaseReleaseOutcome?
  private var acquireCount = 0
  private var releaseCount = 0
  private var renewCount = 0

  init(clock: RuntimeManualClock, activeLeaseID: UUID? = nil) {
    self.clock = clock
    if let activeLeaseID {
      let now = clock.now()
      self.observation = SupervisorHelperObservation(
        phase: .active,
        leaseID: activeLeaseID,
        ownerUID: 501,
        sleepOverride: .disabled,
        ttlDeadline: now.adding(.seconds(90)),
        hardDeadline: now.adding(.seconds(5_400)),
        detail: nil
      )
    } else {
      self.observation = Self.idleObservation()
    }
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
    if let releaseOverride {
      return releaseOverride
    }
    observation = Self.idleObservation()
    return .released
  }

  func renew(leaseID: UUID, ttl: Duration) async -> SupervisorHeartbeatResult {
    renewCount += 1
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
    guard let leaseID = observation.leaseID, observation.ownerUID == 501 else {
      return .released
    }
    return await release(
      sessionID: leaseID,
      lease: LeaseToken(id: leaseID),
      reason: .superseded
    )
  }

  func snapshot() -> Snapshot {
    Snapshot(
      acquireCount: acquireCount,
      releaseCount: releaseCount,
      renewCount: renewCount
    )
  }

  func setReleaseOverride(_ outcome: LeaseReleaseOutcome?) {
    releaseOverride = outcome
  }

  func completeRecovery() {
    releaseOverride = nil
    observation = Self.idleObservation()
  }

  private static func idleObservation() -> SupervisorHelperObservation {
    SupervisorHelperObservation(
      phase: .idle,
      leaseID: nil,
      ownerUID: nil,
      sleepOverride: .normal,
      ttlDeadline: nil,
      hardDeadline: nil,
      detail: nil
    )
  }
}

private actor RuntimeFakeSampler: SupervisorEnvironmentSampling {
  private var snapshots: [(network: NetworkSnapshot, device: DeviceSafetySnapshot)]

  init(snapshots: [(network: NetworkSnapshot, device: DeviceSafetySnapshot)]) {
    self.snapshots = snapshots
  }

  func sample(
    commuteTarget: CommuteNetworkTarget?
  ) async -> (network: NetworkSnapshot, device: DeviceSafetySnapshot) {
    precondition(!snapshots.isEmpty, "missing fake environment snapshot")
    if snapshots.count == 1 {
      return snapshots[0]
    }
    return snapshots.removeFirst()
  }
}

private actor RuntimeBlockingTemperatureSampler: TemperatureTelemetrySampling {
  private var shouldBlockNextSample = false
  private var continuation: CheckedContinuation<Void, Never>?
  private(set) var isBlocked = false
  private(set) var sampleCount = 0

  func blockNextSample() {
    shouldBlockNextSample = true
  }

  func sample() async -> TemperatureTelemetrySnapshot {
    sampleCount += 1
    if shouldBlockNextSample {
      shouldBlockNextSample = false
      isBlocked = true
      await withCheckedContinuation { continuation = $0 }
      isBlocked = false
    }
    let sampledAt = Date(timeIntervalSince1970: 1_000)
    return TemperatureTelemetrySnapshot(
      status: .temporarilyUnavailable,
      source: .appleSMC,
      machineModel: "Mac17,8",
      operatingSystemBuild: "25F84",
      mappingRevision: "Mac17,8-apple-smc-r1",
      mappingQuality: .singleDeviceValidated,
      sampledAt: sampledAt,
      validUntil: nil,
      lastSuccessfulAt: nil,
      components: []
    )
  }

  func unblock() {
    continuation?.resume()
    continuation = nil
  }
}

private actor RuntimeCancellableTemperatureSampler: TemperatureTelemetrySampling {
  private(set) var isSampling = false
  private(set) var observedCancellation = false

  func sample() async -> TemperatureTelemetrySnapshot {
    isSampling = true
    do {
      try await Task.sleep(for: .seconds(3_600))
    } catch {
      observedCancellation = Task.isCancelled
    }
    isSampling = false
    let sampledAt = Date(timeIntervalSince1970: 1_000)
    return TemperatureTelemetrySnapshot(
      status: .temporarilyUnavailable,
      source: .appleSMC,
      machineModel: "Mac17,8",
      operatingSystemBuild: "25F84",
      mappingRevision: "Mac17,8-apple-smc-r1",
      mappingQuality: .singleDeviceValidated,
      sampledAt: sampledAt,
      validUntil: nil,
      lastSuccessfulAt: nil,
      components: []
    )
  }
}

private actor RuntimeTemperatureMonitorCompletion {
  private(set) var isFinished = false

  func finish() {
    isFinished = true
  }
}

private actor RuntimeFakeCache: SupervisorStatusCaching {
  private var status: SupervisorStatusWire?

  init(initial: SupervisorStatusWire? = nil) {
    self.status = initial
  }

  func save(_ status: SupervisorStatusWire) async throws {
    self.status = status
  }

  func load() async throws -> SupervisorStatusWire? {
    status
  }
}

private actor RuntimeFakeEventSink: SupervisorEventRecording {
  private var events: [SupervisorEvent] = []
  func record(_ event: SupervisorEvent) { events.append(event) }
  func snapshot() -> [SupervisorEvent] { events }
}

private actor RuntimeBlockingLidEventSink: SupervisorEventRecording {
  private var resumed = false
  private var continuation: CheckedContinuation<Void, Never>?
  private(set) var isBlocked = false

  func record(_ event: SupervisorEvent) async {
    guard event.kind == .lidStateConflict, !resumed else { return }
    isBlocked = true
    await withCheckedContinuation { continuation = $0 }
  }

  func unblock() {
    resumed = true
    continuation?.resume()
    continuation = nil
  }
}

private actor RuntimeFailedObservationStores:
  SupervisorStatusCaching, SupervisorHistoryRecording, SupervisorEventRecording
{
  func save(_ status: SupervisorStatusWire) throws { throw CocoaError(.fileWriteNoPermission) }
  func load() -> SupervisorStatusWire? { nil }
  func record(_ status: SupervisorStatusWire) throws { throw CocoaError(.fileWriteNoPermission) }
  func record(_ event: SupervisorEvent) throws { throw CocoaError(.fileWriteNoPermission) }
}

private actor RuntimeFakeConfigurationStore: SupervisorConfigurationCaching {
  private var configuration: PersistedSupervisorConfiguration?

  init(initial: PersistedSupervisorConfiguration? = nil) {
    self.configuration = initial
  }

  func save(_ configuration: PersistedSupervisorConfiguration) async throws {
    self.configuration = configuration
  }

  func load() async throws -> PersistedSupervisorConfiguration? {
    configuration
  }

  func remove() async throws {
    configuration = nil
  }
}

private actor RuntimeFakePowerAssertionBackend: UserPowerAssertionBackend {
  struct Snapshot: Sendable {
    let acquireCount: Int
    let releaseCount: Int
    let isActive: Bool
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
    active = nil
    releaseCount += 1
  }

  func snapshot() -> Snapshot {
    Snapshot(
      acquireCount: acquireCount,
      releaseCount: releaseCount,
      isActive: active != nil
    )
  }
}

private final class RuntimeManualClock: @unchecked Sendable, MonotonicTimeSource {
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

private func runtimeSnapshot(
  ssid: String?,
  interface: String = "en0",
  clock: RuntimeManualClock,
  thermal: ThermalLevel = .nominal,
  lid: LidState = .open,
  lidConflict: Bool = false
) -> (network: NetworkSnapshot, device: DeviceSafetySnapshot) {
  (
    NetworkSnapshot(
      ssid: ssid,
      interfaceName: interface,
      routeReachable: true,
      internetReachability: .confirmed,
      capturedAt: clock.now()
    ),
    DeviceSafetySnapshot(
      batteryPercent: 80,
      powerConnection: .battery,
      thermalLevel: thermal,
      lidState: lid,
      externalDisplayState: .absent,
      lowPowerModeEnabled: false,
      lidSignalsDisagree: lidConflict,
      capturedAt: clock.now()
    )
  )
}
