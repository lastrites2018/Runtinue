import CoreGraphics
import Foundation
import IOKit
import IOKit.ps
import SafeClamCore

public struct MacDeviceProbe: Sendable {
  private let clock: any MonotonicTimeSource

  public init(clock: any MonotonicTimeSource = SystemUptimeClock()) {
    self.clock = clock
  }

  public func snapshot() -> DeviceSafetySnapshot {
    let power = Self.readInternalBattery()
    return DeviceSafetySnapshot(
      batteryPercent: power.percentage,
      powerConnection: power.connection,
      thermalLevel: Self.readThermalLevel(),
      lidState: Self.readLidState(),
      externalDisplayState: Self.readExternalDisplayState(),
      lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
      capturedAt: clock.now()
    )
  }

  private static func readInternalBattery() -> (percentage: Int?, connection: PowerConnection) {
    guard let powerSnapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
      let sources = IOPSCopyPowerSourcesList(powerSnapshot)?.takeRetainedValue() as? [CFTypeRef]
    else {
      return (nil, .unknown)
    }

    for source in sources {
      guard
        let description = IOPSGetPowerSourceDescription(powerSnapshot, source)?
          .takeUnretainedValue() as? [String: Any],
        description["Type"] as? String == "InternalBattery"
      else {
        continue
      }

      let current = (description["Current Capacity"] as? NSNumber)?.doubleValue
      let maximum = (description["Max Capacity"] as? NSNumber)?.doubleValue
      let percentage: Int?
      if let current, let maximum, maximum > 0 {
        percentage = Int((current / maximum * 100).rounded())
      } else {
        percentage = nil
      }

      let connection: PowerConnection
      switch description["Power Source State"] as? String {
      case "AC Power":
        connection = .ac
      case "Battery Power":
        connection = .battery
      default:
        connection = .unknown
      }
      return (percentage, connection)
    }

    return (nil, .unknown)
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

  private static func readExternalDisplayState() -> ExternalDisplayState {
    var displayCount: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &displayCount) == .success else {
      return .unknown
    }

    var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
    guard CGGetActiveDisplayList(displayCount, &displays, &displayCount) == .success else {
      return .unknown
    }

    return displays.contains(where: { CGDisplayIsBuiltin($0) == 0 }) ? .present : .absent
  }
}
