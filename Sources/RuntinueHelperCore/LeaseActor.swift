import Foundation
import RuntinueCore

public actor LeaseActor {
  private struct RuntimeLease: Sendable {
    var persisted: PersistedLease
    var ttlDeadline: MonotonicInstant
    let hardDeadline: MonotonicInstant
    var retryAttempt: Int
    var nextRecoveryAttempt: MonotonicInstant?
  }

  private struct OrphanRecovery: Sendable {
    let detail: String
    var retryAttempt: Int
    var nextRecoveryAttempt: MonotonicInstant
  }

  private let powerBackend: any SleepPowerBackend
  private let store: any LeaseStateStore
  private let monotonicClock: any MonotonicTimeSource
  private let wallClock: any WallTimeSource

  private var started = false
  private var operationInProgress = false
  private var runtimeLease: RuntimeLease?
  private var orphanRecovery: OrphanRecovery?

  public init(
    powerBackend: any SleepPowerBackend,
    store: any LeaseStateStore,
    monotonicClock: any MonotonicTimeSource = SystemContinuousClock(),
    wallClock: any WallTimeSource = SystemWallClock()
  ) {
    self.powerBackend = powerBackend
    self.store = store
    self.monotonicClock = monotonicClock
    self.wallClock = wallClock
  }

  public func start() async -> HelperLeaseStatus {
    if started {
      return await currentStatus()
    }
    guard !operationInProgress else {
      return unknownStatus("helper startup is already in progress")
    }

    operationInProgress = true
    defer { operationInProgress = false }

    let now = monotonicClock.now()
    switch await store.load() {
    case .absent:
      started = true
      return await currentStatus()

    case .valid(var persisted):
      guard persisted.rollbackBaseline == .normal else {
        orphanRecovery = OrphanRecovery(
          detail: "persisted rollback baseline is not normal",
          retryAttempt: 0,
          nextRecoveryAttempt: now
        )
        started = true
        return await recoverCorruptState()
      }
      persisted.phase = .recoveryPending
      persisted.recoveryDetail =
        persisted.version == PersistedLease.currentVersion
        ? "startup recovery"
        : "unknown persisted lease version \(persisted.version)"
      runtimeLease = RuntimeLease(
        persisted: persisted,
        ttlDeadline: now,
        hardDeadline: now,
        retryAttempt: 0,
        nextRecoveryAttempt: now
      )
      started = true
      return await recoverPersistedLease(reason: .startupRecovery)

    case .corrupt(let detail):
      orphanRecovery = OrphanRecovery(
        detail: detail,
        retryAttempt: 0,
        nextRecoveryAttempt: now
      )
      started = true
      return await recoverCorruptState()
    }
  }

  public func acquire(_ request: LeaseAcquireRequest) async -> HelperLeaseMutationResult {
    guard started else {
      return .rejected(.stateUnavailable("helper startup recovery has not completed"))
    }
    guard !operationInProgress else {
      return .rejected(.stateUnavailable("another helper operation is in progress"))
    }
    guard runtimeLease == nil, orphanRecovery == nil else {
      return .rejected(.leaseAlreadyExists)
    }
    guard request.ttl > .zero, request.ttl <= LeaseAcquireRequest.maximumTTL else {
      return .rejected(.invalidTTL)
    }
    guard request.hardCap > .zero,
      request.hardCap <= LeaseAcquireRequest.maximumHardCap
    else {
      return .rejected(.invalidHardCap)
    }
    let reason = request.reason.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !reason.isEmpty, reason.utf8.count <= 256 else {
      return .rejected(.invalidReason)
    }

    operationInProgress = true
    defer { operationInProgress = false }

    switch await powerBackend.readSleepOverride() {
    case .disabled:
      return .rejected(.sleepOverrideAlreadyOwned)
    case .unavailable(let detail):
      return .rejected(.stateUnavailable(detail))
    case .normal:
      break
    }

    let monotonicNow = monotonicClock.now()
    let wallNow = wallClock.now()
    let effectiveTTL = min(request.ttl, request.hardCap)
    var persisted = PersistedLease(
      leaseID: request.leaseID,
      ownerUID: request.ownerUID,
      createdAt: wallNow,
      hardDeadline: wallNow.addingTimeInterval(request.hardCap.timeInterval),
      rollbackBaseline: .normal,
      reason: reason,
      phase: .acquiring,
      lastRenewedAt: wallNow,
      ttlExpiresAt: wallNow.addingTimeInterval(effectiveTTL.timeInterval)
    )

    do {
      try await store.save(persisted)
    } catch {
      return .rejected(.persistenceFailure(String(describing: error)))
    }

    runtimeLease = RuntimeLease(
      persisted: persisted,
      ttlDeadline: monotonicNow.adding(effectiveTTL),
      hardDeadline: monotonicNow.adding(request.hardCap),
      retryAttempt: 0,
      nextRecoveryAttempt: nil
    )

    switch await powerBackend.readSleepOverride() {
    case .normal:
      break
    case .disabled:
      return await abandonUncommittedAcquisition(
        rejection: .sleepOverrideAlreadyOwned,
        detail: "SleepDisabled changed before Runtinue could enable it"
      )
    case .unavailable(let detail):
      return await abandonUncommittedAcquisition(
        rejection: .stateUnavailable(detail),
        detail: "SleepDisabled became unavailable before enable: \(detail)"
      )
    }

    do {
      try await powerBackend.writeAndVerify(.disabled)
    } catch {
      return await rollbackFailedAcquisition(
        primaryFailure: "failed to enable sleep override: \(error)"
      )
    }
    if let expired = await releaseExpiredLeaseIfNeeded() { return expired }

    persisted.phase = .active
    runtimeLease?.persisted = persisted
    do {
      try await store.save(persisted)
    } catch {
      return await rollbackFailedAcquisition(
        primaryFailure: "failed to persist active phase: \(error)"
      )
    }
    if let expired = await releaseExpiredLeaseIfNeeded() { return expired }

    return .success(await currentStatus())
  }

  public func renew(
    leaseID: UUID,
    ownerUID: UInt32,
    ttl: Duration = LeaseAcquireRequest.defaultTTL
  ) async -> HelperLeaseMutationResult {
    guard started else {
      return .rejected(.stateUnavailable("helper has not started"))
    }
    guard !operationInProgress else {
      return .rejected(.stateUnavailable("another helper operation is in progress"))
    }
    guard ttl > .zero, ttl <= LeaseAcquireRequest.maximumTTL else {
      return .rejected(.invalidTTL)
    }
    guard var runtime = runtimeLease,
      runtime.persisted.leaseID == leaseID,
      runtime.persisted.ownerUID == ownerUID,
      runtime.persisted.phase == .active
    else {
      return .rejected(.leaseMismatch)
    }

    operationInProgress = true
    defer { operationInProgress = false }

    if let expired = await releaseExpiredLeaseIfNeeded() { return expired }

    do {
      try await powerBackend.writeAndVerify(.disabled)
    } catch {
      runtime.persisted.phase = .recoveryPending
      runtime.persisted.recoveryDetail = "renew verification failed: \(error)"
      runtimeLease = runtime
      await persistBestEffort(runtime.persisted)
      return await recoverPersistedLease(reason: .safetyTrip).asMutationResult
    }

    // A power write can span sleep. Check the old TTL before extending it.
    if let expired = await releaseExpiredLeaseIfNeeded() { return expired }
    let now = monotonicClock.now()
    let proposedTTLDeadline = now.adding(ttl)
    runtime.ttlDeadline = min(proposedTTLDeadline, runtime.hardDeadline)
    let wallNow = wallClock.now()
    runtime.persisted.lastRenewedAt = wallNow
    let remainingUntilHardDeadline = runtime.ttlDeadline.durationSince(now) ?? .zero
    runtime.persisted.ttlExpiresAt = wallNow.addingTimeInterval(
      remainingUntilHardDeadline.timeInterval
    )
    runtimeLease = runtime

    do {
      try await store.save(runtime.persisted)
    } catch {
      runtime.persisted.phase = .recoveryPending
      runtime.persisted.recoveryDetail = "renew persistence failed: \(error)"
      runtimeLease = runtime
      await persistBestEffort(runtime.persisted)
      return await recoverPersistedLease(reason: .safetyTrip).asMutationResult
    }
    if let expired = await releaseExpiredLeaseIfNeeded() { return expired }

    return .success(await currentStatus())
  }

  public func release(
    leaseID: UUID,
    ownerUID: UInt32,
    reason: HelperReleaseReason
  ) async -> HelperLeaseMutationResult {
    guard started else {
      return .rejected(.stateUnavailable("helper has not started"))
    }
    guard !operationInProgress else {
      return .rejected(.stateUnavailable("another helper operation is in progress"))
    }
    guard let runtime = runtimeLease,
      runtime.persisted.leaseID == leaseID,
      runtime.persisted.ownerUID == ownerUID
    else {
      return .rejected(.leaseMismatch)
    }

    operationInProgress = true
    defer { operationInProgress = false }
    return await releaseCurrent(reason: reason)
  }

  public func tick() async -> HelperLeaseStatus {
    guard started, !operationInProgress else {
      return await currentStatus()
    }

    operationInProgress = true
    defer { operationInProgress = false }

    let now = monotonicClock.now()
    if let orphanRecovery, now >= orphanRecovery.nextRecoveryAttempt {
      return await recoverCorruptState()
    }
    guard let runtime = runtimeLease else {
      return await currentStatus()
    }

    if runtime.persisted.phase == .recoveryPending,
      let nextAttempt = runtime.nextRecoveryAttempt,
      now >= nextAttempt
    {
      return await recoverPersistedLease(reason: .safetyTrip)
    }
    if runtime.persisted.phase == .active {
      if now >= runtime.hardDeadline {
        return await releaseCurrent(reason: .hardDeadlineReached).status
      }
      if now >= runtime.ttlDeadline {
        return await releaseCurrent(reason: .supervisorHeartbeatExpired).status
      }
      switch await powerBackend.readSleepOverride() {
      case .disabled:
        break
      case .normal:
        do {
          // Reassert once without extending either deadline.
          try await powerBackend.writeAndVerify(.disabled)
        } catch {
          return await recoverPersistedLease(reason: .safetyTrip)
        }
      case .unavailable:
        return await recoverPersistedLease(reason: .safetyTrip)
      }
      // A slow write or system suspend must not outlive the original deadline.
      let verifiedAt = monotonicClock.now()
      if verifiedAt >= runtime.hardDeadline {
        return await releaseCurrent(reason: .hardDeadlineReached).status
      }
      if verifiedAt >= runtime.ttlDeadline {
        return await releaseCurrent(reason: .supervisorHeartbeatExpired).status
      }
    }
    return await currentStatus()
  }

  public func status() async -> HelperLeaseStatus {
    guard started else {
      return unknownStatus("helper has not started")
    }
    return await currentStatus()
  }

  public func shutdown() async -> HelperLeaseStatus {
    guard started else {
      return unknownStatus("helper has not started")
    }
    guard !operationInProgress else {
      return await currentStatus()
    }
    guard runtimeLease != nil else {
      return await currentStatus()
    }

    operationInProgress = true
    defer { operationInProgress = false }
    return await releaseCurrent(reason: .shutdown).status
  }

  public func recover() async -> HelperLeaseStatus {
    guard started else {
      return unknownStatus("helper has not started")
    }
    guard !operationInProgress else {
      return await currentStatus()
    }

    operationInProgress = true
    defer { operationInProgress = false }
    if orphanRecovery != nil {
      return await recoverCorruptState()
    }
    if runtimeLease?.persisted.phase == .recoveryPending {
      return await recoverPersistedLease(reason: .safetyTrip)
    }
    return await currentStatus()
  }

  private func releaseExpiredLeaseIfNeeded() async -> HelperLeaseMutationResult? {
    guard let runtime = runtimeLease else { return nil }
    let now = monotonicClock.now()
    if now >= runtime.hardDeadline {
      return await releaseCurrent(reason: .hardDeadlineReached)
    }
    if now >= runtime.ttlDeadline {
      return await releaseCurrent(reason: .supervisorHeartbeatExpired)
    }
    return nil
  }

  private func releaseCurrent(reason: HelperReleaseReason) async -> HelperLeaseMutationResult {
    guard var runtime = runtimeLease else {
      return .rejected(.leaseMismatch)
    }

    runtime.persisted.phase = .releasing
    runtime.persisted.recoveryDetail = reason.rawValue
    runtimeLease = runtime
    do {
      try await store.save(runtime.persisted)
    } catch {
      await markRecoveryPending(
        "failed to persist releasing phase: \(error)"
      )
      return .recoveryPending(await currentStatus())
    }

    do {
      try await powerBackend.writeAndVerify(runtime.persisted.rollbackBaseline)
    } catch {
      await markRecoveryPending("release failed: \(error)")
      return .recoveryPending(await currentStatus())
    }

    do {
      try await store.remove()
      runtimeLease = nil
      return .success(await currentStatus())
    } catch {
      await markRecoveryPending("verified normal sleep but failed to remove lease: \(error)")
      return .recoveryPending(await currentStatus())
    }
  }

  private func rollbackFailedAcquisition(
    primaryFailure: String
  ) async -> HelperLeaseMutationResult {
    do {
      try await powerBackend.writeAndVerify(.normal)
    } catch {
      await markRecoveryPending("\(primaryFailure); rollback failed: \(error)")
      return .recoveryPending(await currentStatus())
    }

    do {
      try await store.remove()
      runtimeLease = nil
      return .rejected(.powerFailure(primaryFailure))
    } catch {
      await markRecoveryPending(
        "\(primaryFailure); normal sleep verified but lease removal failed: \(error)"
      )
      return .recoveryPending(await currentStatus())
    }
  }

  private func abandonUncommittedAcquisition(
    rejection: HelperLeaseRejection,
    detail: String
  ) async -> HelperLeaseMutationResult {
    do {
      try await store.remove()
      runtimeLease = nil
      return .rejected(rejection)
    } catch {
      await markRecoveryPending(
        "\(detail); failed to remove uncommitted lease: \(error)"
      )
      return .recoveryPending(await currentStatus())
    }
  }

  private func recoverPersistedLease(
    reason: HelperReleaseReason
  ) async -> HelperLeaseStatus {
    guard var runtime = runtimeLease else {
      return await currentStatus()
    }

    runtime.persisted.phase = .recoveryPending
    runtime.persisted.recoveryDetail = reason.rawValue
    runtimeLease = runtime
    await persistBestEffort(runtime.persisted)

    do {
      try await powerBackend.writeAndVerify(runtime.persisted.rollbackBaseline)
      try await store.remove()
      runtimeLease = nil
      return await currentStatus()
    } catch {
      await markRecoveryPending("recovery failed: \(error)")
      return await currentStatus()
    }
  }

  private func recoverCorruptState() async -> HelperLeaseStatus {
    guard var recovery = orphanRecovery else {
      return await currentStatus()
    }

    do {
      try await powerBackend.writeAndVerify(.normal)
      try await store.quarantineCorruptState()
      orphanRecovery = nil
      return await currentStatus()
    } catch {
      recovery.retryAttempt += 1
      recovery.nextRecoveryAttempt = monotonicClock.now().adding(
        retryDelay(attempt: recovery.retryAttempt)
      )
      orphanRecovery = recovery
      return await currentStatus()
    }
  }

  private func markRecoveryPending(_ detail: String) async {
    guard var runtime = runtimeLease else {
      return
    }
    runtime.persisted.phase = .recoveryPending
    runtime.persisted.recoveryDetail = detail
    runtime.retryAttempt += 1
    runtime.nextRecoveryAttempt = monotonicClock.now().adding(
      retryDelay(attempt: runtime.retryAttempt)
    )
    runtimeLease = runtime
    await persistBestEffort(runtime.persisted)
  }

  private func persistBestEffort(_ persisted: PersistedLease) async {
    try? await store.save(persisted)
  }

  private func currentStatus() async -> HelperLeaseStatus {
    let observed = await powerBackend.readSleepOverride()
    if let orphanRecovery {
      return HelperLeaseStatus(
        phase: .recoveryPending,
        leaseID: nil,
        ownerUID: nil,
        observedSleepOverride: observed,
        ttlDeadline: nil,
        hardDeadline: nil,
        detail: "corrupt state recovery: \(orphanRecovery.detail)"
      )
    }
    guard let runtime = runtimeLease else {
      let phase: HelperLeasePhase
      switch observed {
      case .normal:
        phase = .idle
      case .disabled:
        phase = .externalOwner
      case .unavailable:
        phase = .unknown
      }
      return HelperLeaseStatus(
        phase: phase,
        leaseID: nil,
        ownerUID: nil,
        observedSleepOverride: observed,
        ttlDeadline: nil,
        hardDeadline: nil,
        detail: nil
      )
    }

    let phase: HelperLeasePhase
    switch runtime.persisted.phase {
    case .acquiring:
      phase = .acquiring
    case .active:
      let now = monotonicClock.now()
      phase =
        observed == .disabled && now < runtime.ttlDeadline && now < runtime.hardDeadline
        ? .active
        : .unknown
    case .releasing:
      phase = .releasing
    case .recoveryPending:
      phase = .recoveryPending
    }
    return HelperLeaseStatus(
      phase: phase,
      leaseID: runtime.persisted.leaseID,
      ownerUID: runtime.persisted.ownerUID,
      observedSleepOverride: observed,
      ttlDeadline: runtime.ttlDeadline,
      hardDeadline: runtime.hardDeadline,
      detail: runtime.persisted.recoveryDetail
    )
  }

  private func unknownStatus(_ detail: String) -> HelperLeaseStatus {
    HelperLeaseStatus(
      phase: .unknown,
      leaseID: nil,
      ownerUID: nil,
      observedSleepOverride: .unavailable(detail),
      ttlDeadline: nil,
      hardDeadline: nil,
      detail: detail
    )
  }

  private func retryDelay(attempt: Int) -> Duration {
    switch attempt {
    case 0:
      .zero
    case 1:
      .seconds(1)
    case 2:
      .seconds(2)
    default:
      .seconds(5)
    }
  }
}

extension Duration {
  fileprivate var timeInterval: TimeInterval {
    let parts = components
    return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
  }
}

extension HelperLeaseMutationResult {
  fileprivate var status: HelperLeaseStatus {
    switch self {
    case .success(let status), .recoveryPending(let status):
      status
    case .rejected(let reason):
      HelperLeaseStatus(
        phase: .unknown,
        leaseID: nil,
        ownerUID: nil,
        observedSleepOverride: .unavailable("release rejected: \(reason)"),
        ttlDeadline: nil,
        hardDeadline: nil,
        detail: "release rejected: \(reason)"
      )
    }
  }
}

extension HelperLeaseStatus {
  fileprivate var asMutationResult: HelperLeaseMutationResult {
    phase == .recoveryPending ? .recoveryPending(self) : .success(self)
  }
}
