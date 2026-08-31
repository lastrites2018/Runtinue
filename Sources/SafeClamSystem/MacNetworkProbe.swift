import CoreWLAN
import Foundation
import SafeClamCore
import SystemConfiguration

public struct MacNetworkProbe: Sendable {
  private let clock: any MonotonicTimeSource

  public init(clock: any MonotonicTimeSource = SystemUptimeClock()) {
    self.clock = clock
  }

  public func snapshot(confirmInternet: Bool = false) async -> NetworkSnapshot {
    let client = CWWiFiClient.shared()
    let wifiInterface =
      client.interface()
      ?? client.interfaceNames()?.first.flatMap {
        client.interface(withName: $0)
      }
    let route = Self.readDefaultRoute()
    let primaryInterface = route.interfaceName ?? wifiInterface?.interfaceName
    let ssid =
      primaryInterface == nil || primaryInterface == wifiInterface?.interfaceName
      ? wifiInterface?.ssid()
      : nil
    let routeReachable = Self.defaultRouteIsReachable()
    let internetReachability: InternetReachability
    if confirmInternet && routeReachable {
      internetReachability = await Self.confirmInternetReachability()
    } else {
      internetReachability = .unchecked
    }

    return NetworkSnapshot(
      ssid: ssid,
      interfaceName: primaryInterface,
      gateway: route.gateway,
      routeReachable: routeReachable,
      internetReachability: internetReachability,
      capturedAt: clock.now()
    )
  }

  private static func readDefaultRoute() -> (interfaceName: String?, gateway: String?) {
    guard
      let value = SCDynamicStoreCopyValue(
        nil,
        "State:/Network/Global/IPv4" as CFString
      ) as? [String: Any]
    else {
      return (nil, nil)
    }
    return (
      value["PrimaryInterface"] as? String,
      value["Router"] as? String
    )
  }

  private static func defaultRouteIsReachable() -> Bool {
    guard let reachability = SCNetworkReachabilityCreateWithName(nil, "captive.apple.com") else {
      return false
    }

    var flags = SCNetworkReachabilityFlags()
    guard SCNetworkReachabilityGetFlags(reachability, &flags) else {
      return false
    }

    return flags.contains(.reachable) && !flags.contains(.connectionRequired)
  }

  private static func confirmInternetReachability() async -> InternetReachability {
    guard let url = URL(string: "https://captive.apple.com/hotspot-detect.html") else {
      return .unavailable
    }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 5
    configuration.timeoutIntervalForResource = 5
    configuration.waitsForConnectivity = false
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }

    do {
      var request = URLRequest(url: url)
      request.cachePolicy = .reloadIgnoringLocalCacheData
      let (data, response) = try await session.data(for: request)
      guard
        InternetProbeResponseValidator.confirmsInternet(
          data: data,
          response: response,
          expectedURL: url
        )
      else {
        return .unavailable
      }
      return .confirmed
    } catch {
      return .unavailable
    }
  }
}

enum InternetProbeResponseValidator {
  static func confirmsInternet(
    data: Data,
    response: URLResponse,
    expectedURL: URL
  ) -> Bool {
    guard let httpResponse = response as? HTTPURLResponse,
      httpResponse.statusCode == 200,
      httpResponse.url?.scheme == expectedURL.scheme,
      httpResponse.url?.host?.caseInsensitiveCompare(expectedURL.host ?? "") == .orderedSame,
      httpResponse.url?.path == expectedURL.path,
      let body = String(data: data, encoding: .utf8),
      body.trimmingCharacters(in: .whitespacesAndNewlines) == "Success"
    else {
      return false
    }
    return true
  }
}
