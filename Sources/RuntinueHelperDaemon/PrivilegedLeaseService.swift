import Foundation
import RuntinueHelperCore
import RuntinueIPC

final class PrivilegedLeaseService: NSObject, PrivilegedLeaseXPCProtocol,
  @unchecked Sendable
{
  private let leaseActor: LeaseActor
  private let ownerUID: UInt32

  init(leaseActor: LeaseActor, ownerUID: UInt32) {
    self.leaseActor = leaseActor
    self.ownerUID = ownerUID
  }

  func protocolVersion(withReply reply: @escaping (Int) -> Void) {
    reply(RuntinueIPCContract.protocolVersion)
  }

  func acquire(_ request: Data, withReply reply: @escaping (Data) -> Void) {
    let replyBox = ReplyBox(reply)
    guard
      let decoded: AcquireLeaseWireRequest = decodeRequest(request),
      RuntinueIPCContract.acceptsRequest(
        protocolVersion: decoded.protocolVersion,
        byteCount: request.count
      ),
      let ttl = RuntinueIPCContract.validatedDuration(
        seconds: decoded.ttlSeconds,
        maximumSeconds: Double(LeaseAcquireRequest.maximumTTL.components.seconds)
      ),
      let hardCap = RuntinueIPCContract.validatedDuration(
        seconds: decoded.hardCapSeconds,
        maximumSeconds: Double(LeaseAcquireRequest.maximumHardCap.components.seconds)
      )
    else {
      replyBox.call(invalidRequestResponse("invalid acquire request"))
      return
    }

    Task {
      let result = await leaseActor.acquire(
        LeaseAcquireRequest(
          leaseID: decoded.leaseID,
          ownerUID: ownerUID,
          ttl: ttl,
          hardCap: hardCap,
          reason: decoded.reason
        )
      )
      replyBox.call(encodeMutationResult(result))
    }
  }

  func renew(_ request: Data, withReply reply: @escaping (Data) -> Void) {
    let replyBox = ReplyBox(reply)
    guard
      let decoded: RenewLeaseWireRequest = decodeRequest(request),
      RuntinueIPCContract.acceptsRequest(
        protocolVersion: decoded.protocolVersion,
        byteCount: request.count
      ),
      let ttl = RuntinueIPCContract.validatedDuration(
        seconds: decoded.ttlSeconds,
        maximumSeconds: Double(LeaseAcquireRequest.maximumTTL.components.seconds)
      )
    else {
      replyBox.call(invalidRequestResponse("invalid renew request"))
      return
    }

    Task {
      let result = await leaseActor.renew(
        leaseID: decoded.leaseID,
        ownerUID: ownerUID,
        ttl: ttl
      )
      replyBox.call(encodeMutationResult(result))
    }
  }

  func release(_ request: Data, withReply reply: @escaping (Data) -> Void) {
    let replyBox = ReplyBox(reply)
    guard
      let decoded: ReleaseLeaseWireRequest = decodeRequest(request),
      RuntinueIPCContract.acceptsRequest(
        protocolVersion: decoded.protocolVersion,
        byteCount: request.count
      )
    else {
      replyBox.call(invalidRequestResponse("invalid release request"))
      return
    }

    let reason: HelperReleaseReason
    switch decoded.reason {
    case .userRequested:
      reason = .userRequested
    case .safetyTrip:
      reason = .safetyTrip
    case .supervisorShutdown:
      reason = .shutdown
    }

    Task {
      let result = await leaseActor.release(
        leaseID: decoded.leaseID,
        ownerUID: ownerUID,
        reason: reason
      )
      replyBox.call(encodeMutationResult(result))
    }
  }

  func status(withReply reply: @escaping (Data) -> Void) {
    let replyBox = ReplyBox(reply)
    Task {
      let status = await leaseActor.status()
      replyBox.call(
        encodeResponse(
          HelperMutationWireResponse(
            outcome: status.phase == .recoveryPending ? .recoveryPending : .success,
            status: makeWireStatus(status),
            rejection: nil
          )
        )
      )
    }
  }

  func recover(withReply reply: @escaping (Data) -> Void) {
    let replyBox = ReplyBox(reply)
    Task {
      let status = await leaseActor.recover()
      replyBox.call(
        encodeResponse(
          HelperMutationWireResponse(
            outcome: status.phase == .recoveryPending ? .recoveryPending : .success,
            status: makeWireStatus(status),
            rejection: nil
          )
        )
      )
    }
  }

  private func decodeRequest<T: Decodable>(_ data: Data) -> T? {
    RuntinueIPCContract.decodeRequest(T.self, from: data)
  }

  private func encodeMutationResult(_ result: HelperLeaseMutationResult) -> Data {
    let response: HelperMutationWireResponse
    switch result {
    case .success(let status):
      response = HelperMutationWireResponse(
        outcome: .success,
        status: makeWireStatus(status),
        rejection: nil
      )
    case .rejected(let rejection):
      response = HelperMutationWireResponse(
        outcome: .rejected,
        status: nil,
        rejection: String(describing: rejection)
      )
    case .recoveryPending(let status):
      response = HelperMutationWireResponse(
        outcome: .recoveryPending,
        status: makeWireStatus(status),
        rejection: status.detail
      )
    }
    return encodeResponse(response)
  }

  private func makeWireStatus(_ status: HelperLeaseStatus) -> HelperStatusWire {
    let phase = WireHelperPhase(rawValue: status.phase.rawValue) ?? .unknown
    let sleepOverride: WireSleepOverride
    let observedDetail: String?
    switch status.observedSleepOverride {
    case .normal:
      sleepOverride = .normal
      observedDetail = nil
    case .disabled:
      sleepOverride = .disabled
      observedDetail = nil
    case .unavailable(let detail):
      sleepOverride = .unavailable
      observedDetail = detail
    }
    return HelperStatusWire(
      phase: phase,
      leaseID: status.leaseID,
      ownerUID: status.ownerUID,
      sleepOverride: sleepOverride,
      ttlDeadlineContinuousNanoseconds: status.ttlDeadline?.continuousNanoseconds,
      hardDeadlineContinuousNanoseconds: status.hardDeadline?.continuousNanoseconds,
      detail: status.detail ?? observedDetail
    )
  }

  private func invalidRequestResponse(_ detail: String) -> Data {
    encodeResponse(
      HelperMutationWireResponse(
        outcome: .invalidRequest,
        status: nil,
        rejection: detail
      )
    )
  }

  private func encodeResponse(_ response: HelperMutationWireResponse) -> Data {
    (try? JSONEncoder().encode(response)) ?? Data()
  }
}

private final class ReplyBox<Value>: @unchecked Sendable {
  private let reply: (Value) -> Void

  init(_ reply: @escaping (Value) -> Void) {
    self.reply = reply
  }

  func call(_ value: Value) {
    reply(value)
  }
}
