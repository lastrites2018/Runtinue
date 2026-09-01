import RuntinueCore
import RuntinueSystem

public struct MacEnvironmentSampler: SupervisorEnvironmentSampling, Sendable {
  private let networkProbe: MacNetworkProbe
  private let deviceProbe: MacDeviceProbe

  public init(clock: any MonotonicTimeSource = SystemContinuousClock()) {
    self.networkProbe = MacNetworkProbe(clock: clock)
    self.deviceProbe = MacDeviceProbe(clock: clock)
  }

  public func sample(
    commuteTarget: CommuteNetworkTarget?
  ) async -> (network: NetworkSnapshot, device: DeviceSafetySnapshot) {
    var network = await networkProbe.snapshot()
    let shouldConfirmInternet: Bool
    switch commuteTarget {
    case .wifiHotspot(let expectedSSID):
      shouldConfirmInternet =
        network.routeReachable
        && (network.ssid == nil || network.ssid == expectedSSID)
    case .usbTethering:
      shouldConfirmInternet =
        network.ssid == nil && network.interfaceName != nil && network.routeReachable
    case nil:
      shouldConfirmInternet = false
    }
    if shouldConfirmInternet {
      network = await networkProbe.snapshot(confirmInternet: true)
    }
    return (network, deviceProbe.snapshot())
  }
}
