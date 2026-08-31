import Foundation

public enum HotspotWaitingReason: Equatable, Sendable {
  case snapshotFromFuture
  case staleSnapshot(age: Duration)
  case routeUnavailable
  case ssidUnavailable
  case interfaceUnavailable
  case unexpectedSSID(observed: String?)
  case networkIdentityUnchanged
  case internetUnchecked
  case internetUnavailable
}

public enum CommuteNetworkTarget: Equatable, Sendable {
  case wifiHotspot(ssid: String)
  case usbTethering

  public var expectedSSID: String? {
    guard case .wifiHotspot(let ssid) = self else {
      return nil
    }
    return ssid
  }
}

public enum HotspotTransitionVerdict: Equatable, Sendable {
  case waiting(HotspotWaitingReason)
  case ready
}

public struct HotspotTransitionPolicy: Equatable, Sendable {
  public let target: CommuteNetworkTarget
  public let requireNetworkIdentityChange: Bool
  public let maximumSnapshotAge: Duration

  public init(
    expectedSSID: String,
    requireNetworkIdentityChange: Bool = true,
    maximumSnapshotAge: Duration = .seconds(15)
  ) {
    self.target = .wifiHotspot(
      ssid: expectedSSID.trimmingCharacters(in: .whitespacesAndNewlines)
    )
    self.requireNetworkIdentityChange = requireNetworkIdentityChange
    self.maximumSnapshotAge = maximumSnapshotAge
  }

  public init(
    target: CommuteNetworkTarget,
    requireNetworkIdentityChange: Bool = true,
    maximumSnapshotAge: Duration = .seconds(15)
  ) {
    switch target {
    case .wifiHotspot(let ssid):
      self.target = .wifiHotspot(
        ssid: ssid.trimmingCharacters(in: .whitespacesAndNewlines)
      )
    case .usbTethering:
      self.target = .usbTethering
    }
    self.requireNetworkIdentityChange = requireNetworkIdentityChange
    self.maximumSnapshotAge = maximumSnapshotAge
  }

  public func evaluate(
    origin: NetworkSnapshot,
    current: NetworkSnapshot,
    at now: MonotonicInstant
  ) -> HotspotTransitionVerdict {
    guard let age = now.durationSince(current.capturedAt) else {
      return .waiting(.snapshotFromFuture)
    }
    guard age <= maximumSnapshotAge else {
      return .waiting(.staleSnapshot(age: age))
    }
    guard current.routeReachable else {
      return .waiting(.routeUnavailable)
    }
    switch target {
    case .wifiHotspot(let expectedSSID):
      guard let currentSSID = current.ssid else {
        return .waiting(.ssidUnavailable)
      }
      guard currentSSID == expectedSSID else {
        return .waiting(.unexpectedSSID(observed: current.ssid))
      }
      guard let interface = current.interfaceName, !interface.isEmpty else {
        return .waiting(.interfaceUnavailable)
      }
    case .usbTethering:
      guard current.ssid == nil else {
        return .waiting(.unexpectedSSID(observed: current.ssid))
      }
      guard let currentInterface = current.interfaceName,
        let originInterface = origin.interfaceName
      else {
        return .waiting(.interfaceUnavailable)
      }
      guard currentInterface != originInterface else {
        return .waiting(.networkIdentityUnchanged)
      }
    }

    if requireNetworkIdentityChange {
      let identityChanged =
        knownValuesDiffer(origin.ssid, current.ssid)
        || knownValuesDiffer(origin.interfaceName, current.interfaceName)
        || knownValuesDiffer(origin.gateway, current.gateway)
      guard identityChanged else {
        return .waiting(.networkIdentityUnchanged)
      }
    }

    switch current.internetReachability {
    case .confirmed:
      break
    case .unchecked:
      return .waiting(.internetUnchecked)
    case .unavailable:
      return .waiting(.internetUnavailable)
    }

    return .ready
  }

  private func knownValuesDiffer<T: Equatable>(_ origin: T?, _ current: T?) -> Bool {
    guard let origin, let current else {
      return false
    }
    return origin != current
  }
}
