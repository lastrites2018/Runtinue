import Foundation
import RuntinueCore
import RuntinueIPC
import RuntinueSupervisorCore
import RuntinueUserSupport

public protocol SupervisorEnvironmentSampling: Sendable {
  func sample(
    commuteTarget: CommuteNetworkTarget?
  ) async -> (network: NetworkSnapshot, device: DeviceSafetySnapshot)
}

public protocol SupervisorStatusCaching: Sendable {
  func save(_ status: SupervisorStatusWire) async throws
  func load() async throws -> SupervisorStatusWire?
}

public enum SupervisorRuntimeError: Error, Equatable, Sendable {
  case sessionMismatch
  case sessionNotRunning
  case modeConflict
  case invalidAdaptiveConfiguration
  case invalidDeskConfiguration
  case adaptiveNotEnabled
  case deskNotEnabled
  case adaptiveSessionUnavailable
  case startupRecoveryPending
}

public struct AdaptiveModeConfiguration: Equatable, Sendable {
  public let idleGrace: Duration
  public let hardCap: Duration

  public init(idleGrace: Duration, hardCap: Duration) {
    self.idleGrace = idleGrace
    self.hardCap = hardCap
  }
}

public struct DeskModeConfiguration: Equatable, Sendable {
  public let allowClosedLid: Bool
  public let hardCap: Duration

  public init(allowClosedLid: Bool, hardCap: Duration) {
    self.allowClosedLid = allowClosedLid
    self.hardCap = hardCap
  }
}

public actor SupervisorRuntime {
  public static let monitoringInterval: Duration = .seconds(5)
  private static let trustedWiFiObservationMaximumAge: Duration = .seconds(15)

  private struct TrustedWiFiObservation: Sendable {
    let ssid: String
    let interfaceName: String
    let receivedAt: MonotonicInstant
  }

  private let backend: any SupervisorLeaseBackend
  private let controller: SafetySupervisorController
  private let directController: DirectSafetyLeaseController
  private let deskController: DeskModeController
  private let sampler: any SupervisorEnvironmentSampling
  private let statusCache: any SupervisorStatusCaching
  private let historyRecorder: (any SupervisorHistoryRecording)?
  private let eventRecorder: SupervisorEventRecorder?
  private let configurationStore: (any SupervisorConfigurationCaching)?
  private let clock: any MonotonicTimeSource
  private let monitorInterval: Duration
  private let automaticMonitoring: Bool

  private var hasStarted = false
  private var commuteTarget: CommuteNetworkTarget?
  private var adaptiveConfiguration: AdaptiveModeConfiguration?
  private var deskConfiguration: DeskModeConfiguration?
  private var lastAdaptiveActivity: MonotonicInstant?
  private var lastAdaptiveActivitySource: String?
  private var lastAdaptiveNamedSession: String?
  private var adaptiveDisablePending = false
  private var deskDisablePending = false
  private var trustedWiFiObservation: TrustedWiFiObservation?
  private var startupRecoveryDetail: String?
  private var monitorTask: Task<Void, Never>?

  public init(
    backend: any SupervisorLeaseBackend,
    sampler: any SupervisorEnvironmentSampling,
    statusCache: any SupervisorStatusCaching,
    historyRecorder: (any SupervisorHistoryRecording)? = nil,
    eventRecorder: SupervisorEventRecorder? = nil,
    configurationStore: (any SupervisorConfigurationCaching)? = nil,
    powerAssertionBackend: any UserPowerAssertionBackend =
      UnavailableUserPowerAssertionBackend(),
    ownerUID: UInt32,
    clock: any MonotonicTimeSource = SystemUptimeClock(),
    monitorInterval: Duration = SupervisorRuntime.monitoringInterval,
    automaticMonitoring: Bool = true
  ) {
    self.backend = backend
    self.controller = SafetySupervisorController(
      leaseBackend: backend,
      ownerUID: ownerUID,
      clock: clock
    )
    let directController = DirectSafetyLeaseController(
      leaseBackend: backend,
      ownerUID: ownerUID,
      clock: clock
    )
    self.directController = directController
    self.deskController = DeskModeController(
      directController: DirectSafetyLeaseController(
        leaseBackend: backend,
        ownerUID: ownerUID,
        clock: clock
      ),
      assertionBackend: powerAssertionBackend,
      clock: clock
    )
    self.sampler = sampler
    self.statusCache = statusCache
    self.historyRecorder = historyRecorder
    self.eventRecorder = eventRecorder
    self.configurationStore = configurationStore
    self.clock = clock
    self.monitorInterval = monitorInterval
    self.automaticMonitoring = automaticMonitoring
  }

  @discardableResult
  public func startup() async -> SupervisorStatusWire {
    if hasStarted {
      return await currentStatus()
    }
    hasStarted = true
    switch await backend.releaseExistingOwnedLease() {
    case .released:
      startupRecoveryDetail = nil
    case .recoveryPending(let detail):
      startupRecoveryDetail = detail
    }
    await restoreConfiguration()
    if startupRecoveryDetail != nil || adaptiveConfiguration != nil || deskConfiguration != nil,
      automaticMonitoring
    {
      startMonitorIfNeeded()
    }
    let status: SupervisorStatusWire
    if let startupRecoveryDetail {
      status = makeStartupRecoveryStatus(detail: startupRecoveryDetail)
    } else if let deskConfiguration {
      status = makeWireStatus(
        await deskController.status(),
        mode: .desk,
        closedLidAllowed: deskConfiguration.allowClosedLid
      )
    } else if adaptiveConfiguration != nil {
      status = makeWireStatus(
        await directController.status(),
        mode: .adaptive
      )
    } else {
      status = makeWireStatus(await controller.status(), mode: .none)
    }
    await eventRecorder?.record(.supervisorStarted)
    return await persist(status)
  }

  public func recordEvent(
    _ kind: SupervisorEventKind, attemptID: UUID? = nil, sessionID: UUID? = nil,
    command: SupervisorCommandKind? = nil, stopReason: WireSessionStopReason? = nil
  ) async {
    await eventRecorder?.record(
      kind, attemptID: attemptID, sessionID: sessionID, command: command, stopReason: stopReason
    )
  }

  public func recordWiFiObservation(
    ssid: String?,
    interfaceName: String?
  ) {
    guard let ssid, let interfaceName else {
      trustedWiFiObservation = nil
      return
    }
    trustedWiFiObservation = TrustedWiFiObservation(
      ssid: ssid,
      interfaceName: interfaceName,
      receivedAt: clock.now()
    )
  }

  @discardableResult
  public func startTrip(
    expectedHotspotSSID: String,
    hotspotHandoffTimeout: Duration,
    hardCap: Duration
  ) async throws -> SupervisorStatusWire {
    try await startTrip(
      networkTarget: .wifiHotspot(ssid: expectedHotspotSSID),
      hotspotHandoffTimeout: hotspotHandoffTimeout,
      hardCap: hardCap
    )
  }

  @discardableResult
  public func startTrip(
    networkTarget: CommuteNetworkTarget,
    hotspotHandoffTimeout: Duration,
    hardCap: Duration
  ) async throws -> SupervisorStatusWire {
    _ = await startup()
    guard startupRecoveryDetail == nil else {
      throw SupervisorRuntimeError.startupRecoveryPending
    }
    guard adaptiveConfiguration == nil, deskConfiguration == nil else {
      throw SupervisorRuntimeError.modeConflict
    }
    guard commuteTarget == nil else {
      throw SupervisorRuntimeError.modeConflict
    }
    let origin = await sampleEnvironment(commuteTarget: nil)
    let request = CommuteTripRequest(
      networkTarget: networkTarget,
      hotspotHandoffTimeout: hotspotHandoffTimeout,
      hardCap: hardCap
    )
    let status = try await controller.start(
      request,
      originNetwork: origin.network,
      device: origin.device
    )
    self.commuteTarget = request.networkTarget
    if automaticMonitoring {
      startMonitorIfNeeded()
    }
    let wire = makeWireStatus(status, mode: .trip)
    return await persist(wire)
  }

  @discardableResult
  public func monitorOnce() async -> SupervisorStatusWire {
    if startupRecoveryDetail != nil {
      return await monitorStartupRecovery()
    }
    if let commuteTarget {
      return await monitorTrip(commuteTarget: commuteTarget)
    }
    if let adaptiveConfiguration {
      return await monitorAdaptive(configuration: adaptiveConfiguration)
    }
    if let deskConfiguration {
      return await monitorDesk(configuration: deskConfiguration)
    }
    return await currentStatus()
  }

  private func monitorStartupRecovery() async -> SupervisorStatusWire {
    switch await backend.liveStatus() {
    case .available(let helper)
    where helper.phase == .idle && helper.sleepOverride == .normal:
      startupRecoveryDetail = nil
      if adaptiveConfiguration == nil && deskConfiguration == nil && commuteTarget == nil {
        stopMonitor()
      }
      return await currentStatus()
    case .available(let helper):
      startupRecoveryDetail = helper.detail ?? "helper startup recovery is pending"
    case .unavailable(let detail):
      startupRecoveryDetail = detail
    }
    let wire = makeStartupRecoveryStatus(
      detail: startupRecoveryDetail ?? "helper startup recovery is pending"
    )
    return await persist(wire)
  }

  private func monitorTrip(
    commuteTarget: CommuteNetworkTarget
  ) async -> SupervisorStatusWire {
    let current = await controller.status()
    let status: SupervisorStatus
    if current.trip.phase == .recoveryPending {
      status = await controller.reconcileRecovery()
    } else {
      let snapshot = await sampleEnvironment(
        commuteTarget: commuteTarget
      )
      _ = await controller.observe(
        network: snapshot.network,
        device: snapshot.device
      )
      status = await controller.tick()
    }
    let wire = makeWireStatus(status, mode: .trip)
    if isTerminal(wire.phase) {
      stopMonitor()
      self.commuteTarget = nil
    }
    return await persist(wire)
  }

  private func monitorAdaptive(
    configuration: AdaptiveModeConfiguration
  ) async -> SupervisorStatusWire {
    let current = await directController.status()
    var status = current
    switch current.trip.phase {
    case .acquiringLease, .active:
      let snapshot = await sampleEnvironment(commuteTarget: nil)
      status = await directController.observe(device: snapshot.device)
      if let lastAdaptiveActivity,
        let idleAge = clock.now().durationSince(lastAdaptiveActivity),
        idleAge >= configuration.idleGrace,
        status.trip.phase == .active
      {
        status = await directController.stop(reason: .userRequested)
      }
    case .recoveryPending:
      status = await directController.reconcileRecovery()
    case .idle, .waitingForHotspot, .releasingLease, .ended:
      break
    }
    if adaptiveDisablePending,
      status.trip.phase == .idle || status.trip.phase == .ended
    {
      adaptiveConfiguration = nil
      adaptiveDisablePending = false
      stopMonitor()
    }
    let wire = makeWireStatus(
      status,
      mode: adaptiveConfiguration == nil ? .none : .adaptive,
      protectedDetail: adaptiveActivityDetail
    )
    return await persist(wire)
  }

  private func monitorDesk(
    configuration: DeskModeConfiguration
  ) async -> SupervisorStatusWire {
    let current = await deskController.status()
    var status = current
    switch current.trip.phase {
    case .acquiringLease, .active:
      let snapshot = await sampleEnvironment(commuteTarget: nil)
      status = await deskController.observe(device: snapshot.device)
    case .recoveryPending:
      status = await deskController.reconcileRecovery()
    case .idle, .waitingForHotspot, .releasingLease, .ended:
      break
    }
    if status.trip.phase == .idle || status.trip.phase == .ended {
      deskConfiguration = nil
      deskDisablePending = false
      stopMonitor()
      try? await configurationStore?.remove()
    }
    let wire = makeWireStatus(
      status,
      mode: deskConfiguration == nil ? .none : .desk,
      closedLidAllowed: configuration.allowClosedLid
    )
    return await persist(wire)
  }

  @discardableResult
  public func enableAdaptive(
    idleGrace: Duration,
    hardCap: Duration
  ) async throws -> SupervisorStatusWire {
    _ = await startup()
    guard startupRecoveryDetail == nil else {
      throw SupervisorRuntimeError.startupRecoveryPending
    }
    guard commuteTarget == nil,
      adaptiveConfiguration == nil,
      deskConfiguration == nil
    else {
      throw SupervisorRuntimeError.modeConflict
    }
    guard idleGrace > .zero,
      idleGrace <= .seconds(60 * 60),
      hardCap > .zero,
      hardCap <= CommuteTripRequest.maximumHardCap
    else {
      throw SupervisorRuntimeError.invalidAdaptiveConfiguration
    }
    adaptiveConfiguration = AdaptiveModeConfiguration(
      idleGrace: idleGrace,
      hardCap: hardCap
    )
    lastAdaptiveActivity = nil
    lastAdaptiveActivitySource = nil
    lastAdaptiveNamedSession = nil
    adaptiveDisablePending = false
    await persistAdaptiveConfiguration()
    if automaticMonitoring {
      startMonitorIfNeeded()
    }
    let wire = makeWireStatus(
      await directController.status(),
      mode: .adaptive,
      inactiveDetail: "adaptive mode is waiting for activity"
    )
    return await persist(wire)
  }

  @discardableResult
  public func disableAdaptive() async throws -> SupervisorStatusWire {
    _ = await startup()
    guard adaptiveConfiguration != nil else {
      if commuteTarget != nil || deskConfiguration != nil {
        throw SupervisorRuntimeError.modeConflict
      }
      throw SupervisorRuntimeError.adaptiveNotEnabled
    }
    let current = await directController.status()
    adaptiveDisablePending = true
    let status: SupervisorStatus
    switch current.trip.phase {
    case .acquiringLease, .active:
      status = await directController.stop(reason: .userRequested)
    case .recoveryPending:
      status = await directController.reconcileRecovery()
    case .idle, .waitingForHotspot, .releasingLease, .ended:
      status = current
    }
    lastAdaptiveActivity = nil
    lastAdaptiveActivitySource = nil
    lastAdaptiveNamedSession = nil
    try? await configurationStore?.remove()
    if status.trip.phase == .idle || status.trip.phase == .ended {
      adaptiveConfiguration = nil
      adaptiveDisablePending = false
      if startupRecoveryDetail == nil {
        stopMonitor()
      }
    }
    let wire: SupervisorStatusWire
    if let startupRecoveryDetail {
      wire = makeStartupRecoveryStatus(detail: startupRecoveryDetail)
    } else {
      wire = makeWireStatus(
        status,
        mode: adaptiveConfiguration == nil ? .none : .adaptive
      )
    }
    return await persist(wire)
  }

  @discardableResult
  public func activityPing(
    source: String = "activity",
    namedSession: String? = nil
  ) async throws -> SupervisorStatusWire {
    _ = await startup()
    guard startupRecoveryDetail == nil else {
      throw SupervisorRuntimeError.startupRecoveryPending
    }
    guard let adaptiveConfiguration else {
      throw SupervisorRuntimeError.adaptiveNotEnabled
    }
    guard !adaptiveDisablePending else {
      throw SupervisorRuntimeError.adaptiveSessionUnavailable
    }
    lastAdaptiveActivity = clock.now()
    lastAdaptiveActivitySource = source
    lastAdaptiveNamedSession = namedSession
    let current = await directController.status()
    let status: SupervisorStatus
    switch current.trip.phase {
    case .idle, .ended:
      let snapshot = await sampleEnvironment(commuteTarget: nil)
      status = try await directController.start(
        hardCap: adaptiveConfiguration.hardCap,
        device: snapshot.device
      )
    case .acquiringLease, .active:
      let snapshot = await sampleEnvironment(commuteTarget: nil)
      status = await directController.observe(device: snapshot.device)
    case .waitingForHotspot, .releasingLease, .recoveryPending:
      throw SupervisorRuntimeError.adaptiveSessionUnavailable
    }
    if automaticMonitoring {
      startMonitorIfNeeded()
    }
    let wire = makeWireStatus(
      status,
      mode: .adaptive,
      protectedDetail: adaptiveActivityDetail
    )
    return await persist(wire)
  }

  @discardableResult
  public func enableDesk(
    allowClosedLid: Bool,
    hardCap: Duration
  ) async throws -> SupervisorStatusWire {
    _ = await startup()
    guard startupRecoveryDetail == nil else {
      throw SupervisorRuntimeError.startupRecoveryPending
    }
    guard commuteTarget == nil,
      adaptiveConfiguration == nil,
      deskConfiguration == nil
    else {
      throw SupervisorRuntimeError.modeConflict
    }
    guard hardCap > .zero, hardCap <= CommuteTripRequest.maximumHardCap else {
      throw SupervisorRuntimeError.invalidDeskConfiguration
    }
    let snapshot = await sampleEnvironment(commuteTarget: nil)
    let status = try await deskController.start(
      allowClosedLid: allowClosedLid,
      hardCap: hardCap,
      device: snapshot.device
    )
    deskConfiguration = DeskModeConfiguration(
      allowClosedLid: allowClosedLid,
      hardCap: hardCap
    )
    deskDisablePending = false
    if automaticMonitoring {
      startMonitorIfNeeded()
    }
    let wire = makeWireStatus(
      status,
      mode: .desk,
      closedLidAllowed: allowClosedLid
    )
    return await persist(wire)
  }

  @discardableResult
  public func disableDesk() async throws -> SupervisorStatusWire {
    _ = await startup()
    guard deskConfiguration != nil else {
      if commuteTarget != nil || adaptiveConfiguration != nil {
        throw SupervisorRuntimeError.modeConflict
      }
      throw SupervisorRuntimeError.deskNotEnabled
    }
    deskDisablePending = true
    let status = await deskController.stop()
    if status.trip.phase == .idle || status.trip.phase == .ended {
      deskConfiguration = nil
      deskDisablePending = false
      stopMonitor()
    }
    try? await configurationStore?.remove()
    let wire = makeWireStatus(
      status,
      mode: deskConfiguration == nil ? .none : .desk,
      closedLidAllowed: false
    )
    return await persist(wire)
  }

  @discardableResult
  public func stop(expectedSessionID: UUID?) async throws -> SupervisorStatusWire {
    _ = await startup()
    let usesDesk = deskConfiguration != nil
    let usesAdaptive = adaptiveConfiguration != nil && commuteTarget == nil
    let current: SupervisorStatus
    if usesDesk {
      current = await deskController.status()
    } else if usesAdaptive {
      current = await directController.status()
    } else {
      current = await controller.status()
    }
    guard let currentID = current.trip.sessionID else {
      throw SupervisorRuntimeError.sessionNotRunning
    }
    if let expectedSessionID, expectedSessionID != currentID {
      throw SupervisorRuntimeError.sessionMismatch
    }
    let status: SupervisorStatus
    if usesDesk {
      deskDisablePending = true
      status = await deskController.stop()
      if status.trip.phase == .idle || status.trip.phase == .ended {
        deskConfiguration = nil
        deskDisablePending = false
        stopMonitor()
      }
      try? await configurationStore?.remove()
    } else if usesAdaptive {
      status = await directController.stop()
    } else {
      status = await controller.stop()
      if status.trip.phase == .idle || status.trip.phase == .ended {
        commuteTarget = nil
        stopMonitor()
      } else if automaticMonitoring {
        startMonitorIfNeeded()
      }
    }
    let wire = makeWireStatus(
      status,
      mode: usesDesk
        ? (deskConfiguration == nil ? .none : .desk)
        : (usesAdaptive ? .adaptive : .trip),
      closedLidAllowed: false
    )
    return await persist(wire)
  }

  public func currentStatus() async -> SupervisorStatusWire {
    if !hasStarted {
      _ = await startup()
    }
    let wire: SupervisorStatusWire
    if let startupRecoveryDetail {
      wire = makeStartupRecoveryStatus(detail: startupRecoveryDetail)
    } else if let deskConfiguration {
      wire = makeWireStatus(
        await deskController.status(),
        mode: .desk,
        closedLidAllowed: deskConfiguration.allowClosedLid
      )
    } else if adaptiveConfiguration != nil, commuteTarget == nil {
      wire = makeWireStatus(
        await directController.status(),
        mode: .adaptive,
        inactiveDetail: "adaptive mode is waiting for activity",
        protectedDetail: adaptiveActivityDetail
      )
    } else {
      wire = makeWireStatus(
        await controller.status(),
        mode: commuteTarget == nil ? .none : .trip
      )
    }
    return await persist(wire)
  }

  @discardableResult
  public func shutdown() async -> SupervisorStatusWire {
    stopMonitor()
    if let startupRecoveryDetail {
      let wire = makeStartupRecoveryStatus(detail: startupRecoveryDetail)
      return await persist(wire)
    }
    commuteTarget = nil
    let tripCurrent = await controller.status()
    let tripStatus: SupervisorStatus
    switch tripCurrent.trip.phase {
    case .waitingForHotspot, .acquiringLease, .active:
      tripStatus = await controller.stop()
    case .idle, .releasingLease, .ended, .recoveryPending:
      tripStatus = tripCurrent
    }
    let directCurrent = await directController.status()
    let directStatus: SupervisorStatus
    switch directCurrent.trip.phase {
    case .acquiringLease, .active:
      directStatus = await directController.stop(reason: .userRequested)
    case .idle, .waitingForHotspot, .releasingLease, .ended, .recoveryPending:
      directStatus = directCurrent
    }
    let deskCurrent = await deskController.status()
    let deskStatus: SupervisorStatus
    switch deskCurrent.trip.phase {
    case .acquiringLease, .active:
      deskStatus = await deskController.stop()
    case .idle, .waitingForHotspot, .releasingLease, .ended, .recoveryPending:
      deskStatus = deskCurrent
    }
    let useDesk = deskCurrent.trip.sessionID != nil
    let useDirect = !useDesk && directCurrent.trip.sessionID != nil
    let wire = makeWireStatus(
      useDesk ? deskStatus : (useDirect ? directStatus : tripStatus),
      mode: useDesk ? .desk : (adaptiveConfiguration == nil ? .none : .adaptive),
      closedLidAllowed: false
    )
    return await persist(wire)
  }

  private func startMonitorIfNeeded() {
    guard monitorTask == nil else {
      return
    }
    monitorTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else {
          return
        }
        try? await Task.sleep(for: self.monitorInterval)
        guard !Task.isCancelled else {
          return
        }
        _ = await self.monitorOnce()
      }
    }
  }

  private func sampleEnvironment(
    commuteTarget: CommuteNetworkTarget?
  ) async -> (network: NetworkSnapshot, device: DeviceSafetySnapshot) {
    let sampled = await sampler.sample(commuteTarget: commuteTarget)
    if commuteTarget == .usbTethering {
      return sampled
    }
    guard let trustedWiFiObservation,
      sampled.network.interfaceName == trustedWiFiObservation.interfaceName,
      let age = clock.now().durationSince(trustedWiFiObservation.receivedAt),
      age <= Self.trustedWiFiObservationMaximumAge
    else {
      if case .wifiHotspot = commuteTarget {
        return (
          replacingSSID(in: sampled.network, with: nil),
          sampled.device
        )
      }
      return sampled
    }
    return (
      replacingSSID(
        in: sampled.network,
        with: trustedWiFiObservation.ssid
      ),
      sampled.device
    )
  }

  private func replacingSSID(
    in network: NetworkSnapshot,
    with ssid: String?
  ) -> NetworkSnapshot {
    NetworkSnapshot(
      ssid: ssid,
      interfaceName: network.interfaceName,
      gateway: network.gateway,
      routeReachable: network.routeReachable,
      internetReachability: network.internetReachability,
      capturedAt: network.capturedAt
    )
  }

  private func stopMonitor() {
    monitorTask?.cancel()
    monitorTask = nil
  }

  private func persist(_ status: SupervisorStatusWire) async -> SupervisorStatusWire {
    await eventRecorder?.observe(status)
    var issues = await eventRecorder?.issues() ?? []
    let buildID = eventRecorder?.buildID
    let observed = status.withObservation(
      eventRecorder == nil ? nil : WireObservationStatus(buildID: buildID, issues: issues)
    )
    do {
      try await historyRecorder?.record(observed)
    } catch {
      issues.append(.historyUnavailable)
    }
    let published = observed.withObservation(
      eventRecorder == nil && issues.isEmpty
        ? nil : WireObservationStatus(buildID: buildID, issues: issues)
    )
    do {
      try await statusCache.save(published)
    } catch {
      issues.append(.statusCacheUnavailable)
    }
    return published.withObservation(
      eventRecorder == nil && issues.isEmpty
        ? nil : WireObservationStatus(buildID: buildID, issues: issues)
    )
  }

  private func restoreConfiguration() async {
    guard let stored = try? await configurationStore?.load(),
      stored.version == PersistedSupervisorConfiguration.currentVersion
    else {
      return
    }
    if let idleGraceSeconds = stored.adaptiveIdleGraceSeconds,
      let hardCapSeconds = stored.adaptiveHardCapSeconds,
      idleGraceSeconds.isFinite,
      hardCapSeconds.isFinite,
      idleGraceSeconds > 0,
      idleGraceSeconds <= 60 * 60,
      hardCapSeconds > 0,
      hardCapSeconds <= 24 * 60 * 60
    {
      adaptiveConfiguration = AdaptiveModeConfiguration(
        idleGrace: .seconds(idleGraceSeconds),
        hardCap: .seconds(hardCapSeconds)
      )
      return
    }
    if stored.deskHardCapSeconds != nil {
      try? await configurationStore?.remove()
    }
  }

  private func persistAdaptiveConfiguration() async {
    guard let adaptiveConfiguration else {
      return
    }
    try? await configurationStore?.save(
      PersistedSupervisorConfiguration(
        adaptiveIdleGraceSeconds: adaptiveConfiguration.idleGrace.secondsValue,
        adaptiveHardCapSeconds: adaptiveConfiguration.hardCap.secondsValue
      )
    )
  }

  private func isTerminal(_ phase: WireTripPhase) -> Bool {
    switch phase {
    case .idle, .ended:
      true
    case .waitingForHotspot, .acquiringLease, .active, .releasingLease,
      .recoveryPending:
      false
    }
  }

  private func makeWireStatus(
    _ status: SupervisorStatus,
    mode: WireSessionMode,
    inactiveDetail: String? = nil,
    protectedDetail: String? = nil,
    closedLidAllowed: Bool = true
  ) -> SupervisorStatusWire {
    let verdict: WireProtectionVerdict
    let remainingSeconds: Double?
    let detail: String?

    switch status.verdict {
    case .inactive:
      verdict = .inactive
      remainingSeconds = nil
      detail = status.trip.stopReason.map(String.init(describing:)) ?? inactiveDetail
    case .waitingForHotspot(let reason):
      verdict = .waitingForHotspot
      remainingSeconds = nil
      detail = reason.map(String.init(describing:))
    case .acquiring:
      verdict = .acquiring
      remainingSeconds = nil
      detail = nil
    case .protected(let remaining):
      verdict = .protected
      remainingSeconds = remaining.secondsValue
      detail = protectedDetail
    case .releasing(let reason):
      verdict = .releasing
      remainingSeconds = nil
      detail = reason.map(String.init(describing:))
    case .recoveryPending(let reason):
      verdict = .recoveryPending
      remainingSeconds = nil
      detail = reason
    case .unsafe(let reason):
      verdict = .unsafe
      remainingSeconds = nil
      detail = reason
    case .unknown(let reason):
      verdict = .unknown
      remainingSeconds = nil
      detail = reason
    }

    return SupervisorStatusWire(
      phase: WireTripPhase(rawValue: status.trip.phase.rawValue) ?? .ended,
      mode: mode,
      sessionID: status.trip.sessionID,
      verdict: verdict,
      closedLidAllowed: closedLidAllowed && verdict == .protected,
      remainingSeconds: remainingSeconds,
      batteryPercent: status.latestDevice?.batteryPercent,
      thermalLevel: status.latestDevice?.thermalLevel.rawValue,
      lidState: status.latestDevice?.lidState.rawValue,
      stopReason: makeWireStopReason(status.trip.stopReason),
      detail: detail,
      updatedAt: Date()
    )
  }

  private func makeStartupRecoveryStatus(detail: String) -> SupervisorStatusWire {
    SupervisorStatusWire(
      phase: .recoveryPending,
      mode: adaptiveConfiguration == nil ? .none : .adaptive,
      sessionID: nil,
      verdict: .recoveryPending,
      closedLidAllowed: false,
      remainingSeconds: nil,
      batteryPercent: nil,
      thermalLevel: nil,
      lidState: nil,
      stopReason: nil,
      detail: detail,
      updatedAt: Date()
    )
  }

  private func makeWireStopReason(
    _ reason: TripStopReason?
  ) -> WireSessionStopReason? {
    switch reason {
    case .userRequested:
      .userRequested
    case .hotspotHandoffTimedOut:
      .hotspotHandoffTimedOut
    case .hardDeadlineReached:
      .hardDeadlineReached
    case .safety:
      .safety
    case .leaseRejected:
      .leaseRejected
    case .leaseRecoveryPending:
      .leaseRecoveryPending
    case .superseded:
      .superseded
    case nil:
      nil
    }
  }

  private var adaptiveActivityDetail: String? {
    guard let lastAdaptiveActivitySource else {
      return nil
    }
    if let lastAdaptiveNamedSession {
      return
        "adaptive activity source=\(lastAdaptiveActivitySource), session=\(lastAdaptiveNamedSession)"
    }
    return "adaptive activity source=\(lastAdaptiveActivitySource)"
  }
}

extension Duration {
  fileprivate var secondsValue: Double {
    let parts = components
    return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
  }
}
