import Foundation

public enum TemperatureComponent: String, Equatable, Sendable {
  case cpuInternal
  case gpuInternal
}

public enum TemperatureTelemetryStatus: String, Equatable, Sendable {
  case available
  case partial
  case unsupportedModel
  case mappingUnverified
  case temporarilyUnavailable
}

public enum TemperatureTelemetrySource: String, Equatable, Sendable {
  case appleSMC
}

public enum TemperatureMappingQuality: String, Equatable, Sendable {
  case singleDeviceValidated
}

public struct ComponentTemperatureObservation: Equatable, Sendable {
  public let component: TemperatureComponent
  public let minimumCelsius: Double?
  public let maximumCelsius: Double?
  public let validSensorCount: Int
  public let expectedSensorCount: Int
  public let validSensorIDs: [String]

  public init(
    component: TemperatureComponent,
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

public struct TemperatureTelemetrySnapshot: Equatable, Sendable {
  public let status: TemperatureTelemetryStatus
  public let source: TemperatureTelemetrySource
  public let machineModel: String?
  public let operatingSystemBuild: String?
  public let mappingRevision: String?
  public let mappingQuality: TemperatureMappingQuality?
  public let sampledAt: Date
  public let validUntil: Date?
  public let lastSuccessfulAt: Date?
  public let components: [ComponentTemperatureObservation]

  public init(
    status: TemperatureTelemetryStatus,
    source: TemperatureTelemetrySource,
    machineModel: String?,
    operatingSystemBuild: String? = nil,
    mappingRevision: String?,
    mappingQuality: TemperatureMappingQuality?,
    sampledAt: Date,
    validUntil: Date?,
    lastSuccessfulAt: Date?,
    components: [ComponentTemperatureObservation]
  ) {
    self.status = status
    self.source = source
    self.machineModel = machineModel
    self.operatingSystemBuild = operatingSystemBuild
    self.mappingRevision = mappingRevision
    self.mappingQuality = mappingQuality
    self.sampledAt = sampledAt
    self.validUntil = validUntil
    self.lastSuccessfulAt = lastSuccessfulAt
    self.components = components
  }
}
