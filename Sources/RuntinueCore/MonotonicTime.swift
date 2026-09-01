import Darwin
import Foundation

/// A boot-scoped, sleep-inclusive monotonic timestamp shared across processes.
/// It is intentionally not persisted or compared across boots.
/// A privileged helper restart must release an existing lease instead of
/// reconstructing a prior monotonic deadline.
public struct MonotonicInstant: Hashable, Comparable, Sendable {
  public let continuousNanoseconds: UInt64

  public init(continuousNanoseconds: UInt64) {
    self.continuousNanoseconds = continuousNanoseconds
  }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.continuousNanoseconds < rhs.continuousNanoseconds
  }

  public func adding(_ duration: Duration) -> Self {
    let delta = duration.nonnegativeNanoseconds
    let (value, overflow) = continuousNanoseconds.addingReportingOverflow(delta)
    return Self(continuousNanoseconds: overflow ? .max : value)
  }

  public func durationSince(_ earlier: Self) -> Duration? {
    guard self >= earlier else {
      return nil
    }

    let difference = continuousNanoseconds - earlier.continuousNanoseconds
    if difference > UInt64(Int64.max) {
      return .nanoseconds(Int64.max)
    }
    return .nanoseconds(Int64(difference))
  }
}

public protocol MonotonicTimeSource: Sendable {
  func now() -> MonotonicInstant
}

public struct SystemContinuousClock: MonotonicTimeSource {
  public init() {}

  public func now() -> MonotonicInstant {
    MonotonicInstant(continuousNanoseconds: clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW))
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
