import Foundation
import RuntinueCore
import RuntinueIPC

@MainActor
final class TripPreferences {
  private static let hotspotKey = "trip.lastHotspotSSID"
  private static let verifiedKey = "trip.verifiedHotspot.v1"
  private let defaults: UserDefaults
  private var pendingVerification: (sessionID: UUID, ssid: String)?

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  var lastHotspotSSID: String? {
    verifiedHotspot?.ssid ?? lastEnteredSSID
  }

  var lastEnteredSSID: String? {
    guard let value = defaults.object(forKey: Self.hotspotKey) as? String else {
      return nil
    }
    return try? TripFormInput.validatedHotspotSSID(value)
  }

  var hasPendingVerification: Bool { pendingVerification != nil }

  private var verifiedHotspot: HotspotFingerprint? {
    guard let data = defaults.data(forKey: Self.verifiedKey), data.count <= 1_024,
      let fingerprint = try? JSONDecoder().decode(HotspotFingerprint.self, from: data),
      fingerprint.isValid
    else { return nil }
    return fingerprint
  }

  func confirmedHotspotSSID(for current: NetworkSnapshot?) -> String? {
    guard let verified = verifiedHotspot else { return nil }
    if current?.ssid == verified.ssid,
      current.flatMap(HotspotFingerprint.init) != verified
    {
      return nil
    }
    return verified.ssid
  }

  // 마지막 입력값만 저장한다. 연결 여부와 보호 상태는 Supervisor가 매번 확인한다.
  func rememberInput(_ request: StartTripWireRequest) {
    guard request.networkTargetKind == .wifiHotspot,
      let value = request.expectedHotspotSSID,
      let ssid = try? TripFormInput.validatedHotspotSSID(value)
    else {
      return
    }
    defaults.set(ssid, forKey: Self.hotspotKey)
  }

  func registerAcceptedRequest(_ request: StartTripWireRequest, status: SupervisorStatusWire) {
    pendingVerification = nil
    guard request.networkTargetKind == .wifiHotspot, request.allowAlreadyConnected,
      request.protocolVersion == RuntinueIPCContract.protocolVersion,
      let rawSSID = request.expectedHotspotSSID,
      let ssid = try? TripFormInput.validatedHotspotSSID(rawSSID),
      status.protocolVersion == RuntinueIPCContract.protocolVersion, status.mode == .trip,
      let sessionID = status.sessionID,
      [.waitingForHotspot, .acquiringLease, .active].contains(status.phase)
    else { return }
    pendingVerification = (sessionID, ssid)
  }

  func observeProtection(
    _ status: SupervisorStatusWire, network: NetworkSnapshot?, now: Date = Date()
  ) {
    guard let pending = pendingVerification else { return }
    guard status.sessionID == pending.sessionID, status.mode == .trip,
      ![.ended, .idle, .releasingLease, .recoveryPending].contains(status.phase)
    else {
      pendingVerification = nil
      return
    }
    let age = now.timeIntervalSince(status.updatedAt)
    guard status.protocolVersion == RuntinueIPCContract.protocolVersion,
      status.phase == .active, status.verdict == .protected, status.closedLidAllowed,
      age >= 0, age <= 30,
      let network, network.ssid == pending.ssid,
      let fingerprint = HotspotFingerprint(network),
      let data = try? JSONEncoder().encode(fingerprint)
    else { return }
    defaults.set(data, forKey: Self.verifiedKey)
    pendingVerification = nil
  }
}

private struct HotspotFingerprint: Codable, Equatable {
  let version: Int
  let ssid: String
  let gateway: String
  let interfaceName: String
  let interfaceKind: String

  init?(_ network: NetworkSnapshot) {
    guard network.routeReachable, let ssid = network.ssid,
      let gateway = network.gateway, let interfaceName = network.interfaceName
    else { return nil }
    self.version = 1
    self.ssid = ssid
    self.gateway = gateway
    self.interfaceName = interfaceName
    self.interfaceKind = "wifi"
    guard isValid else { return nil }
  }

  var isValid: Bool {
    version == 1 && interfaceKind == "wifi"
      && (try? TripFormInput.validatedHotspotSSID(ssid)) == ssid
      && !gateway.isEmpty && gateway.utf8.count <= 64
      && !interfaceName.isEmpty && interfaceName.utf8.count <= 64
  }
}
