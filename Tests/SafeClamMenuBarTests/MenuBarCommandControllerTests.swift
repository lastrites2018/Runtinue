import Foundation
import XCTest

@testable import SafeClamIPC
@testable import SafeClamMenuBar

@MainActor
final class MenuBarCommandControllerTests: XCTestCase {
  func testPendingCommandImmediatelyInvalidatesProtectedStatusUntilReply() async {
    let controller = MenuBarCommandController()
    let started = expectation(description: "명령 시작")
    let operation = SuspendedCommandOperation()
    var visibleStatus: SupervisorStatusWire? = Self.protectedStatus
    var presentation = MenuBarPresentation(status: visibleStatus)
    var updates: [MenuBarCommandUpdate] = []

    let command = controller.perform(
      operation: {
        started.fulfill()
        return try await operation.run()
      },
      didUpdate: { update in
        updates.append(update)
        visibleStatus = update.status
        presentation = MenuBarPresentation(
          status: update.status,
          isCommandInFlight: controller.isCommandInFlight
        )
      }
    )

    XCTAssertTrue(controller.isCommandInFlight)
    XCTAssertNil(visibleStatus)
    XCTAssertEqual(presentation.summary, "요청 처리 중, 덮개 닫기 금지")
    XCTAssertEqual(updates.count, 1)
    let startedResult = await XCTWaiter.fulfillment(of: [started], timeout: 1)
    XCTAssertEqual(startedResult, .completed)
    XCTAssertNil(visibleStatus)
    XCTAssertTrue(controller.isCommandInFlight)

    operation.finish(with: .success(Self.inactiveStatus))
    await command.value

    XCTAssertFalse(controller.isCommandInFlight)
    XCTAssertEqual(visibleStatus, Self.inactiveStatus)
    XCTAssertEqual(presentation.summary, "비활성")
    XCTAssertEqual(updates.count, 2)
  }

  func testFailedCommandCannotRestoreProtectedStatusBeforeFreshReply() async {
    let controller = MenuBarCommandController()
    let started = expectation(description: "실패할 명령 시작")
    let operation = SuspendedCommandOperation()
    var visibleStatus: SupervisorStatusWire? = Self.protectedStatus
    var presentation = MenuBarPresentation(status: visibleStatus)
    var reportedError: SupervisorXPCClientError?

    let command = controller.perform(
      operation: {
        started.fulfill()
        return try await operation.run()
      },
      didUpdate: { update in
        visibleStatus = update.status
        presentation = MenuBarPresentation(
          status: update.status,
          isCommandInFlight: controller.isCommandInFlight
        )
        if case .failed(let error) = update {
          reportedError = error as? SupervisorXPCClientError
        }
      }
    )
    let startedResult = await XCTWaiter.fulfillment(of: [started], timeout: 1)
    XCTAssertEqual(startedResult, .completed)
    operation.finish(with: .failure(SupervisorXPCClientError.unavailable))
    await command.value

    XCTAssertFalse(controller.isCommandInFlight)
    XCTAssertNil(visibleStatus)
    XCTAssertEqual(reportedError, .unavailable)
    XCTAssertEqual(presentation.summary, "보호 상태 확인 불가, 덮개 닫기 금지")
    let availability = MenuBarActionAvailability(
      status: visibleStatus,
      isCommandInFlight: controller.isCommandInFlight
    )
    XCTAssertFalse(availability.canStart)
    XCTAssertFalse(availability.canStop)

    await controller.perform(
      operation: { Self.protectedStatus },
      didUpdate: { update in
        visibleStatus = update.status
        presentation = MenuBarPresentation(
          status: update.status,
          isCommandInFlight: controller.isCommandInFlight
        )
      }
    ).value
    XCTAssertEqual(visibleStatus, Self.protectedStatus)
    XCTAssertEqual(presentation.summary, "보호 중, 덮개 닫기 가능")
  }

  func testPendingCommandDoesNotRunADuplicateOperation() async {
    let controller = MenuBarCommandController()
    let started = expectation(description: "첫 명령 시작")
    let operation = SuspendedCommandOperation()
    var firstUpdateCount = 0
    var duplicateOperationCount = 0
    var duplicateUpdateCount = 0

    let first = controller.perform(
      operation: {
        started.fulfill()
        return try await operation.run()
      },
      didUpdate: { _ in firstUpdateCount += 1 }
    )
    let startedResult = await XCTWaiter.fulfillment(of: [started], timeout: 1)
    XCTAssertEqual(startedResult, .completed)
    let duplicate = controller.perform(
      operation: {
        duplicateOperationCount += 1
        return Self.protectedStatus
      },
      didUpdate: { _ in duplicateUpdateCount += 1 }
    )
    operation.finish(with: .success(Self.inactiveStatus))
    await first.value
    await duplicate.value

    XCTAssertEqual(firstUpdateCount, 2)
    XCTAssertEqual(duplicateOperationCount, 0)
    XCTAssertEqual(duplicateUpdateCount, 0)
    XCTAssertFalse(controller.isCommandInFlight)
  }

  func testCancelledCommandCannotPublishALateProtectedReply() async {
    let controller = MenuBarCommandController()
    let started = expectation(description: "취소할 명령 시작")
    let operation = SuspendedCommandOperation()
    var updates: [MenuBarCommandUpdate] = []
    let command = controller.perform(
      operation: {
        started.fulfill()
        return try await operation.run()
      },
      didUpdate: { updates.append($0) }
    )
    let startedResult = await XCTWaiter.fulfillment(of: [started], timeout: 1)
    XCTAssertEqual(startedResult, .completed)
    controller.cancel()
    XCTAssertTrue(controller.isCommandInFlight)
    operation.finish(with: .success(Self.protectedStatus))
    await command.value

    XCTAssertEqual(updates.count, 1)
    XCTAssertNil(updates.first?.status)
    XCTAssertFalse(controller.isCommandInFlight)
  }

  func testCancellationBeforeExecutionDoesNotRunOperation() async {
    let controller = MenuBarCommandController()
    var operationCount = 0
    var updateCount = 0
    let command = controller.perform(
      operation: {
        operationCount += 1
        return Self.protectedStatus
      },
      didUpdate: { _ in updateCount += 1 }
    )
    controller.cancel()
    await command.value

    XCTAssertEqual(operationCount, 0)
    XCTAssertEqual(updateCount, 1)
    XCTAssertFalse(controller.isCommandInFlight)
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
      phase: .ended,
      mode: .none,
      sessionID: nil,
      verdict: .inactive,
      remainingSeconds: nil,
      batteryPercent: nil,
      thermalLevel: nil,
      lidState: nil,
      detail: nil,
      updatedAt: Date(timeIntervalSince1970: 2)
    )
  }
}

@MainActor
private final class SuspendedCommandOperation {
  private var continuation: CheckedContinuation<SupervisorStatusWire, Error>?
  private var result: Result<SupervisorStatusWire, Error>?

  func run() async throws -> SupervisorStatusWire {
    if let result {
      return try result.get()
    }
    return try await withCheckedThrowingContinuation { continuation = $0 }
  }

  func finish(with result: Result<SupervisorStatusWire, Error>) {
    self.result = result
    continuation?.resume(with: result)
    continuation = nil
  }
}
