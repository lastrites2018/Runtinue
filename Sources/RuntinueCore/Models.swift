import Foundation

public struct NetworkSnapshot: Equatable, Sendable {
  public let ssid: String?
  public let interfaceName: String?
  public let gateway: String?
  public let routeReachable: Bool
  public let internetReachability: InternetReachability
  public let capturedAt: MonotonicInstant

  public init(
    ssid: String?,
    interfaceName: String?,
    gateway: String? = nil,
    routeReachable: Bool,
    internetReachability: InternetReachability = .unchecked,
    capturedAt: MonotonicInstant
  ) {
    self.ssid = ssid
    self.interfaceName = interfaceName
    self.gateway = gateway
    self.routeReachable = routeReachable
    self.internetReachability = internetReachability
    self.capturedAt = capturedAt
  }
}

public enum InternetReachability: String, Equatable, Sendable {
  case confirmed
  case unavailable
  case unchecked
}

public enum PowerConnection: String, Equatable, Sendable {
  case acCharging
  case acNotCharging
  case battery
  case unknown
}

public enum ThermalLevel: String, Equatable, Sendable {
  case nominal
  case fair
  case serious
  case critical
  case unknown

  var severity: Int? {
    switch self {
    case .nominal: 0
    case .fair: 1
    case .serious: 2
    case .critical: 3
    case .unknown: nil
    }
  }
}

public enum LidState: String, Equatable, Sendable {
  case open
  case closed
  case unknown
}

public enum ExternalDisplayState: String, Equatable, Sendable {
  case present
  case absent
  case unknown
}

public struct DeviceSafetySnapshot: Equatable, Sendable {
  public let batteryPercent: Int?
  public let powerConnection: PowerConnection
  public let thermalLevel: ThermalLevel
  public let lidState: LidState
  public let externalDisplayState: ExternalDisplayState
  public let lowPowerModeEnabled: Bool
  public let lidSignalsDisagree: Bool
  public let capturedAt: MonotonicInstant

  public init(
    batteryPercent: Int?,
    powerConnection: PowerConnection,
    thermalLevel: ThermalLevel,
    lidState: LidState,
    externalDisplayState: ExternalDisplayState,
    lowPowerModeEnabled: Bool,
    lidSignalsDisagree: Bool = false,
    capturedAt: MonotonicInstant
  ) {
    self.batteryPercent = batteryPercent
    self.powerConnection = powerConnection
    self.thermalLevel = thermalLevel
    self.lidState = lidState
    self.externalDisplayState = externalDisplayState
    self.lowPowerModeEnabled = lowPowerModeEnabled
    self.lidSignalsDisagree = lidSignalsDisagree
    self.capturedAt = capturedAt
  }
}
