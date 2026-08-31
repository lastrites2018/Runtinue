import Dispatch
import Foundation

/// A process-local monotonic timestamp. It is intentionally not persisted.
/// A privileged helper restart must release an existing lease instead of
/// reconstructing a prior monotonic deadline.
public struct MonotonicInstant: Hashable, Comparable, Sendable {
  public let uptimeNanoseconds: UInt64

  public init(uptimeNanoseconds: UInt64) {
    self.uptimeNanoseconds = uptimeNanoseconds
  }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.uptimeNanoseconds < rhs.uptimeNanoseconds
  }

  public func adding(_ duration: Duration) -> Self {
    let delta = duration.nonnegativeNanoseconds
    let (value, overflow) = uptimeNanoseconds.addingReportingOverflow(delta)
    return Self(uptimeNanoseconds: overflow ? .max : value)
  }

  public func durationSince(_ earlier: Self) -> Duration? {
    guard self >= earlier else {
      return nil
    }

    let difference = uptimeNanoseconds - earlier.uptimeNanoseconds
    if difference > UInt64(Int64.max) {
      return .nanoseconds(Int64.max)
    }
    return .nanoseconds(Int64(difference))
  }
}

public protocol MonotonicTimeSource: Sendable {
  func now() -> MonotonicInstant
}

public struct SystemUptimeClock: MonotonicTimeSource {
  public init() {}

  public func now() -> MonotonicInstant {
    MonotonicInstant(uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds)
  }
}

extension Duration {
  var nonnegativeNanoseconds: UInt64 {
    let parts = components
    guard parts.seconds >= 0, parts.attoseconds >= 0 else {
      return 0
    }

    let seconds = UInt64(parts.seconds)
    let nanoseconds = UInt64(parts.attoseconds / 1_000_000_000)
    let (scaledSeconds, multiplyOverflow) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
    guard !multiplyOverflow else {
      return .max
    }

    let (total, addOverflow) = scaledSeconds.addingReportingOverflow(nanoseconds)
    return addOverflow ? .max : total
  }
}
