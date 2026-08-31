import XCTest

@testable import RuntinueHelperCore

final class FaultInjectingPowerBackendTests: XCTestCase {
  func testWriteFailureDoesNotChangeState() async {
    let backend = FaultInjectingPowerBackend(
      writeFaults: [1: .fail("fixture")]
    )

    do {
      try await backend.writeAndVerify(.disabled)
      XCTFail("expected injected failure")
    } catch {
      XCTAssertEqual(
        error as? InjectedPowerBackendError,
        .writeFailed("fixture")
      )
    }
    let snapshot = await backend.snapshot()
    XCTAssertEqual(snapshot.state, .normal)
    XCTAssertEqual(snapshot.writeCallCount, 1)
  }

  func testPartialWriteCanReproduceChangedStateWithReportedFailure() async {
    let backend = FaultInjectingPowerBackend(
      writeFaults: [1: .applyThenFail("lost reply")]
    )

    try? await backend.writeAndVerify(.disabled)

    let snapshot = await backend.snapshot()
    XCTAssertEqual(snapshot.state, .disabled)
    XCTAssertEqual(snapshot.writeCallCount, 1)
  }

  func testReadFaultIsConsumedAtConfiguredCall() async {
    let backend = FaultInjectingPowerBackend(
      readFaults: [2: .unavailable("timeout")]
    )

    let first = await backend.readSleepOverride()
    let second = await backend.readSleepOverride()
    let third = await backend.readSleepOverride()
    XCTAssertEqual(first, .normal)
    XCTAssertEqual(second, .unavailable("timeout"))
    XCTAssertEqual(third, .normal)
  }

  func testReadTimeoutBecomesUnavailableWithoutChangingState() async {
    let backend = FaultInjectingPowerBackend(
      readFaults: [
        1: .timeout(after: .milliseconds(1), detail: "read timed out")
      ]
    )

    let observed = await backend.readSleepOverride()
    let snapshot = await backend.snapshot()

    XCTAssertEqual(observed, .unavailable("read timed out"))
    XCTAssertEqual(snapshot.state, .normal)
    XCTAssertEqual(snapshot.readCallCount, 1)
  }

  func testWriteTimeoutFailsWithoutApplyingRequestedState() async {
    let backend = FaultInjectingPowerBackend(
      writeFaults: [
        1: .timeout(after: .milliseconds(1), detail: "write timed out")
      ]
    )

    do {
      try await backend.writeAndVerify(.disabled)
      XCTFail("expected injected timeout")
    } catch {
      XCTAssertEqual(
        error as? InjectedPowerBackendError,
        .timedOut("write timed out")
      )
    }
    let snapshot = await backend.snapshot()
    XCTAssertEqual(snapshot.state, .normal)
    XCTAssertEqual(snapshot.writeCallCount, 1)
  }
}
