import Darwin
import XCTest

@testable import RuntinueCore

final class ContinuousTimeTests: XCTestCase {
  func testSystemClockUsesTheSharedSleepInclusiveDarwinTimebase() {
    let before = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
    let now = SystemContinuousClock().now().continuousNanoseconds
    let after = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
    XCTAssertGreaterThanOrEqual(now, before)
    XCTAssertLessThanOrEqual(now, after)
  }

  func testInstantArithmeticSaturatesAndRejectsReverseTime() {
    let now = MonotonicInstant(continuousNanoseconds: UInt64.max - 1)
    XCTAssertEqual(now.adding(.seconds(1)).continuousNanoseconds, .max)
    XCTAssertNil(now.durationSince(now.adding(.nanoseconds(1))))
    XCTAssertEqual(now.adding(.seconds(-1)), now)
  }
}
