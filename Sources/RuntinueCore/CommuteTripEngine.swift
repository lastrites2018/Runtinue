import Foundation

public struct CommuteTripRequest: Equatable, Sendable {
  public static let defaultHardCap: Duration = .seconds(90 * 60)
  public static let maximumHardCap: Duration = .seconds(24 * 60 * 60)
  public static let maximumHotspotSSIDBytes = 32

  public let networkTarget: CommuteNetworkTarget
  public let hotspotHandoffTimeout: Duration
  public let hardCap: Duration
  public let safetyPolicy: DeviceSafetyPolicy

  public init(
    expectedHotspotSSID: String,
    hotspotHandoffTimeout: Duration = .seconds(15 * 60),
    hardCap: Duration = Self.defaultHardCap,
    safetyPolicy: DeviceSafetyPolicy = DeviceSafetyPolicy()
  ) {
    self.networkTarget = .wifiHotspot(
      ssid: expectedHotspotSSID.trimmingCharacters(in: .whitespacesAndNewlines)
    )
    self.hotspotHandoffTimeout = hotspotHandoffTimeout
    self.hardCap = hardCap
    self.safetyPolicy = safetyPolicy
  }

  public init(
    networkTarget: CommuteNetworkTarget,
    hotspotHandoffTimeout: Duration = .seconds(15 * 60),
    hardCap: Duration = Self.defaultHardCap,
    safetyPolicy: DeviceSafetyPolicy = DeviceSafetyPolicy()
  ) {
    switch networkTarget {
    case .wifiHotspot(let ssid):
      self.networkTarget = .wifiHotspot(
        ssid: ssid.trimmingCharacters(in: .whitespacesAndNewlines)
      )
    case .usbTethering:
      self.networkTarget = .usbTethering
    }
    self.hotspotHandoffTimeout = hotspotHandoffTimeout
    self.hardCap = hardCap
    self.safetyPolicy = safetyPolicy
  }

  func validate() throws {
    if case .wifiHotspot(let ssid) = networkTarget {
      guard !ssid.isEmpty else {
        throw CommuteTripError.emptyHotspotSSID
      }
      guard ssid.utf8.count <= Self.maximumHotspotSSIDBytes else {
        throw CommuteTripError.hotspotSSIDTooLong
      }
    }
    guard hotspotHandoffTimeout > .zero else {
      throw CommuteTripError.invalidHotspotHandoffTimeout
    }
    guard hardCap > .zero else {
      throw CommuteTripError.invalidHardCap
    }
    guard hardCap <= Self.maximumHardCap else {
      throw CommuteTripError.hardCapExceedsMaximum
    }
  }
}

public enum CommuteTripError: Error, Equatable, Sendable {
  case emptyHotspotSSID
  case hotspotSSIDTooLong
  case invalidHotspotHandoffTimeout
  case invalidHardCap
  case hardCapExceedsMaximum
  case sessionAlreadyRunning
}

public struct LeaseToken: Hashable, Sendable {
  public let id: UUID

  public init(id: UUID = UUID()) {
    self.id = id
  }
}

public enum TripPhase: String, Equatable, Sendable {
  case idle
  case waitingForHotspot
  case acquiringLease
  case active
  case releasingLease
  case ended
  case recoveryPending
}

public enum TripStopReason: Equatable, Sendable {
  case userRequested
  case hotspotHandoffTimedOut
  case hardDeadlineReached
  case safety(DeviceSafetyStopReason)
  case leaseRejected(String)
  case leaseRecoveryPending(String)
  case superseded
}

public struct TripStatus: Equatable, Sendable {
  public let phase: TripPhase
  public let sessionID: UUID?
  public let hotspotDeadline: MonotonicInstant?
  public let hardDeadline: MonotonicInstant?
  public let stopReason: TripStopReason?
  public let hotspotWaitingReason: HotspotWaitingReason?

  public init(
    phase: TripPhase,
    sessionID: UUID?,
    hotspotDeadline: MonotonicInstant?,
    hardDeadline: MonotonicInstant?,
    stopReason: TripStopReason?,
    hotspotWaitingReason: HotspotWaitingReason?
  ) {
    self.phase = phase
    self.sessionID = sessionID
    self.hotspotDeadline = hotspotDeadline
    self.hardDeadline = hardDeadline
    self.stopReason = stopReason
    self.hotspotWaitingReason = hotspotWaitingReason
  }
}

public enum LeaseAcquisitionOutcome: Equatable, Sendable {
  case acquired(LeaseToken)
  case rejected(String)
  case recoveryPending(String)
}

public enum LeaseReleaseOutcome: Equatable, Sendable {
  case released
  case recoveryPending(String)
}

public enum TripCommand: Equatable, Sendable {
  case acquire(sessionID: UUID, hardCap: Duration)
  case release(sessionID: UUID, lease: LeaseToken, reason: TripStopReason)
}

public struct CommuteTripEngine: Sendable {
  private struct Session: Sendable {
    let id: UUID
    let request: CommuteTripRequest
    let originNetwork: NetworkSnapshot
    let hotspotDeadline: MonotonicInstant
    var latestDevice: DeviceSafetySnapshot
    var latestSafetyVerdict: DeviceSafetyVerdict
    var hardDeadline: MonotonicInstant?
    var lease: LeaseToken?
    var pendingStopReason: TripStopReason?
    var terminalStopReason: TripStopReason?
    var hotspotWaitingReason: HotspotWaitingReason?
  }

  public private(set) var phase: TripPhase = .idle
  private var session: Session?

  public init() {}

  @discardableResult
  public mutating func arm(
    _ request: CommuteTripRequest,
    originNetwork: NetworkSnapshot,
    device: DeviceSafetySnapshot,
    at now: MonotonicInstant,
    sessionID: UUID = UUID()
  ) throws -> TripStatus {
    try request.validate()
    guard !isRunning else {
      throw CommuteTripError.sessionAlreadyRunning
    }

    let safetyVerdict = request.safetyPolicy.evaluate(device, at: now)
    session = Session(
      id: sessionID,
      request: request,
      originNetwork: originNetwork,
      hotspotDeadline: now.adding(request.hotspotHandoffTimeout),
      latestDevice: device,
      latestSafetyVerdict: safetyVerdict,
      hardDeadline: nil,
      lease: nil,
      pendingStopReason: nil,
      terminalStopReason: nil,
      hotspotWaitingReason: nil
    )

    switch safetyVerdict {
    case .safe, .uncertain:
      phase = .waitingForHotspot
    case .stop(let reason):
      phase = .ended
      session?.terminalStopReason = .safety(reason)
    }
    return status
  }

  public mutating func observeNetwork(
    _ network: NetworkSnapshot,
    at now: MonotonicInstant
  ) -> [TripCommand] {
    guard phase == .waitingForHotspot, var currentSession = session else {
      return []
    }

    if now >= currentSession.hotspotDeadline {
      phase = .ended
      currentSession.terminalStopReason = .hotspotHandoffTimedOut
      session = currentSession
      return []
    }

    let hotspotPolicy = HotspotTransitionPolicy(
      target: currentSession.request.networkTarget,
      // Wi-Fi는 현재 연결의 준비 상태로 판단한다. USB의 인터페이스 전환 조건은 유지한다.
      requireNetworkIdentityChange: false
    )
    switch hotspotPolicy.evaluate(
      origin: currentSession.originNetwork,
      current: network,
      at: now
    ) {
    case .waiting(let reason):
      currentSession.hotspotWaitingReason = reason
      session = currentSession
      return []
    case .ready:
      currentSession.hotspotWaitingReason = nil
    }

    if case .safe = currentSession.latestSafetyVerdict {
      currentSession.latestSafetyVerdict = currentSession.request.safetyPolicy.evaluate(
        currentSession.latestDevice,
        at: now
      )
    }
    switch currentSession.latestSafetyVerdict {
    case .safe:
      phase = .acquiringLease
      session = currentSession
      return [
        .acquire(
          sessionID: currentSession.id,
          hardCap: currentSession.request.hardCap
        )
      ]
    case .stop(let reason):
      phase = .ended
      currentSession.terminalStopReason = .safety(reason)
      session = currentSession
      return []
    case .uncertain:
      session = currentSession
      return []
    }
  }

  public mutating func observeDevice(
    _ device: DeviceSafetySnapshot,
    at now: MonotonicInstant
  ) -> [TripCommand] {
    guard let currentSession = session else {
      return []
    }
    return observeDevice(
      device,
      verdict: currentSession.request.safetyPolicy.evaluate(device, at: now),
      at: now
    )
  }

  public mutating func observeDevice(
    _ device: DeviceSafetySnapshot,
    verdict: DeviceSafetyVerdict,
    at now: MonotonicInstant
  ) -> [TripCommand] {
    guard var currentSession = session else {
      return []
    }
    currentSession.latestDevice = device
    currentSession.latestSafetyVerdict = verdict
    session = currentSession

    guard phase == .active || phase == .acquiringLease else {
      return []
    }
    switch verdict {
    case .safe, .uncertain:
      return []
    case .stop(let reason):
      return beginRelease(reason: .safety(reason))
    }
  }

  public mutating func tick(at now: MonotonicInstant) -> [TripCommand] {
    guard let currentSession = session else {
      return []
    }

    switch phase {
    case .waitingForHotspot:
      if now >= currentSession.hotspotDeadline {
        phase = .ended
        session?.terminalStopReason = .hotspotHandoffTimedOut
      }
      return []
    case .acquiringLease, .active:
      if let hardDeadline = currentSession.hardDeadline, now >= hardDeadline {
        return beginRelease(reason: .hardDeadlineReached)
      }
      let latestVerdict: DeviceSafetyVerdict
      if case .safe = currentSession.latestSafetyVerdict {
        latestVerdict = currentSession.request.safetyPolicy.evaluate(
          currentSession.latestDevice,
          at: now
        )
      } else {
        latestVerdict = currentSession.latestSafetyVerdict
      }
      if case .stop(let reason) = latestVerdict {
        return beginRelease(reason: .safety(reason))
      }
      return []
    case .idle, .releasingLease, .ended, .recoveryPending:
      return []
    }
  }

  public mutating func stop() -> [TripCommand] {
    beginRelease(reason: .userRequested)
  }

  public mutating func completeAcquisition(
    sessionID: UUID,
    outcome: LeaseAcquisitionOutcome,
    at now: MonotonicInstant
  ) -> [TripCommand] {
    guard var currentSession = session, currentSession.id == sessionID else {
      if case .acquired(let lease) = outcome {
        return [.release(sessionID: sessionID, lease: lease, reason: .superseded)]
      }
      return []
    }

    switch outcome {
    case .acquired(let lease):
      currentSession.lease = lease
      currentSession.hardDeadline = now.adding(currentSession.request.hardCap)
      session = currentSession

      if phase == .acquiringLease {
        phase = .active
        return []
      }

      let reason = currentSession.pendingStopReason ?? .superseded
      phase = .releasingLease
      return [.release(sessionID: sessionID, lease: lease, reason: reason)]

    case .rejected(let message):
      phase = .ended
      currentSession.terminalStopReason =
        currentSession.pendingStopReason
        ?? .leaseRejected(message)
      session = currentSession
      return []

    case .recoveryPending(let message):
      phase = .recoveryPending
      currentSession.terminalStopReason = .leaseRecoveryPending(message)
      session = currentSession
      return []
    }
  }

  public mutating func completeRelease(
    sessionID: UUID,
    lease: LeaseToken,
    outcome: LeaseReleaseOutcome
  ) -> [TripCommand] {
    guard var currentSession = session,
      currentSession.id == sessionID,
      currentSession.lease == lease
    else {
      return []
    }

    switch outcome {
    case .released:
      phase = .ended
      currentSession.terminalStopReason = currentSession.pendingStopReason ?? .userRequested
      currentSession.lease = nil
    case .recoveryPending(let message):
      phase = .recoveryPending
      currentSession.terminalStopReason = .leaseRecoveryPending(message)
    }
    session = currentSession
    return []
  }

  @discardableResult
  public mutating func confirmRecovery() -> TripStatus {
    guard phase == .recoveryPending, var currentSession = session else {
      return status
    }
    phase = .ended
    currentSession.lease = nil
    currentSession.terminalStopReason =
      currentSession.pendingStopReason ?? .userRequested
    session = currentSession
    return status
  }

  public var status: TripStatus {
    TripStatus(
      phase: phase,
      sessionID: session?.id,
      hotspotDeadline: session?.hotspotDeadline,
      hardDeadline: session?.hardDeadline,
      stopReason: session?.terminalStopReason ?? session?.pendingStopReason,
      hotspotWaitingReason: session?.hotspotWaitingReason
    )
  }

  private var isRunning: Bool {
    switch phase {
    case .waitingForHotspot, .acquiringLease, .active, .releasingLease, .recoveryPending:
      true
    case .idle, .ended:
      false
    }
  }

  private mutating func beginRelease(reason: TripStopReason) -> [TripCommand] {
    guard var currentSession = session else {
      return []
    }

    switch phase {
    case .waitingForHotspot:
      phase = .ended
      currentSession.terminalStopReason = reason
      session = currentSession
      return []
    case .acquiringLease:
      phase = .releasingLease
      currentSession.pendingStopReason = reason
      session = currentSession
      return []
    case .active:
      guard let lease = currentSession.lease else {
        phase = .recoveryPending
        currentSession.terminalStopReason = .leaseRecoveryPending(
          "active session has no lease token")
        session = currentSession
        return []
      }
      phase = .releasingLease
      currentSession.pendingStopReason = reason
      session = currentSession
      return [.release(sessionID: currentSession.id, lease: lease, reason: reason)]
    case .idle, .releasingLease, .ended, .recoveryPending:
      return []
    }
  }
}
