import Foundation
import XCTest

@testable import RuntinueIPC
@testable import RuntinueKit

@MainActor
final class ClamshellSafetyControllerTests: XCTestCase {
  func testTripStartReturnsSupervisorSessionAndForwardsNetworkContract() async throws {
    let sessionID = UUID()
    let client = FakeSupervisorControlClient(
      status: wireStatus(
        mode: .trip,
        sessionID: sessionID,
        verdict: .waitingForHotspot
      )
    )
    let controller = ClamshellSafetyController(client: client)

    let handle = try await controller.start(
      SessionRequest(
        mode: .trip(
          expectedHotspotSSID: "iPhone",
          handoffTimeout: .seconds(600),
          alreadyConnected: true
        ),
        hardCap: .seconds(3_600)
      )
    )

    XCTAssertEqual(handle.id, sessionID)
    let calls = await client.recordedCalls()
    XCTAssertEqual(
      calls,
      [
        .startTrip(
          targetKind: .wifiHotspot,
          ssid: "iPhone",
          handoffTimeoutSeconds: 600,
          hardCapSeconds: 3_600,
          safetyProfile: .bagSafe,
          alreadyConnected: true
        )
      ]
    )
  }

  func testUSBTetheredTripForwardsExplicitNetworkTarget() async throws {
    let sessionID = UUID()
    let client = FakeSupervisorControlClient(
      status: wireStatus(
        mode: .trip,
        sessionID: sessionID,
        verdict: .waitingForHotspot
      )
    )
    let controller = ClamshellSafetyController(client: client)

    let handle = try await controller.start(
      SessionRequest(
        mode: .usbTetheredTrip(handoffTimeout: .seconds(300)),
        hardCap: .seconds(3_600)
      )
    )

    XCTAssertEqual(handle.id, sessionID)
    let calls = await client.recordedCalls()
    XCTAssertEqual(
      calls,
      [
        .startTrip(
          targetKind: .usbTethering,
          ssid: nil,
          handoffTimeoutSeconds: 300,
          hardCapSeconds: 3_600,
          safetyProfile: .bagSafe
        )
      ]
    )
  }

  func testHotspotWaitMapsToAcquiringAndNeverProtected() async {
    let client = FakeSupervisorControlClient(
      status: wireStatus(
        mode: .trip,
        sessionID: UUID(),
        verdict: .waitingForHotspot
      )
    )
    let controller = ClamshellSafetyController(client: client)

    let verdict = await controller.status()
    XCTAssertEqual(verdict, .acquiring)
  }

  func testStatusFailureMapsToUnknown() async {
    let client = FakeSupervisorControlClient(
      status: wireStatus(mode: .none, sessionID: nil, verdict: .inactive),
      statusFailure: .unavailable
    )
    let controller = ClamshellSafetyController(client: client)

    guard case .unknown(let reason) = await controller.status() else {
      return XCTFail("expected unknown verdict")
    }
    XCTAssertTrue(reason.contains("Supervisor"))
  }

  func testReleasingStatusMapsStructuredReleaseReason() async {
    let client = FakeSupervisorControlClient(
      status: wireStatus(
        mode: .trip,
        sessionID: UUID(),
        verdict: .releasing,
        stopReason: .hardDeadlineReached,
        detail: "hard deadline reached"
      )
    )
    let controller = ClamshellSafetyController(client: client)
    let status = await controller.status()

    XCTAssertEqual(
      status,
      .releasing(reason: .hardDeadlineReached)
    )
  }

  func testAdaptiveHandleStopsByDisablingAdaptiveMode() async throws {
    let enabled = wireStatus(mode: .adaptive, sessionID: nil, verdict: .inactive)
    let client = FakeSupervisorControlClient(status: enabled)
    let controller = ClamshellSafetyController(client: client)
    let handle = try await controller.start(
      SessionRequest(
        mode: .adaptive(idleGrace: .seconds(120)),
        hardCap: .seconds(3_600)
      )
    )

    try await controller.stop(handle)

    let calls = await client.recordedCalls()
    XCTAssertEqual(calls.count, 3)
    XCTAssertEqual(
      calls[0],
      .enableAdaptive(
        idleGraceSeconds: 120,
        hardCapSeconds: 3_600,
        safetyProfile: .bagSafe
      )
    )
    XCTAssertEqual(calls[1], .status)
    XCTAssertEqual(calls[2], .disableAdaptive)
  }

  func testUnknownHandleCannotStopASession() async {
    let client = FakeSupervisorControlClient(
      status: wireStatus(mode: .trip, sessionID: UUID(), verdict: .protected)
    )
    let controller = ClamshellSafetyController(client: client)

    do {
      try await controller.stop(SessionHandle(id: UUID()))
      XCTFail("expected handle mismatch")
    } catch {
      XCTAssertEqual(
        error as? ClamshellSafetyControllerError,
        .handleMismatch
      )
    }
    let calls = await client.recordedCalls()
    XCTAssertEqual(calls, [])
  }

  func testRejectsNonPositiveHardCapBeforeIPC() async {
    let client = FakeSupervisorControlClient(
      status: wireStatus(mode: .none, sessionID: nil, verdict: .inactive)
    )
    let controller = ClamshellSafetyController(client: client)

    do {
      _ = try await controller.start(
        SessionRequest(
          mode: .trip(expectedHotspotSSID: "iPhone"),
          hardCap: .zero
        )
      )
      XCTFail("expected invalid hard cap")
    } catch {
      XCTAssertEqual(
        error as? ClamshellSafetyControllerError,
        .invalidHardCap
      )
    }
    let calls = await client.recordedCalls()
    XCTAssertEqual(calls, [])
  }

  func testTripRequiresSupervisorOwnedSessionIdentifier() async {
    let client = FakeSupervisorControlClient(
      status: wireStatus(mode: .trip, sessionID: nil, verdict: .waitingForHotspot)
    )
    let controller = ClamshellSafetyController(client: client)

    do {
      _ = try await controller.start(
        SessionRequest(
          mode: .trip(expectedHotspotSSID: "iPhone"),
          hardCap: .seconds(3_600)
        )
      )
      XCTFail("expected missing session identifier")
    } catch {
      XCTAssertEqual(
        error as? ClamshellSafetyControllerError,
        .missingSessionIdentifier
      )
    }
  }

  func testHandleFromAnotherModeCannotDisableCurrentMode() async throws {
    let client = FakeSupervisorControlClient(
      status: wireStatus(
        mode: .adaptive,
        sessionID: UUID(),
        verdict: .inactive
      )
    )
    let controller = ClamshellSafetyController(client: client)
    let handle = try await controller.start(
      SessionRequest(
        mode: .trip(expectedHotspotSSID: "iPhone"),
        hardCap: .seconds(3_600)
      )
    )

    do {
      try await controller.stop(handle)
      XCTFail("expected handle mismatch")
    } catch {
      XCTAssertEqual(
        error as? ClamshellSafetyControllerError,
        .handleMismatch
      )
    }
    let calls = await client.recordedCalls()
    XCTAssertEqual(calls.count, 2)
    XCTAssertEqual(calls[1], .status)
  }
}

private enum FakeCall: Equatable, Sendable {
  case startTrip(
    targetKind: WireCommuteNetworkTargetKind,
    ssid: String?,
    handoffTimeoutSeconds: Double,
    hardCapSeconds: Double,
    safetyProfile: WireSafetyProfile,
    alreadyConnected: Bool = false
  )
  case status
  case stop(UUID?)
  case enableAdaptive(
    idleGraceSeconds: Double,
    hardCapSeconds: Double,
    safetyProfile: WireSafetyProfile
  )
  case disableAdaptive
  case enableDesk(
    allowClosedLid: Bool,
    hardCapSeconds: Double,
    safetyProfile: WireSafetyProfile
  )
  case disableDesk
}

private actor FakeSupervisorControlClient: SupervisorControlClient {
  private let response: SupervisorStatusWire
  private let statusFailure: SupervisorXPCClientError?
  private var calls: [FakeCall] = []

  init(
    status: SupervisorStatusWire,
    statusFailure: SupervisorXPCClientError? = nil
  ) {
    response = status
    self.statusFailure = statusFailure
  }

  func startTrip(_ request: StartTripWireRequest) async throws -> SupervisorStatusWire {
    calls.append(
      .startTrip(
        targetKind: request.networkTargetKind,
        ssid: request.expectedHotspotSSID,
        handoffTimeoutSeconds: request.hotspotHandoffTimeoutSeconds,
        hardCapSeconds: request.hardCapSeconds,
        safetyProfile: request.safetyProfile,
        alreadyConnected: request.allowAlreadyConnected
      )
    )
    return response
  }

  func stop(expectedSessionID: UUID?) async throws -> SupervisorStatusWire {
    calls.append(.stop(expectedSessionID))
    return response
  }

  func status() async throws -> SupervisorStatusWire {
    calls.append(.status)
    if let statusFailure {
      throw statusFailure
    }
    return response
  }

  func enableAdaptive(
    idleGraceSeconds: Double,
    hardCapSeconds: Double,
    safetyProfile: WireSafetyProfile
  ) async throws -> SupervisorStatusWire {
    calls.append(
      .enableAdaptive(
        idleGraceSeconds: idleGraceSeconds,
        hardCapSeconds: hardCapSeconds,
        safetyProfile: safetyProfile
      )
    )
    return response
  }

  func disableAdaptive() async throws -> SupervisorStatusWire {
    calls.append(.disableAdaptive)
    return response
  }

  func enableDesk(
    allowClosedLid: Bool,
    hardCapSeconds: Double,
    safetyProfile: WireSafetyProfile
  ) async throws -> SupervisorStatusWire {
    calls.append(
      .enableDesk(
        allowClosedLid: allowClosedLid,
        hardCapSeconds: hardCapSeconds,
        safetyProfile: safetyProfile
      )
    )
    return response
  }

  func disableDesk() async throws -> SupervisorStatusWire {
    calls.append(.disableDesk)
    return response
  }

  func recordedCalls() -> [FakeCall] {
    calls
  }
}

private func wireStatus(
  mode: WireSessionMode,
  sessionID: UUID?,
  verdict: WireProtectionVerdict,
  stopReason: WireSessionStopReason? = nil,
  detail: String? = nil
) -> SupervisorStatusWire {
  SupervisorStatusWire(
    phase: verdict == .waitingForHotspot ? .waitingForHotspot : .active,
    mode: mode,
    sessionID: sessionID,
    verdict: verdict,
    closedLidAllowed: verdict == .protected,
    remainingSeconds: verdict == .protected ? 600 : nil,
    batteryPercent: 80,
    thermalLevel: "nominal",
    lidState: "open",
    stopReason: stopReason,
    detail: detail,
    updatedAt: Date(timeIntervalSince1970: 1)
  )
}
