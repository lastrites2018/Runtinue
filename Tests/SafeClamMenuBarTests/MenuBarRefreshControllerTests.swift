import Foundation
import XCTest

@testable import SafeClamIPC
@testable import SafeClamMenuBar

@MainActor
final class MenuBarRefreshControllerTests: XCTestCase {
  func testCancelledSamplingCannotSubmitOldWiFiObservation() async {
    let controller = MenuBarRefreshController()
    let samplingStarted = expectation(description: "sampling started")
    let sampling = SuspendedRefreshOperation()
    var submissionCount = 0
    var statusReadCount = 0
    var renderCount = 0

    let refresh = controller.refresh(
      observeWiFi: {
        samplingStarted.fulfill()
        await sampling.wait()
        return MenuBarWiFiObservation(ssid: "old hotspot", interfaceName: "en0")
      },
      submitWiFi: { _ in submissionCount += 1 },
      readStatus: {
        statusReadCount += 1
        return Self.inactiveStatus
      },
      render: { _ in renderCount += 1 }
    )
    let samplingResult = await XCTWaiter.fulfillment(of: [samplingStarted], timeout: 1)
    XCTAssertEqual(samplingResult, .completed)
    controller.cancel()
    sampling.resume()
    await refresh.value

    XCTAssertEqual(submissionCount, 0)
    XCTAssertEqual(statusReadCount, 0)
    XCTAssertEqual(renderCount, 0)
  }

  func testPendingSubmissionKeepsRefreshSingleFlightEvenAfterCancellation() async {
    let controller = MenuBarRefreshController()
    let submissionStarted = expectation(description: "submission started")
    let submission = SuspendedRefreshOperation()
    var observationCount = 0
    var submissionCount = 0
    var renderCount = 0

    func refresh() -> Task<Void, Never> {
      controller.refresh(
        observeWiFi: {
          observationCount += 1
          return MenuBarWiFiObservation(ssid: "hotspot", interfaceName: "en0")
        },
        submitWiFi: { _ in
          submissionCount += 1
          if submissionCount == 1 {
            submissionStarted.fulfill()
            await submission.wait()
          }
        },
        readStatus: { Self.inactiveStatus },
        render: { _ in renderCount += 1 }
      )
    }

    let first = refresh()
    let submissionResult = await XCTWaiter.fulfillment(of: [submissionStarted], timeout: 1)
    XCTAssertEqual(submissionResult, .completed)
    let duplicate = refresh()
    controller.cancel()
    let afterCancellation = refresh()
    submission.resume()
    await first.value
    await duplicate.value
    await afterCancellation.value

    XCTAssertEqual(observationCount, 1)
    XCTAssertEqual(submissionCount, 1)
    XCTAssertEqual(renderCount, 0)

    await refresh().value
    XCTAssertEqual(observationCount, 2)
    XCTAssertEqual(submissionCount, 2)
    XCTAssertEqual(renderCount, 1)
  }

  func testLateRefreshCannotRestoreProtectionAfterCommandFailure() async {
    let refreshController = MenuBarRefreshController()
    let commandController = MenuBarCommandController()
    let statusReadStarted = expectation(description: "이전 상태 조회 시작")
    let statusRead = SuspendedRefreshOperation()
    var visibleStatus: SupervisorStatusWire? = Self.protectedStatus
    var renderCount = 0

    let oldRefresh = refreshController.refresh(
      observeWiFi: { MenuBarWiFiObservation(ssid: nil, interfaceName: nil) },
      submitWiFi: { _ in },
      readStatus: {
        statusReadStarted.fulfill()
        await statusRead.wait()
        return Self.protectedStatus
      },
      render: {
        visibleStatus = $0
        renderCount += 1
      }
    )
    let readResult = await XCTWaiter.fulfillment(of: [statusReadStarted], timeout: 1)
    XCTAssertEqual(readResult, .completed)
    refreshController.cancel()
    await commandController.perform(
      operation: { throw SupervisorXPCClientError.unavailable },
      didUpdate: { visibleStatus = $0.status }
    ).value

    XCTAssertNil(visibleStatus)
    statusRead.resume()
    await oldRefresh.value
    XCTAssertNil(visibleStatus)
    XCTAssertEqual(renderCount, 0)

    await refreshController.refresh(
      observeWiFi: { MenuBarWiFiObservation(ssid: nil, interfaceName: nil) },
      submitWiFi: { _ in },
      readStatus: { Self.protectedStatus },
      render: {
        visibleStatus = $0
        renderCount += 1
      }
    ).value
    XCTAssertEqual(visibleStatus, Self.protectedStatus)
    XCTAssertEqual(renderCount, 1)
  }

  private static var protectedStatus: SupervisorStatusWire {
    SupervisorStatusWire(
      phase: .active,
      mode: .trip,
      sessionID: UUID(uuidString: "11111111-1111-4111-8111-111111111111"),
      verdict: .protected,
      closedLidAllowed: true,
      remainingSeconds: 600,
      batteryPercent: 80,
      thermalLevel: "nominal",
      lidState: "open",
      detail: nil,
      updatedAt: Date(timeIntervalSince1970: 1)
    )
  }

  private static var inactiveStatus: SupervisorStatusWire {
    SupervisorStatusWire(
      phase: .idle,
      mode: .none,
      sessionID: nil,
      verdict: .inactive,
      remainingSeconds: nil,
      batteryPercent: nil,
      thermalLevel: nil,
      lidState: nil,
      detail: nil,
      updatedAt: Date(timeIntervalSince1970: 1)
    )
  }
}

@MainActor
private final class SuspendedRefreshOperation {
  private var continuation: CheckedContinuation<Void, Never>?

  func wait() async {
    await withCheckedContinuation { continuation = $0 }
  }

  func resume() {
    continuation?.resume()
    continuation = nil
  }
}
