import Foundation

@objc public protocol SupervisorControlXPCProtocol {
  func protocolVersion(withReply reply: @escaping (Int) -> Void)
  func startTrip(_ request: Data, withReply reply: @escaping (Data) -> Void)
  func enableAdaptive(_ request: Data, withReply reply: @escaping (Data) -> Void)
  func disableAdaptive(_ request: Data, withReply reply: @escaping (Data) -> Void)
  func enableDesk(_ request: Data, withReply reply: @escaping (Data) -> Void)
  func disableDesk(_ request: Data, withReply reply: @escaping (Data) -> Void)
  func stop(_ request: Data, withReply reply: @escaping (Data) -> Void)
  func status(withReply reply: @escaping (Data) -> Void)
  func submitWiFiObservation(_ request: Data, withReply reply: @escaping (Data) -> Void)
}

@objc public protocol SupervisorActivityXPCProtocol {
  func protocolVersion(withReply reply: @escaping (Int) -> Void)
  func activityPing(_ request: Data, withReply reply: @escaping (Data) -> Void)
}

public enum WireCommuteNetworkTargetKind: String, Codable, Equatable, Sendable {
  case wifiHotspot
  case usbTethering
}

public enum WireSafetyProfile: String, Codable, Equatable, Sendable {
  case bagSafe
}

public struct StartTripWireRequest: Codable, Equatable, Sendable {
  public let protocolVersion: Int
  public let networkTargetKind: WireCommuteNetworkTargetKind
  public let expectedHotspotSSID: String?
  public let hotspotHandoffTimeoutSeconds: Double
  public let hardCapSeconds: Double
  public let safetyProfile: WireSafetyProfile
  public let allowAlreadyConnected: Bool

  public init(
    protocolVersion: Int = RuntinueIPCContract.protocolVersion,
    expectedHotspotSSID: String,
    hotspotHandoffTimeoutSeconds: Double,
    hardCapSeconds: Double,
    safetyProfile: WireSafetyProfile = .bagSafe,
    allowAlreadyConnected: Bool = false
  ) {
    self.protocolVersion = protocolVersion
    self.networkTargetKind = .wifiHotspot
    self.expectedHotspotSSID = expectedHotspotSSID
    self.hotspotHandoffTimeoutSeconds = hotspotHandoffTimeoutSeconds
    self.hardCapSeconds = hardCapSeconds
    self.safetyProfile = safetyProfile
    self.allowAlreadyConnected = allowAlreadyConnected
  }

  public init(
    protocolVersion: Int = RuntinueIPCContract.protocolVersion,
    networkTargetKind: WireCommuteNetworkTargetKind,
    expectedHotspotSSID: String? = nil,
    hotspotHandoffTimeoutSeconds: Double,
    hardCapSeconds: Double,
    safetyProfile: WireSafetyProfile = .bagSafe,
    allowAlreadyConnected: Bool = false
  ) {
    self.protocolVersion = protocolVersion
    self.networkTargetKind = networkTargetKind
    self.expectedHotspotSSID = expectedHotspotSSID
    self.hotspotHandoffTimeoutSeconds = hotspotHandoffTimeoutSeconds
    self.hardCapSeconds = hardCapSeconds
    self.safetyProfile = safetyProfile
    self.allowAlreadyConnected = allowAlreadyConnected
  }
}

public struct StopSessionWireRequest: Codable, Equatable, Sendable {
  public let protocolVersion: Int
  public let expectedSessionID: UUID?

  public init(
    protocolVersion: Int = RuntinueIPCContract.protocolVersion,
    expectedSessionID: UUID? = nil
  ) {
    self.protocolVersion = protocolVersion
    self.expectedSessionID = expectedSessionID
  }
}

public struct EnableAdaptiveWireRequest: Codable, Equatable, Sendable {
  public let protocolVersion: Int
  public let idleGraceSeconds: Double
  public let hardCapSeconds: Double
  public let safetyProfile: WireSafetyProfile

  public init(
    protocolVersion: Int = RuntinueIPCContract.protocolVersion,
    idleGraceSeconds: Double,
    hardCapSeconds: Double,
    safetyProfile: WireSafetyProfile = .bagSafe
  ) {
    self.protocolVersion = protocolVersion
    self.idleGraceSeconds = idleGraceSeconds
    self.hardCapSeconds = hardCapSeconds
    self.safetyProfile = safetyProfile
  }
}

public struct DisableAdaptiveWireRequest: Codable, Equatable, Sendable {
  public let protocolVersion: Int

  public init(
    protocolVersion: Int = RuntinueIPCContract.protocolVersion
  ) {
    self.protocolVersion = protocolVersion
  }
}

public struct EnableDeskWireRequest: Codable, Equatable, Sendable {
  public let protocolVersion: Int
  public let allowClosedLid: Bool
  public let hardCapSeconds: Double
  public let safetyProfile: WireSafetyProfile

  public init(
    protocolVersion: Int = RuntinueIPCContract.protocolVersion,
    allowClosedLid: Bool,
    hardCapSeconds: Double,
    safetyProfile: WireSafetyProfile = .bagSafe
  ) {
    self.protocolVersion = protocolVersion
    self.allowClosedLid = allowClosedLid
    self.hardCapSeconds = hardCapSeconds
    self.safetyProfile = safetyProfile
  }
}

public struct DisableDeskWireRequest: Codable, Equatable, Sendable {
  public let protocolVersion: Int

  public init(
    protocolVersion: Int = RuntinueIPCContract.protocolVersion
  ) {
    self.protocolVersion = protocolVersion
  }
}

public struct ActivityPingWireRequest: Codable, Equatable, Sendable {
  public let protocolVersion: Int
  public let source: String
  public let namedSession: String?

  public init(
    protocolVersion: Int = RuntinueIPCContract.protocolVersion,
    source: String,
    namedSession: String? = nil
  ) {
    self.protocolVersion = protocolVersion
    self.source = source
    self.namedSession = namedSession
  }
}

public struct WiFiObservationWireRequest: Codable, Equatable, Sendable {
  public let protocolVersion: Int
  public let ssid: String?
  public let interfaceName: String?

  public init(
    protocolVersion: Int = RuntinueIPCContract.protocolVersion,
    ssid: String?,
    interfaceName: String?
  ) {
    self.protocolVersion = protocolVersion
    self.ssid = ssid
    self.interfaceName = interfaceName
  }
}

public enum WireSupervisorCommandOutcome: String, Codable, Equatable, Sendable {
  case success
  case rejected
  case invalidRequest
  case unavailable
}

public enum WireTripPhase: String, Codable, Equatable, Sendable {
  case idle
  case waitingForHotspot
  case acquiringLease
  case active
  case releasingLease
  case ended
  case recoveryPending
}

public enum WireProtectionVerdict: String, Codable, Equatable, Sendable {
  case inactive
  case waitingForHotspot
  case acquiring
  case protected
  case releasing
  case recoveryPending
  case unsafe
  case unknown
}

public enum WireSessionMode: String, Codable, Equatable, Sendable {
  case none
  case trip
  case adaptive
  case desk
}

public enum WireSessionStopReason: String, Codable, Equatable, Sendable {
  case userRequested
  case hotspotHandoffTimedOut
  case hardDeadlineReached
  case safety
  case leaseRejected
  case leaseRecoveryPending
  case superseded
}

public enum WireObservationIssue: String, Codable, Equatable, Sendable {
  case buildIdentityUnavailable
  case eventsUnavailable
  case historyUnavailable
  case statusCacheUnavailable
}

public struct WireObservationStatus: Codable, Equatable, Sendable {
  public let buildID: String?
  public let issues: [WireObservationIssue]

  public init(buildID: String?, issues: [WireObservationIssue]) {
    self.buildID = buildID
    self.issues = issues
  }
}

public enum WireTemperatureComponent: String, Codable, Equatable, Sendable {
  case cpuInternal
  case gpuInternal
}

public enum WireTemperatureTelemetryStatus: String, Codable, Equatable, Sendable {
  case available
  case partial
  case unsupportedModel
  case mappingUnverified
  case temporarilyUnavailable
}

public enum WireTemperatureTelemetrySource: String, Codable, Equatable, Sendable {
  case appleSMC
}

public enum WireTemperatureMappingQuality: String, Codable, Equatable, Sendable {
  case singleDeviceValidated
}

public struct WireTemperatureComponentObservation: Codable, Equatable, Sendable {
  public let component: WireTemperatureComponent
  public let minimumCelsius: Double?
  public let maximumCelsius: Double?
  public let validSensorCount: Int
  public let expectedSensorCount: Int
  public let validSensorIDs: [String]

  public init(
    component: WireTemperatureComponent,
    minimumCelsius: Double?,
    maximumCelsius: Double?,
    validSensorCount: Int,
    expectedSensorCount: Int,
    validSensorIDs: [String]
  ) {
    self.component = component
    self.minimumCelsius = minimumCelsius
    self.maximumCelsius = maximumCelsius
    self.validSensorCount = validSensorCount
    self.expectedSensorCount = expectedSensorCount
    self.validSensorIDs = validSensorIDs
  }
}

public struct WireTemperatureTelemetry: Codable, Equatable, Sendable {
  public let status: WireTemperatureTelemetryStatus
  public let source: WireTemperatureTelemetrySource
  public let machineModel: String?
  public let operatingSystemBuild: String?
  public let mappingRevision: String?
  public let mappingQuality: WireTemperatureMappingQuality?
  public let samplingIntervalSeconds: Double?
  public let sampledAt: Date
  public let validUntil: Date?
  public let lastSuccessfulAt: Date?
  public let components: [WireTemperatureComponentObservation]

  public init(
    status: WireTemperatureTelemetryStatus,
    source: WireTemperatureTelemetrySource,
    machineModel: String?,
    operatingSystemBuild: String? = nil,
    mappingRevision: String?,
    mappingQuality: WireTemperatureMappingQuality?,
    samplingIntervalSeconds: Double? = nil,
    sampledAt: Date,
    validUntil: Date?,
    lastSuccessfulAt: Date?,
    components: [WireTemperatureComponentObservation]
  ) {
    self.status = status
    self.source = source
    self.machineModel = machineModel
    self.operatingSystemBuild = operatingSystemBuild
    self.mappingRevision = mappingRevision
    self.mappingQuality = mappingQuality
    self.samplingIntervalSeconds = samplingIntervalSeconds
    self.sampledAt = sampledAt
    self.validUntil = validUntil
    self.lastSuccessfulAt = lastSuccessfulAt
    self.components = components
  }
}

public struct SupervisorStatusWire: Codable, Equatable, Sendable {
  public let protocolVersion: Int
  public let phase: WireTripPhase
  public let mode: WireSessionMode
  public let sessionID: UUID?
  public let verdict: WireProtectionVerdict
  public let closedLidAllowed: Bool
  public let remainingSeconds: Double?
  public let batteryPercent: Int?
  public let thermalLevel: String?
  public let lidState: String?
  public let stopReason: WireSessionStopReason?
  public let observation: WireObservationStatus?
  public let temperatureTelemetry: WireTemperatureTelemetry?
  public let detail: String?
  public let updatedAt: Date

  public init(
    protocolVersion: Int = RuntinueIPCContract.protocolVersion,
    phase: WireTripPhase,
    mode: WireSessionMode = .none,
    sessionID: UUID?,
    verdict: WireProtectionVerdict,
    closedLidAllowed: Bool = false,
    remainingSeconds: Double?,
    batteryPercent: Int?,
    thermalLevel: String?,
    lidState: String?,
    stopReason: WireSessionStopReason? = nil,
    observation: WireObservationStatus? = nil,
    temperatureTelemetry: WireTemperatureTelemetry? = nil,
    detail: String?,
    updatedAt: Date
  ) {
    self.protocolVersion = protocolVersion
    self.phase = phase
    self.mode = mode
    self.sessionID = sessionID
    self.verdict = verdict
    self.closedLidAllowed = closedLidAllowed
    self.remainingSeconds = remainingSeconds
    self.batteryPercent = batteryPercent
    self.thermalLevel = thermalLevel
    self.lidState = lidState
    self.stopReason = stopReason
    self.observation = observation
    self.temperatureTelemetry = temperatureTelemetry
    self.detail = detail
    self.updatedAt = updatedAt
  }

  public func withObservation(_ observation: WireObservationStatus?) -> SupervisorStatusWire {
    SupervisorStatusWire(
      protocolVersion: protocolVersion, phase: phase, mode: mode, sessionID: sessionID,
      verdict: verdict, closedLidAllowed: closedLidAllowed, remainingSeconds: remainingSeconds,
      batteryPercent: batteryPercent, thermalLevel: thermalLevel, lidState: lidState,
      stopReason: stopReason, observation: observation,
      temperatureTelemetry: temperatureTelemetry, detail: detail, updatedAt: updatedAt
    )
  }

  public func withTemperatureTelemetry(
    _ temperatureTelemetry: WireTemperatureTelemetry?
  ) -> SupervisorStatusWire {
    SupervisorStatusWire(
      protocolVersion: protocolVersion, phase: phase, mode: mode, sessionID: sessionID,
      verdict: verdict, closedLidAllowed: closedLidAllowed, remainingSeconds: remainingSeconds,
      batteryPercent: batteryPercent, thermalLevel: thermalLevel, lidState: lidState,
      stopReason: stopReason, observation: observation,
      temperatureTelemetry: temperatureTelemetry, detail: detail, updatedAt: updatedAt
    )
  }
}

public struct SupervisorCommandWireResponse: Codable, Equatable, Sendable {
  public let protocolVersion: Int
  public let outcome: WireSupervisorCommandOutcome
  public let status: SupervisorStatusWire?
  public let error: String?

  public init(
    protocolVersion: Int = RuntinueIPCContract.protocolVersion,
    outcome: WireSupervisorCommandOutcome,
    status: SupervisorStatusWire?,
    error: String?
  ) {
    self.protocolVersion = protocolVersion
    self.outcome = outcome
    self.status = status
    self.error = error
  }
}

public struct ActivityPingWireResponse: Codable, Equatable, Sendable {
  public let protocolVersion: Int
  public let accepted: Bool
  public let detail: String?

  public init(
    protocolVersion: Int = RuntinueIPCContract.protocolVersion,
    accepted: Bool,
    detail: String?
  ) {
    self.protocolVersion = protocolVersion
    self.accepted = accepted
    self.detail = detail
  }
}

public struct WiFiObservationWireResponse: Codable, Equatable, Sendable {
  public let protocolVersion: Int
  public let accepted: Bool
  public let detail: String?

  public init(
    protocolVersion: Int = RuntinueIPCContract.protocolVersion,
    accepted: Bool,
    detail: String?
  ) {
    self.protocolVersion = protocolVersion
    self.accepted = accepted
    self.detail = detail
  }
}
