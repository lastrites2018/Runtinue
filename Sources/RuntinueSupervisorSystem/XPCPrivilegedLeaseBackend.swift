import Darwin
import Foundation
import RuntinueCore
import RuntinueIPC
import RuntinueSupervisorCore
import RuntinueUserSupport

public actor XPCPrivilegedLeaseBackend: SupervisorLeaseBackend {
  private let machServiceName: String
  private let requestTimeout: TimeInterval
  private let ownerUID: UInt32
  private let eventRecorder: SupervisorEventRecorder?
  private let clock: any MonotonicTimeSource

  public init(
    machServiceName: String = RuntinueIPCContract.helperMachServiceName,
    requestTimeout: TimeInterval = 10,
    ownerUID: UInt32 = getuid(),
    eventRecorder: SupervisorEventRecorder? = nil,
    clock: any MonotonicTimeSource = SystemContinuousClock()
  ) {
    self.machServiceName = machServiceName
    self.requestTimeout = requestTimeout
    self.ownerUID = ownerUID
    self.eventRecorder = eventRecorder
    self.clock = clock
  }

  public func acquire(
    sessionID: UUID,
    hardCap: Duration
  ) async -> LeaseAcquisitionOutcome {
    let attemptID = UUID()
    let requestedAt = Date()
    let request = AcquireLeaseWireRequest(
      leaseID: sessionID,
      ttlSeconds: 90,
      hardCapSeconds: hardCap.secondsValue,
      reason: "commute"
    )
    guard let data = try? JSONEncoder().encode(request),
      let response = await send({ proxy, reply in
        proxy.acquire(data, withReply: reply)
      }),
      response.protocolVersion == RuntinueIPCContract.protocolVersion
    else {
      await eventRecorder?.record(
        .leaseAcquireRequested, attemptID: attemptID, sessionID: sessionID, at: requestedAt
      )
      await eventRecorder?.record(.recoveryPending, attemptID: attemptID, sessionID: sessionID)
      return .recoveryPending("privileged helper is unavailable")
    }

    await eventRecorder?.record(
      .leaseAcquireRequested, attemptID: attemptID, sessionID: sessionID, at: requestedAt
    )
    switch response.outcome {
    case .success:
      guard Self.confirmsActiveLease(response, leaseID: sessionID, ownerUID: ownerUID, at: clock.now()) else {
        await eventRecorder?.record(.recoveryPending, attemptID: attemptID, sessionID: sessionID)
        return .recoveryPending("helper acquisition did not confirm the owned active lease")
      }
      await eventRecorder?.record(.leaseAcquireAccepted, attemptID: attemptID, sessionID: sessionID)
      return .acquired(LeaseToken(id: sessionID))
    case .recoveryPending:
      await eventRecorder?.record(.recoveryPending, attemptID: attemptID, sessionID: sessionID)
      return .recoveryPending(response.rejection ?? "helper recovery is pending")
    case .rejected, .invalidRequest:
      await eventRecorder?.record(.leaseAcquireRejected, attemptID: attemptID, sessionID: sessionID)
      return .rejected(response.rejection ?? "helper rejected acquisition")
    }
  }

  public func release(
    sessionID: UUID,
    lease: LeaseToken,
    reason: TripStopReason
  ) async -> LeaseReleaseOutcome {
    let attemptID = UUID()
    let requestedAt = Date()
    let wireReason: WireReleaseReason
    switch reason {
    case .safety:
      wireReason = .safetyTrip
    case .userRequested:
      wireReason = .userRequested
    default:
      wireReason = .supervisorShutdown
    }
    let request = ReleaseLeaseWireRequest(
      leaseID: lease.id,
      reason: wireReason
    )
    guard let data = try? JSONEncoder().encode(request),
      let response = await send({ proxy, reply in
        proxy.release(data, withReply: reply)
      }),
      response.protocolVersion == RuntinueIPCContract.protocolVersion
    else {
      await eventRecorder?.record(
        .releaseRequested, attemptID: attemptID, sessionID: sessionID, at: requestedAt
      )
      await eventRecorder?.record(.recoveryPending, attemptID: attemptID, sessionID: sessionID)
      return .recoveryPending("privileged helper release is unavailable")
    }

    // Restore power first. A failed or slow observation write must not defer the release request.
    await eventRecorder?.record(
      .releaseRequested, attemptID: attemptID, sessionID: sessionID, at: requestedAt
    )
    switch response.outcome {
    case .success:
      guard Self.confirmsNormalSleep(response) else {
        await eventRecorder?.record(.recoveryPending, attemptID: attemptID, sessionID: sessionID)
        return .recoveryPending("helper release did not confirm idle normal sleep")
      }
      await eventRecorder?.record(.sleepRestored, attemptID: attemptID, sessionID: sessionID)
      return .released
    case .recoveryPending, .rejected, .invalidRequest:
      await eventRecorder?.record(.recoveryPending, attemptID: attemptID, sessionID: sessionID)
      return .recoveryPending(response.rejection ?? "helper could not verify normal sleep")
    }
  }

  static func confirmsNormalSleep(_ response: HelperMutationWireResponse) -> Bool {
    response.protocolVersion == RuntinueIPCContract.protocolVersion
      && response.outcome == .success
      && response.status?.phase == .idle
      && response.status?.sleepOverride == .normal
      && response.status?.leaseID == nil
      && response.status?.ownerUID == nil
  }

  static func confirmsActiveLease(
    _ response: HelperMutationWireResponse,
    leaseID: UUID,
    ownerUID: UInt32,
    at now: MonotonicInstant
  ) -> Bool {
    guard response.protocolVersion == RuntinueIPCContract.protocolVersion,
      response.outcome == .success, response.rejection == nil,
      let status = response.status,
      status.phase == .active, status.sleepOverride == .disabled,
      status.leaseID == leaseID, status.ownerUID == ownerUID,
      let ttl = status.ttlDeadlineContinuousNanoseconds,
      let hard = status.hardDeadlineContinuousNanoseconds
    else { return false }
    return now.continuousNanoseconds < ttl && ttl <= hard
  }

  public func renew(
    leaseID: UUID,
    ttl: Duration
  ) async -> SupervisorHeartbeatResult {
    let request = RenewLeaseWireRequest(
      leaseID: leaseID,
      ttlSeconds: ttl.secondsValue
    )
    guard let data = try? JSONEncoder().encode(request),
      let response = await send({ proxy, reply in
        proxy.renew(data, withReply: reply)
      }),
      response.protocolVersion == RuntinueIPCContract.protocolVersion
    else {
      await eventRecorder?.record(.heartbeatFailed, sessionID: leaseID)
      return .unavailable("privileged helper heartbeat timed out")
    }

    switch response.outcome {
    case .success:
      guard Self.confirmsActiveLease(response, leaseID: leaseID, ownerUID: ownerUID, at: clock.now()),
        let status = response.status
      else {
        await eventRecorder?.record(.heartbeatFailed, sessionID: leaseID)
        return .rejected("helper renewal did not confirm the owned active lease")
      }
      return .renewed(makeObservation(status))
    case .recoveryPending, .rejected, .invalidRequest:
      await eventRecorder?.record(.heartbeatFailed, sessionID: leaseID)
      return .rejected(response.rejection ?? "helper rejected renewal")
    }
  }

  public func liveStatus() async -> SupervisorHelperQuery {
    guard
      let response = await send({ proxy, reply in
        proxy.status(withReply: reply)
      }),
      response.protocolVersion == RuntinueIPCContract.protocolVersion,
      let status = response.status
    else {
      return .unavailable("privileged helper status is unavailable")
    }
    return .available(makeObservation(status))
  }

  public func releaseExistingOwnedLease() async -> LeaseReleaseOutcome {
    switch await liveStatus() {
    case .unavailable(let detail):
      return .recoveryPending(detail)
    case .available(let observation):
      if observation.phase == .recoveryPending {
        return .recoveryPending(observation.detail ?? "helper recovery is pending")
      }
      guard let leaseID = observation.leaseID,
        observation.ownerUID == ownerUID
      else {
        if observation.phase == .idle, observation.sleepOverride == .normal {
          await eventRecorder?.record(.normalSleepObserved)
        }
        return .released
      }
      return await release(
        sessionID: leaseID,
        lease: LeaseToken(id: leaseID),
        reason: .superseded
      )
    }
  }

  public func recoverHelper() async -> SupervisorHelperQuery {
    guard
      let response = await send({ proxy, reply in
        proxy.recover(withReply: reply)
      }),
      response.protocolVersion == RuntinueIPCContract.protocolVersion,
      let status = response.status
    else {
      return .unavailable("privileged helper recovery is unavailable")
    }
    return .available(makeObservation(status))
  }

  private func send(
    _ operation:
      @escaping (
        PrivilegedLeaseXPCProtocol,
        @escaping (Data) -> Void
      ) -> Void
  ) async -> HelperMutationWireResponse? {
    let responseData: Data? = await withCheckedContinuation { continuation in
      let connection = NSXPCConnection(
        machServiceName: machServiceName,
        options: .privileged
      )
      connection.remoteObjectInterface = NSXPCInterface(
        with: PrivilegedLeaseXPCProtocol.self
      )
      let gate = XPCResponseGate(
        connection: connection,
        continuation: continuation
      )
      connection.invalidationHandler = {
        gate.resolve(nil)
      }
      connection.interruptionHandler = {
        gate.resolve(nil)
      }
      connection.resume()

      guard
        let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
          gate.resolve(nil)
        }) as? PrivilegedLeaseXPCProtocol
      else {
        gate.resolve(nil)
        return
      }

      operation(proxy) { data in
        gate.resolve(data)
      }
      gate.scheduleTimeout(after: requestTimeout)
    }

    guard let responseData, responseData.count <= RuntinueIPCContract.maximumRequestBytes else {
      return nil
    }
    return try? JSONDecoder().decode(
      HelperMutationWireResponse.self,
      from: responseData
    )
  }

  private func makeObservation(
    _ status: HelperStatusWire
  ) -> SupervisorHelperObservation {
    SupervisorHelperObservation(
      phase: SupervisorHelperPhase(rawValue: status.phase.rawValue) ?? .unknown,
      leaseID: status.leaseID,
      ownerUID: status.ownerUID,
      sleepOverride: SupervisorSleepOverride(rawValue: status.sleepOverride.rawValue)
        ?? .unavailable,
      ttlDeadline: status.ttlDeadlineContinuousNanoseconds.map {
        MonotonicInstant(continuousNanoseconds: $0)
      },
      hardDeadline: status.hardDeadlineContinuousNanoseconds.map {
        MonotonicInstant(continuousNanoseconds: $0)
      },
      detail: status.detail
    )
  }
}

private final class XPCResponseGate: @unchecked Sendable {
  private let lock = NSLock()
  private let connection: NSXPCConnection
  private var continuation: CheckedContinuation<Data?, Never>?

  init(
    connection: NSXPCConnection,
    continuation: CheckedContinuation<Data?, Never>
  ) {
    self.connection = connection
    self.continuation = continuation
  }

  func resolve(_ data: Data?) {
    lock.lock()
    guard let continuation else {
      lock.unlock()
      return
    }
    self.continuation = nil
    lock.unlock()
    connection.invalidate()
    continuation.resume(returning: data)
  }

  func scheduleTimeout(after timeout: TimeInterval) {
    DispatchQueue.global(qos: .userInitiated).asyncAfter(
      deadline: .now() + timeout
    ) { [weak self] in
      self?.resolve(nil)
    }
  }
}

extension Duration {
  fileprivate var secondsValue: Double {
    let parts = components
    return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
  }
}
