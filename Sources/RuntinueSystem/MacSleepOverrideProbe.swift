import Foundation
import IOKit

public enum MacSleepOverrideObservation: Equatable, Sendable {
  case normal
  case disabled
  case unavailable(String)
}

public struct MacSleepOverrideProbe: Sendable {
  public init() {}

  public func read() -> MacSleepOverrideObservation {
    let service = IOServiceGetMatchingService(
      kIOMainPortDefault,
      IOServiceMatching("IOPMrootDomain")
    )
    guard service != IO_OBJECT_NULL else {
      return .unavailable("IOPMrootDomain을 찾을 수 없음")
    }
    defer { IOObjectRelease(service) }

    guard
      let value = IORegistryEntryCreateCFProperty(
        service,
        "SleepDisabled" as CFString,
        kCFAllocatorDefault,
        0
      )?.takeRetainedValue() as? Bool
    else {
      return .unavailable("SleepDisabled를 읽을 수 없음")
    }
    return value ? .disabled : .normal
  }
}
