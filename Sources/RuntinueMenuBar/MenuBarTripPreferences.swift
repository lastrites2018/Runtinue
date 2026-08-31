import Foundation
import RuntinueIPC

@MainActor
final class TripPreferences {
  private static let hotspotKey = "trip.lastHotspotSSID"
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  var lastHotspotSSID: String? {
    guard let value = defaults.object(forKey: Self.hotspotKey) as? String else {
      return nil
    }
    return try? TripFormInput.validatedHotspotSSID(value)
  }

  // 마지막 입력값만 저장한다. 연결 여부와 보호 상태는 Supervisor가 매번 확인한다.
  func remember(_ request: StartTripWireRequest) {
    guard request.networkTargetKind == .wifiHotspot,
      let value = request.expectedHotspotSSID,
      let ssid = try? TripFormInput.validatedHotspotSSID(value)
    else {
      return
    }
    defaults.set(ssid, forKey: Self.hotspotKey)
  }
}
