import Foundation
import RuntinueCore

public enum DeskModeError: Error, Equatable, Sendable {
  case sessionAlreadyRunning
  case invalidHardCap
  case lidMustBeOpen
  case unsafe(String)
  case assertionFailure(String)
}

public actor DeskModeController {
  private enum Mode: Equatable, Sendable {
    case idle
    case assertion
    case assertionRecovery
    case closedLease
  }

  private let directController: DirectSafetyLeaseController
  private let assertionBackend: any UserPowerAssertionBackend
  private let clock: any MonotonicTimeSource

  private var mode: Mode = .idle
  private var assertionToken: UserPowerAssertionToken?
  private var sessionID: UUID?
  private var hardDeadline: MonotonicInstant?
  private var latestDevice: DeviceSafetySnapshot?
  private var latestSafetyVerdict: DeviceSafetyVerdict?
  private var safetyTracker = DeviceSafetyTracker()
  private var terminalStatus: SupervisorStatus?
  private var pendingReleaseReason: TripStopReason?

  public init(
    directController: DirectSafetyLeaseController,
    assertionBackend: any UserPowerAssertionBackend,
    clock: any MonotonicTimeSource = SystemUptimeClock()
  ) {
    self.directController = directController
    self.assertionBackend = assertionBackend
    self.clock = clock
  }

  @discardableResult
  public func start(
    allowClosedLid: Bool,
    hardCap: Duration,
    device: DeviceSafetySnapshot,
    safetyPolicy: DeviceSafetyPolicy = DeviceSafetyPolicy()
  ) async throws -> SupervisorStatus {
    guard mode == .idle else {
      throw DeskModeError.sessionAlreadyRunning
    }
    guard hardCap > .zero, hardCap <= CommuteTripRequest.maximumHardCap else {
      throw DeskModeError.invalidHardCap
    }
    terminalStatus = nil
    pendingReleaseReason = nil

    if allowClosedLid {
      let status = try await directController.start(
        hardCap: hardCap,
        device: device,
        safetyPolicy: safetyPolicy
      )
      mode = .closedLease
      return status
    }

    guard device.lidState == .open else {
      throw DeskModeError.lidMustBeOpen
    }
    var tracker = DeviceSafetyTracker(policy: safetyPolicy)
    let verdict = tracker.evaluate(device, at: clock.now())
    guard case .safe = verdict else {
      throw DeskModeError.unsafe(String(describing: verdict))
    }
    do {
      assertionToken = try await assertionBackend.acquire(
        reason: "Runtinue desk mode"
      )
    } catch {
      throw DeskModeError.assertionFailure(String(describing: error))
    }
    mode = .assertion
    sessionID = UUID()
    hardDeadline = clock.now().adding(hardCap)
    latestDevice = device
    latestSafetyVerdict = verdict
    safetyTracker = tracker
    return makeAssertionStatus()
  }

  @discardableResult
  public func observe(device: DeviceSafetySnapshot) async -> SupervisorStatus {
    switch mode {
    case .closedLease:
      return settleClosedLease(
        await directController.observe(device: device)
      )
    case .assertion:
      latestDevice = device
      let verdict = safetyTracker.evaluate(device, at: clock.now())
      latestSafetyVerdict = verdict
      if device.lidState != .open {
        return await releaseAssertion(
          reason: .safety(.lidClosedWithoutPermission)
        )
      }
      if case .stop(let reason) = verdict {
        return await releaseAssertion(reason: .safety(reason))
      }
      if let hardDeadline, clock.now() >= hardDeadline {
        return await releaseAssertion(reason: .hardDeadlineReached)
      }
      return makeAssertionStatus()
    case .assertionRecovery:
      return await retryPendingRelease()
    case .idle:
      return terminalStatus ?? makeIdleStatus()
    }
  }

  @discardableResult
  public func stop() async -> SupervisorStatus {
    switch mode {
    case .closedLease:
      let status = await directController.stop()
      return settleClosedLease(status)
    case .assertion, .assertionRecovery:
      return await releaseAssertion(reason: .userRequested)
    case .idle:
      return terminalStatus ?? makeIdleStatus()
    }
  }

  public func status() async -> SupervisorStatus {
    switch mode {
    case .closedLease:
      return await directController.status()
    case .assertion:
      return makeAssertionStatus()
    case .assertionRecovery:
      return terminalStatus ?? makeRecoveryStatus("desk assertion release is pending")
    case .idle:
      return terminalStatus ?? makeIdleStatus()
    }
  }

  public func allowsClosedLid() -> Bool {
    mode == .closedLease
  }

  @discardableResult
  public func retryPendingRelease() async -> SupervisorStatus {
    guard mode == .assertionRecovery else {
      return await status()
    }
    return await releaseAssertion(reason: pendingReleaseReason ?? .userRequested)
  }

  @discardableResult
  public func reconcileRecovery() async -> SupervisorStatus {
    switch mode {
    case .closedLease:
      return settleClosedLease(await directController.reconcileRecovery())
    case .assertionRecovery:
      return await retryPendingRelease()
    case .idle, .assertion:
      return await status()
    }
  }

  private func releaseAssertion(reason: TripStopReason) async -> SupervisorStatus {
    guard let assertionToken else {
      let status = makeRecoveryStatus("desk assertion token is missing")
      mode = .assertionRecovery
      pendingReleaseReason = reason
      terminalStatus = status
      return status
    }
    do {
      try await assertionBackend.release(assertionToken)
      let status = makeEndedStatus(reason: reason)
      mode = .idle
      self.assertionToken = nil
      pendingReleaseReason = nil
      terminalStatus = status
      return status
    } catch {
      let status = makeRecoveryStatus(
        "desk assertion release failed: \(error)"
      )
      mode = .assertionRecovery
      pendingReleaseReason = reason
      terminalStatus = status
      return status
    }
  }

  private func makeAssertionStatus() -> SupervisorStatus {
    let verdict: SupervisorProtectionVerdict
    switch latestSafetyVerdict {
    case .safe:
      if let hardDeadline,
        let remaining = hardDeadline.durationSince(clock.now()),
        remaining > .zero
      {
        verdict = .protected(remaining: remaining)
      } else {
        verdict = .unknown("desk assertion deadline is unavailable")
      }
    case .uncertain(let reason):
      verdict = .unknown("device safety signal is uncertain: \(reason)")
    case .stop(let reason):
      verdict = .unsafe("device safety: \(reason)")
    case nil:
      verdict = .unknown("desk assertion safety state is incomplete")
    }
    return SupervisorStatus(
      trip: TripStatus(
        phase: .active,
        sessionID: sessionID,
        hotspotDeadline: nil,
        hardDeadline: hardDeadline,
        stopReason: nil,
        hotspotWaitingReason: nil
      ),
      verdict: verdict,
      lastHeartbeat: nil,
      latestDevice: latestDevice
    )
  }

  private func settleClosedLease(_ status: SupervisorStatus) -> SupervisorStatus {
    if status.trip.phase == .idle || status.trip.phase == .ended {
      mode = .idle
      terminalStatus = status
    }
    return status
  }

  private func makeIdleStatus() -> SupervisorStatus {
    SupervisorStatus(
      trip: TripStatus(
        phase: .idle,
        sessionID: nil,
        hotspotDeadline: nil,
        hardDeadline: nil,
        stopReason: nil,
        hotspotWaitingReason: nil
      ),
      verdict: .inactive,
      lastHeartbeat: nil,
      latestDevice: latestDevice
    )
  }

  private func makeEndedStatus(reason: TripStopReason) -> SupervisorStatus {
    let verdict: SupervisorProtectionVerdict
    if case .safety = reason {
      verdict = .unsafe(String(describing: reason))
    } else {
      verdict = .inactive
    }
    return SupervisorStatus(
      trip: TripStatus(
        phase: .ended,
        sessionID: sessionID,
        hotspotDeadline: nil,
        hardDeadline: hardDeadline,
        stopReason: reason,
        hotspotWaitingReason: nil
      ),
      verdict: verdict,
      lastHeartbeat: nil,
      latestDevice: latestDevice
    )
  }

  private func makeRecoveryStatus(_ detail: String) -> SupervisorStatus {
    SupervisorStatus(
      trip: TripStatus(
        phase: .recoveryPending,
        sessionID: sessionID,
        hotspotDeadline: nil,
        hardDeadline: hardDeadline,
        stopReason: .leaseRecoveryPending(detail),
        hotspotWaitingReason: nil
      ),
      verdict: .recoveryPending(detail),
      lastHeartbeat: nil,
      latestDevice: latestDevice
    )
  }
}
