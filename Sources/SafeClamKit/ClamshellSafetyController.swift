import Foundation
import SafeClamCore
import SafeClamIPC

public enum SafetyProfile: String, Equatable, Sendable {
  case bagSafe
}

public struct SessionRequest: Sendable {
  public enum Mode: Sendable {
    case trip(
      expectedHotspotSSID: String,
      handoffTimeout: Duration = .seconds(15 * 60)
    )
    case usbTetheredTrip(
      handoffTimeout: Duration = .seconds(15 * 60)
    )
    case adaptive(idleGrace: Duration)
    case desk(allowClosedLid: Bool = false)
  }

  public let mode: Mode
  public let hardCap: Duration
  public let profile: SafetyProfile

  public init(
    mode: Mode,
    hardCap: Duration,
    profile: SafetyProfile = .bagSafe
  ) {
    self.mode = mode
    self.hardCap = hardCap
    self.profile = profile
  }
}

public struct SessionHandle: Sendable, Hashable {
  public let id: UUID

  public init(id: UUID) {
    self.id = id
  }
}

public enum ReleaseReason: Equatable, Sendable {
  case userRequested
  case hotspotHandoffTimedOut
  case hardDeadlineReached
  case safety(detail: String)
  case leaseRejected(detail: String)
  case leaseRecoveryPending(detail: String)
  case superseded
  case unknown(detail: String?)
}

public enum ProtectionVerdict: Equatable, Sendable {
  case inactive
  case acquiring
  case protected(remaining: Duration, closedLidAllowed: Bool)
  case releasing(reason: ReleaseReason)
  case recoveryPending(reason: String)
  case unsafe(reason: String)
  case unknown(reason: String)
}

public enum ClamshellSafetyControllerError: Error, Equatable, Sendable {
  case invalidHardCap
  case missingSessionIdentifier
  case handleMismatch
}

public actor ClamshellSafetyController {
  private enum HandleMode: Equatable, Sendable {
    case trip
    case adaptive
    case desk
  }

  private let client: any SupervisorControlClient
  private var knownHandles: [UUID: HandleMode] = [:]

  public init(
    client: any SupervisorControlClient = SupervisorXPCClient()
  ) {
    self.client = client
  }

  public func start(_ request: SessionRequest) async throws -> SessionHandle {
    guard request.hardCap > .zero,
      request.hardCap <= CommuteTripRequest.maximumHardCap
    else {
      throw ClamshellSafetyControllerError.invalidHardCap
    }

    let status: SupervisorStatusWire
    switch request.mode {
    case .trip(let expectedHotspotSSID, let handoffTimeout):
      status = try await client.startTrip(
        StartTripWireRequest(
          expectedHotspotSSID: expectedHotspotSSID,
          hotspotHandoffTimeoutSeconds: handoffTimeout.secondsValue,
          hardCapSeconds: request.hardCap.secondsValue,
          safetyProfile: wireProfile(request.profile)
        )
      )
    case .usbTetheredTrip(let handoffTimeout):
      status = try await client.startTrip(
        StartTripWireRequest(
          networkTargetKind: .usbTethering,
          hotspotHandoffTimeoutSeconds: handoffTimeout.secondsValue,
          hardCapSeconds: request.hardCap.secondsValue,
          safetyProfile: wireProfile(request.profile)
        )
      )
    case .adaptive(let idleGrace):
      status = try await client.enableAdaptive(
        idleGraceSeconds: idleGrace.secondsValue,
        hardCapSeconds: request.hardCap.secondsValue,
        safetyProfile: wireProfile(request.profile)
      )
    case .desk(let allowClosedLid):
      status = try await client.enableDesk(
        allowClosedLid: allowClosedLid,
        hardCapSeconds: request.hardCap.secondsValue,
        safetyProfile: wireProfile(request.profile)
      )
    }

    let handleMode: HandleMode
    let handleID: UUID
    switch request.mode {
    case .trip, .usbTetheredTrip:
      guard let sessionID = status.sessionID else {
        throw ClamshellSafetyControllerError.missingSessionIdentifier
      }
      handleMode = .trip
      handleID = sessionID
    case .adaptive:
      handleMode = .adaptive
      handleID = status.sessionID ?? UUID()
    case .desk:
      guard let sessionID = status.sessionID else {
        throw ClamshellSafetyControllerError.missingSessionIdentifier
      }
      handleMode = .desk
      handleID = sessionID
    }
    let handle = SessionHandle(id: handleID)
    knownHandles[handle.id] = handleMode
    return handle
  }

  public func status() async -> ProtectionVerdict {
    do {
      return map(try await client.status())
    } catch {
      return .unknown(reason: "Supervisor 상태를 확인할 수 없음: \(error)")
    }
  }

  public func stop(_ handle: SessionHandle) async throws {
    guard let handleMode = knownHandles[handle.id] else {
      throw ClamshellSafetyControllerError.handleMismatch
    }
    let status = try await client.status()
    switch status.mode {
    case .adaptive:
      guard handleMode == .adaptive else {
        throw ClamshellSafetyControllerError.handleMismatch
      }
      _ = try await client.disableAdaptive()
    case .desk:
      guard handleMode == .desk else {
        throw ClamshellSafetyControllerError.handleMismatch
      }
      _ = try await client.disableDesk()
    case .trip:
      guard handleMode == .trip else {
        throw ClamshellSafetyControllerError.handleMismatch
      }
      if let sessionID = status.sessionID, sessionID != handle.id {
        throw ClamshellSafetyControllerError.handleMismatch
      }
      _ = try await client.stop(expectedSessionID: status.sessionID)
    case .none:
      break
    }
    knownHandles.removeValue(forKey: handle.id)
  }

  private func map(_ status: SupervisorStatusWire) -> ProtectionVerdict {
    switch status.verdict {
    case .inactive:
      return .inactive
    case .waitingForHotspot:
      return .acquiring
    case .acquiring:
      return .acquiring
    case .protected:
      return .protected(
        remaining: .seconds(status.remainingSeconds ?? 0),
        closedLidAllowed: status.closedLidAllowed
      )
    case .releasing:
      return .releasing(reason: mapReleaseReason(status))
    case .recoveryPending:
      return .recoveryPending(reason: status.detail ?? "recovery pending")
    case .unsafe:
      return .unsafe(reason: status.detail ?? "device safety policy stopped the session")
    case .unknown:
      return .unknown(reason: status.detail ?? "protection status is unknown")
    }
  }

  private func mapReleaseReason(_ status: SupervisorStatusWire) -> ReleaseReason {
    switch status.stopReason {
    case .userRequested:
      .userRequested
    case .hotspotHandoffTimedOut:
      .hotspotHandoffTimedOut
    case .hardDeadlineReached:
      .hardDeadlineReached
    case .safety:
      .safety(detail: status.detail ?? "device safety policy stopped the session")
    case .leaseRejected:
      .leaseRejected(detail: status.detail ?? "helper rejected the lease")
    case .leaseRecoveryPending:
      .leaseRecoveryPending(detail: status.detail ?? "lease recovery is pending")
    case .superseded:
      .superseded
    case nil:
      .unknown(detail: status.detail)
    }
  }

  private func wireProfile(_ profile: SafetyProfile) -> WireSafetyProfile {
    switch profile {
    case .bagSafe:
      .bagSafe
    }
  }
}

extension Duration {
  fileprivate var secondsValue: Double {
    let parts = components
    return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
  }
}
