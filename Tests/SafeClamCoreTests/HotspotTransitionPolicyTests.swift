import XCTest

@testable import SafeClamCore

final class HotspotTransitionPolicyTests: XCTestCase {
  private let policy = HotspotTransitionPolicy(expectedSSID: "Jaewan iPhone")

  func testTargetHotspotWithReachableRouteAndChangedSSIDIsReady() {
    let origin = network(ssid: "Office", at: instant(seconds: 10))
    let current = network(ssid: "Jaewan iPhone", at: instant(seconds: 20))

    XCTAssertEqual(
      policy.evaluate(origin: origin, current: current, at: instant(seconds: 20)),
      .ready
    )
  }

  func testTargetSSIDWithoutReachableRouteIsNotReady() {
    let origin = network(ssid: "Office", at: instant(seconds: 10))
    let current = network(
      ssid: "Jaewan iPhone",
      at: instant(seconds: 20),
      reachable: false
    )

    XCTAssertEqual(
      policy.evaluate(origin: origin, current: current, at: instant(seconds: 20)),
      .waiting(.routeUnavailable)
    )
  }

  func testSameNetworkDoesNotCountAsHandoff() {
    let origin = network(ssid: "Jaewan iPhone", at: instant(seconds: 10))
    let current = network(ssid: "Jaewan iPhone", at: instant(seconds: 20))

    XCTAssertEqual(
      policy.evaluate(origin: origin, current: current, at: instant(seconds: 20)),
      .waiting(.networkIdentityUnchanged)
    )
  }

  func testUnknownSSIDDoesNotFallBackToRouteOnly() {
    let origin = network(ssid: "Office", at: instant(seconds: 10))
    let current = network(ssid: nil, at: instant(seconds: 20))

    XCTAssertEqual(
      policy.evaluate(origin: origin, current: current, at: instant(seconds: 20)),
      .waiting(.ssidUnavailable)
    )
  }

  func testTargetHotspotWithoutConfirmedInternetIsNotReady() {
    let origin = network(ssid: "Office", at: instant(seconds: 10))
    let current = network(
      ssid: "Jaewan iPhone",
      at: instant(seconds: 20),
      internet: .unavailable
    )

    XCTAssertEqual(
      policy.evaluate(origin: origin, current: current, at: instant(seconds: 20)),
      .waiting(.internetUnavailable)
    )
  }

  func testGatewayChangeCountsAsNetworkIdentityChange() {
    let now = instant(seconds: 100)
    let origin = network(
      ssid: "iPhone",
      at: now,
      gateway: "192.168.1.1"
    )
    let current = network(
      ssid: "iPhone",
      at: now,
      gateway: "172.20.10.1"
    )

    XCTAssertEqual(
      HotspotTransitionPolicy(expectedSSID: "iPhone").evaluate(
        origin: origin,
        current: current,
        at: now
      ),
      .ready
    )
  }

  func testUnknownOriginIdentityDoesNotCountAsHandoff() {
    let now = MonotonicInstant(uptimeNanoseconds: 100)
    let policy = HotspotTransitionPolicy(expectedSSID: "iPhone")
    let origin = NetworkSnapshot(
      ssid: nil,
      interfaceName: nil,
      gateway: nil,
      routeReachable: true,
      capturedAt: now
    )
    let current = NetworkSnapshot(
      ssid: "iPhone",
      interfaceName: "en0",
      gateway: nil,
      routeReachable: true,
      internetReachability: .confirmed,
      capturedAt: now
    )

    XCTAssertEqual(
      policy.evaluate(origin: origin, current: current, at: now),
      .waiting(.networkIdentityUnchanged)
    )
  }

  func testUSBTetheringRequiresChangedNonWiFiInterfaceAndInternet() {
    let now = instant(seconds: 100)
    let origin = network(
      ssid: "Office",
      at: now,
      interface: "en0",
      gateway: "192.168.1.1"
    )
    let current = network(
      ssid: nil,
      at: now,
      interface: "en5",
      gateway: "172.20.10.1"
    )

    XCTAssertEqual(
      HotspotTransitionPolicy(target: .usbTethering).evaluate(
        origin: origin,
        current: current,
        at: now
      ),
      .ready
    )
  }

  func testUSBTetheringDoesNotAcceptUnchangedInterface() {
    let now = instant(seconds: 100)
    let origin = network(ssid: nil, at: now, interface: "en5")
    let current = network(ssid: nil, at: now, interface: "en5")

    XCTAssertEqual(
      HotspotTransitionPolicy(target: .usbTethering).evaluate(
        origin: origin,
        current: current,
        at: now
      ),
      .waiting(.networkIdentityUnchanged)
    )
  }

  func testUSBTetheringRequiresKnownOriginInterface() {
    let now = MonotonicInstant(uptimeNanoseconds: 100)
    let policy = HotspotTransitionPolicy(target: .usbTethering)
    let origin = NetworkSnapshot(
      ssid: nil,
      interfaceName: nil,
      routeReachable: true,
      capturedAt: now
    )
    let current = NetworkSnapshot(
      ssid: nil,
      interfaceName: "bridge100",
      routeReachable: true,
      internetReachability: .confirmed,
      capturedAt: now
    )

    XCTAssertEqual(
      policy.evaluate(origin: origin, current: current, at: now),
      .waiting(.interfaceUnavailable)
    )
  }
}
