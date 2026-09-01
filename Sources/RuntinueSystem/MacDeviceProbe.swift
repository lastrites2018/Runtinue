import CoreGraphics
import Foundation
import IOKit
import IOKit.ps
import RuntinueCore

public struct MacDeviceProbe: Sendable {
  private let clock: any MonotonicTimeSource

  public init(clock: any MonotonicTimeSource = SystemContinuousClock()) {
    self.clock = clock
  }

  public func snapshot() -> DeviceSafetySnapshot {
    let power = Self.readInternalBattery()
    let displays = Self.readDisplayStates()
    let lid = Self.reconcileLid(
      registry: Self.readLidState(),
      hasInternalBattery: power.hasInternalBattery,
      internalDisplayActive: displays.internalActive
    )
    return DeviceSafetySnapshot(
      batteryPercent: power.percentage,
      powerConnection: power.connection,
      thermalLevel: Self.readThermalLevel(),
      lidState: lid.state,
      externalDisplayState: displays.external,
      lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
      lidSignalsDisagree: lid.signalsDisagree,
      capturedAt: clock.now()
    )
  }

  private static func readInternalBattery() -> (
    percentage: Int?, connection: PowerConnection, hasInternalBattery: Bool?
  ) {
    guard let powerSnapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
      let sources = IOPSCopyPowerSourcesList(powerSnapshot)?.takeRetainedValue() as? [CFTypeRef]
    else {
      return (nil, .unknown, nil)
    }

    for source in sources {
      guard
        let description = IOPSGetPowerSourceDescription(powerSnapshot, source)?
          .takeUnretainedValue() as? [String: Any],
        description["Type"] as? String == "InternalBattery"
      else {
        continue
      }

      let parsed = parseInternalBattery(description)
      return (parsed.percentage, parsed.connection, true)
    }

    return (nil, .unknown, false)
  }

  static func parseInternalBattery(_ description: [String: Any]) -> (
    percentage: Int?, connection: PowerConnection
  ) {
    let current = (description["Current Capacity"] as? NSNumber)?.doubleValue
    let maximum = (description["Max Capacity"] as? NSNumber)?.doubleValue
    let percentage: Int?
    if let current, let maximum, current.isFinite, maximum.isFinite,
      maximum > 0, current >= 0, current <= maximum
    {
      percentage = Int((current / maximum * 100).rounded())
    } else {
      percentage = nil
    }

    let connection: PowerConnection
    switch description["Power Source State"] as? String {
    case "AC Power":
      connection = description["Is Charging"] as? Bool == true ? .acCharging : .acNotCharging
    case "Battery Power":
      connection = .battery
    default:
      connection = .unknown
    }
    return (percentage, connection)
  }

  static func reconcileLid(
    registry: LidState,
    hasInternalBattery: Bool?,
    internalDisplayActive: Bool?
  ) -> (state: LidState, signalsDisagree: Bool) {
    guard hasInternalBattery == true else { return (registry, false) }
    guard let internalDisplayActive else {
      return (registry == .closed ? .closed : .unknown, false)
    }
    if registry == .open, !internalDisplayActive { return (.closed, true) }
    if registry == .closed, internalDisplayActive { return (.closed, true) }
    return (registry, false)
  }

  private static func readThermalLevel() -> ThermalLevel {
    switch ProcessInfo.processInfo.thermalState {
    case .nominal:
      .nominal
    case .fair:
      .fair
    case .serious:
      .serious
    case .critical:
      .critical
    @unknown default:
      .unknown
    }
  }

  private static func readLidState() -> LidState {
    let service = IOServiceGetMatchingService(
      kIOMainPortDefault,
      IOServiceMatching("IOPMrootDomain")
    )
    guard service != IO_OBJECT_NULL else {
      return .unknown
    }
    defer { IOObjectRelease(service) }

    guard
      let property = IORegistryEntryCreateCFProperty(
        service,
        "AppleClamshellState" as CFString,
        kCFAllocatorDefault,
        0
      )?.takeRetainedValue() as? Bool
    else {
      return .unknown
    }
    return property ? .closed : .open
  }

  private static func readDisplayStates() -> (
    internalActive: Bool?, external: ExternalDisplayState
  ) {
    var displayCount: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &displayCount) == .success else {
      return (nil, .unknown)
    }

    var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
    guard CGGetActiveDisplayList(displayCount, &displays, &displayCount) == .success else {
      return (nil, .unknown)
    }

    return (
      displays.contains(where: { CGDisplayIsBuiltin($0) != 0 }),
      displays.contains(where: { CGDisplayIsBuiltin($0) == 0 }) ? .present : .absent
    )
  }
}
