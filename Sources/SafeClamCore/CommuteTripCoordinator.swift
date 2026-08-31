import Foundation

public protocol PrivilegedLeaseBackend: Sendable {
  func acquire(sessionID: UUID, hardCap: Duration) async -> LeaseAcquisitionOutcome
  func release(
    sessionID: UUID,
    lease: LeaseToken,
    reason: TripStopReason
  ) async -> LeaseReleaseOutcome
}

public actor CommuteTripCoordinator {
  private var engine: CommuteTripEngine
  private let leaseBackend: any PrivilegedLeaseBackend
  private let clock: any MonotonicTimeSource

  public init(
    leaseBackend: any PrivilegedLeaseBackend,
    clock: any MonotonicTimeSource = SystemUptimeClock()
  ) {
    self.engine = CommuteTripEngine()
    self.leaseBackend = leaseBackend
    self.clock = clock
  }

  @discardableResult
  public func arm(
    _ request: CommuteTripRequest,
    originNetwork: NetworkSnapshot,
    device: DeviceSafetySnapshot
  ) throws -> TripStatus {
    try engine.arm(
      request,
      originNetwork: originNetwork,
      device: device,
      at: clock.now()
    )
  }

  @discardableResult
  public func observeNetwork(_ network: NetworkSnapshot) async -> TripStatus {
    await execute(engine.observeNetwork(network, at: clock.now()))
    return engine.status
  }

  @discardableResult
  public func observeDevice(_ device: DeviceSafetySnapshot) async -> TripStatus {
    await execute(engine.observeDevice(device, at: clock.now()))
    return engine.status
  }

  @discardableResult
  public func observeDevice(
    _ device: DeviceSafetySnapshot,
    verdict: DeviceSafetyVerdict
  ) async -> TripStatus {
    await execute(
      engine.observeDevice(
        device,
        verdict: verdict,
        at: clock.now()
      )
    )
    return engine.status
  }

  @discardableResult
  public func tick() async -> TripStatus {
    await execute(engine.tick(at: clock.now()))
    return engine.status
  }

  @discardableResult
  public func stop() async -> TripStatus {
    await execute(engine.stop())
    return engine.status
  }

  public func status() -> TripStatus {
    engine.status
  }

  @discardableResult
  public func confirmRecovery() -> TripStatus {
    engine.confirmRecovery()
  }

  private func execute(_ initialCommands: [TripCommand]) async {
    var commands = initialCommands
    while !commands.isEmpty {
      let command = commands.removeFirst()
      switch command {
      case .acquire(let sessionID, let hardCap):
        let outcome = await leaseBackend.acquire(sessionID: sessionID, hardCap: hardCap)
        commands.append(
          contentsOf: engine.completeAcquisition(
            sessionID: sessionID,
            outcome: outcome,
            at: clock.now()
          )
        )
      case .release(let sessionID, let lease, let reason):
        let outcome = await leaseBackend.release(
          sessionID: sessionID,
          lease: lease,
          reason: reason
        )
        commands.append(
          contentsOf: engine.completeRelease(
            sessionID: sessionID,
            lease: lease,
            outcome: outcome
          )
        )
      }
    }
  }
}
