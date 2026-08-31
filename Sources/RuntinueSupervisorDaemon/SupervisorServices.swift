import Foundation
import RuntinueCore
import RuntinueIPC
import RuntinueSupervisorSystem
import RuntinueUserSupport

final class SupervisorControlService: NSObject, SupervisorControlXPCProtocol,
  @unchecked Sendable
{
  private let runtime: SupervisorRuntime

  init(runtime: SupervisorRuntime) {
    self.runtime = runtime
  }

  func protocolVersion(withReply reply: @escaping (Int) -> Void) {
    reply(RuntinueIPCContract.protocolVersion)
  }

  func startTrip(_ request: Data, withReply reply: @escaping (Data) -> Void) {
    let replyBox = SupervisorReplyBox(reply)
    guard let decoded: StartTripWireRequest = decode(request),
      RuntinueIPCContract.acceptsRequest(
        protocolVersion: decoded.protocolVersion,
        byteCount: request.count
      ),
      let networkTarget = networkTarget(decoded),
      valid(decoded)
    else {
      rejectInvalid(.startTrip, message: "invalid trip request", reply: replyBox)
      return
    }

    execute(.startTrip, reply: replyBox) { [runtime] in
      try await runtime.startTrip(
        networkTarget: networkTarget,
        hotspotHandoffTimeout: .seconds(decoded.hotspotHandoffTimeoutSeconds),
        hardCap: .seconds(decoded.hardCapSeconds)
      )
    }
  }

  func stop(_ request: Data, withReply reply: @escaping (Data) -> Void) {
    let replyBox = SupervisorReplyBox(reply)
    guard let decoded: StopSessionWireRequest = decode(request),
      RuntinueIPCContract.acceptsRequest(
        protocolVersion: decoded.protocolVersion,
        byteCount: request.count
      )
    else {
      rejectInvalid(.stop, message: "invalid stop request", reply: replyBox)
      return
    }

    execute(.stop, reply: replyBox) { [runtime] in
      try await runtime.stop(
        expectedSessionID: decoded.expectedSessionID
      )
    }
  }

  func enableAdaptive(_ request: Data, withReply reply: @escaping (Data) -> Void) {
    let replyBox = SupervisorReplyBox(reply)
    guard let decoded: EnableAdaptiveWireRequest = decode(request),
      RuntinueIPCContract.acceptsRequest(
        protocolVersion: decoded.protocolVersion,
        byteCount: request.count
      ),
      decoded.idleGraceSeconds.isFinite,
      decoded.idleGraceSeconds > 0,
      decoded.idleGraceSeconds <= 60 * 60,
      decoded.hardCapSeconds.isFinite,
      decoded.hardCapSeconds > 0,
      decoded.hardCapSeconds <= 24 * 60 * 60,
      decoded.safetyProfile == .bagSafe
    else {
      rejectInvalid(.enableAdaptive, message: "invalid adaptive request", reply: replyBox)
      return
    }

    execute(.enableAdaptive, reply: replyBox) { [runtime] in
      try await runtime.enableAdaptive(
        idleGrace: .seconds(decoded.idleGraceSeconds),
        hardCap: .seconds(decoded.hardCapSeconds)
      )
    }
  }

  func disableAdaptive(_ request: Data, withReply reply: @escaping (Data) -> Void) {
    let replyBox = SupervisorReplyBox(reply)
    guard let decoded: DisableAdaptiveWireRequest = decode(request),
      RuntinueIPCContract.acceptsRequest(
        protocolVersion: decoded.protocolVersion,
        byteCount: request.count
      )
    else {
      rejectInvalid(.disableAdaptive, message: "invalid adaptive disable request", reply: replyBox)
      return
    }
    execute(.disableAdaptive, reply: replyBox) { [runtime] in
      try await runtime.disableAdaptive()
    }
  }

  func enableDesk(_ request: Data, withReply reply: @escaping (Data) -> Void) {
    let replyBox = SupervisorReplyBox(reply)
    guard let decoded: EnableDeskWireRequest = decode(request),
      RuntinueIPCContract.acceptsRequest(
        protocolVersion: decoded.protocolVersion,
        byteCount: request.count
      ),
      decoded.hardCapSeconds.isFinite,
      decoded.hardCapSeconds > 0,
      decoded.hardCapSeconds <= 24 * 60 * 60,
      decoded.safetyProfile == .bagSafe
    else {
      rejectInvalid(.enableDesk, message: "invalid desk request", reply: replyBox)
      return
    }
    execute(.enableDesk, reply: replyBox) { [runtime] in
      try await runtime.enableDesk(
        allowClosedLid: decoded.allowClosedLid,
        hardCap: .seconds(decoded.hardCapSeconds)
      )
    }
  }

  func disableDesk(_ request: Data, withReply reply: @escaping (Data) -> Void) {
    let replyBox = SupervisorReplyBox(reply)
    guard let decoded: DisableDeskWireRequest = decode(request),
      RuntinueIPCContract.acceptsRequest(
        protocolVersion: decoded.protocolVersion,
        byteCount: request.count
      )
    else {
      rejectInvalid(.disableDesk, message: "invalid desk disable request", reply: replyBox)
      return
    }
    execute(.disableDesk, reply: replyBox) { [runtime] in
      try await runtime.disableDesk()
    }
  }

  private func execute(
    _ command: SupervisorCommandKind, reply: SupervisorReplyBox<Data>,
    operation: @escaping @Sendable () async throws -> SupervisorStatusWire
  ) {
    Task {
      let attemptID = UUID()
      await runtime.recordEvent(.commandRequested, attemptID: attemptID, command: command)
      do {
        let status = try await operation()
        await runtime.recordEvent(
          .commandAccepted, attemptID: attemptID, sessionID: status.sessionID,
          command: command, stopReason: status.stopReason
        )
        reply.call(success(status))
      } catch {
        await runtime.recordEvent(.commandRejected, attemptID: attemptID, command: command)
        reply.call(rejected(String(describing: error)))
      }
    }
  }

  private func rejectInvalid(
    _ command: SupervisorCommandKind, message: String, reply: SupervisorReplyBox<Data>
  ) {
    Task {
      let attemptID = UUID()
      await runtime.recordEvent(.commandRequested, attemptID: attemptID, command: command)
      await runtime.recordEvent(.commandRejected, attemptID: attemptID, command: command)
      reply.call(invalidRequest(message))
    }
  }

  func status(withReply reply: @escaping (Data) -> Void) {
    let replyBox = SupervisorReplyBox(reply)
    Task {
      replyBox.call(success(await runtime.currentStatus()))
    }
  }

  func submitWiFiObservation(
    _ request: Data,
    withReply reply: @escaping (Data) -> Void
  ) {
    let replyBox = SupervisorReplyBox(reply)
    guard
      let decoded: WiFiObservationWireRequest = decode(request),
      RuntinueIPCContract.acceptsRequest(
        protocolVersion: decoded.protocolVersion,
        byteCount: request.count
      ),
      validWiFiObservation(decoded)
    else {
      replyBox.call(wifiObservationResponse(accepted: false, detail: "invalid Wi-Fi observation"))
      return
    }
    Task {
      await runtime.recordWiFiObservation(
        ssid: decoded.ssid,
        interfaceName: decoded.interfaceName
      )
      replyBox.call(wifiObservationResponse(accepted: true, detail: nil))
    }
  }

  private func valid(_ request: StartTripWireRequest) -> Bool {
    networkTarget(request) != nil
      && request.hotspotHandoffTimeoutSeconds.isFinite
      && request.hotspotHandoffTimeoutSeconds > 0
      && request.hotspotHandoffTimeoutSeconds <= 24 * 60 * 60
      && request.hardCapSeconds.isFinite
      && request.hardCapSeconds > 0
      && request.hardCapSeconds <= 24 * 60 * 60
      && request.safetyProfile == .bagSafe
  }

  private func validWiFiObservation(
    _ request: WiFiObservationWireRequest
  ) -> Bool {
    if let ssid = request.ssid {
      guard !ssid.isEmpty,
        ssid.utf8.count <= CommuteTripRequest.maximumHotspotSSIDBytes,
        let interfaceName = request.interfaceName,
        !interfaceName.isEmpty,
        interfaceName.utf8.count <= 64
      else {
        return false
      }
    } else if let interfaceName = request.interfaceName,
      interfaceName.utf8.count > 64
    {
      return false
    }
    return true
  }

  private func networkTarget(
    _ request: StartTripWireRequest
  ) -> CommuteNetworkTarget? {
    switch request.networkTargetKind {
    case .wifiHotspot:
      guard let rawSSID = request.expectedHotspotSSID else {
        return nil
      }
      let ssid = rawSSID.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !ssid.isEmpty,
        ssid.utf8.count <= CommuteTripRequest.maximumHotspotSSIDBytes
      else {
        return nil
      }
      return .wifiHotspot(ssid: ssid)
    case .usbTethering:
      guard request.expectedHotspotSSID == nil else {
        return nil
      }
      return .usbTethering
    }
  }

  private func decode<T: Decodable>(_ data: Data) -> T? {
    RuntinueIPCContract.decodeRequest(T.self, from: data)
  }

  private func success(_ status: SupervisorStatusWire) -> Data {
    encode(
      SupervisorCommandWireResponse(
        outcome: .success,
        status: status,
        error: nil
      )
    )
  }

  private func rejected(_ error: String) -> Data {
    encode(
      SupervisorCommandWireResponse(
        outcome: .rejected,
        status: nil,
        error: error
      )
    )
  }

  private func invalidRequest(_ error: String) -> Data {
    encode(
      SupervisorCommandWireResponse(
        outcome: .invalidRequest,
        status: nil,
        error: error
      )
    )
  }

  private func encode(_ response: SupervisorCommandWireResponse) -> Data {
    (try? JSONEncoder().encode(response)) ?? Data()
  }

  private func wifiObservationResponse(
    accepted: Bool,
    detail: String?
  ) -> Data {
    (try? JSONEncoder().encode(
      WiFiObservationWireResponse(
        accepted: accepted,
        detail: detail
      )
    )) ?? Data()
  }
}

final class SupervisorActivityService: NSObject, SupervisorActivityXPCProtocol,
  @unchecked Sendable
{
  private let runtime: SupervisorRuntime

  init(runtime: SupervisorRuntime) {
    self.runtime = runtime
  }

  func protocolVersion(withReply reply: @escaping (Int) -> Void) {
    reply(RuntinueIPCContract.protocolVersion)
  }

  func activityPing(_ request: Data, withReply reply: @escaping (Data) -> Void) {
    let replyBox = SupervisorReplyBox(reply)
    if let decoded = RuntinueIPCContract.decodeRequest(
      ActivityPingWireRequest.self,
      from: request
    ),
      RuntinueIPCContract.acceptsRequest(
        protocolVersion: decoded.protocolVersion,
        byteCount: request.count
      ),
      !decoded.source.isEmpty,
      decoded.source.utf8.count <= 1_024,
      decoded.namedSession?.utf8.count ?? 0 <= 1_024
    {
      Task {
        do {
          _ = try await runtime.activityPing(
            source: decoded.source,
            namedSession: decoded.namedSession
          )
          replyBox.call(
            (try? JSONEncoder().encode(
              ActivityPingWireResponse(accepted: true, detail: nil)
            )) ?? Data()
          )
        } catch {
          replyBox.call(
            (try? JSONEncoder().encode(
              ActivityPingWireResponse(
                accepted: false,
                detail: String(describing: error)
              )
            )) ?? Data()
          )
        }
      }
    } else {
      replyBox.call(
        (try? JSONEncoder().encode(
          ActivityPingWireResponse(
            accepted: false,
            detail: "invalid activity request"
          )
        )) ?? Data()
      )
    }
  }
}

private final class SupervisorReplyBox<Value>: @unchecked Sendable {
  private let reply: (Value) -> Void

  init(_ reply: @escaping (Value) -> Void) {
    self.reply = reply
  }

  func call(_ value: Value) {
    reply(value)
  }
}
