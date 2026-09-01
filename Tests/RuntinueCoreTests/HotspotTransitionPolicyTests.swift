import XCTest

@testable import RuntinueCore

final class HotspotTransitionPolicyTests: XCTestCase {
  private let policy = HotspotTransitionPolicy(expectedSSID: "Jaewan iPhone")

  func testReadinessModeRejectsMissingSSIDWrongSSIDRouteAndStaleSamples() {
    let now = instant(seconds: 100)
    let readiness = HotspotTransitionPolicy(
      expectedSSID: "iPhone", requireNetworkIdentityChange: false
    )
    let origin = network(ssid: "iPhone", at: now)
    let cases: [(NetworkSnapshot, HotspotWaitingReason)] = [
      (network(ssid: nil, at: now), .ssidUnavailable),
      (network(ssid: "Office", at: now), .unexpectedSSID(observed: "Office")),
      (network(ssid: "iPhone", at: now, reachable: false), .routeUnavailable),
      (network(ssid: "iPhone", at: instant(seconds: 84)), .staleSnapshot(age: .seconds(16))),
      (network(ssid: "iPhone", at: instant(seconds: 101)), .snapshotFromFuture),
    ]
    for (current, expected) in cases {
      XCTAssertEqual(readiness.evaluate(origin: origin, current: current, at: now), .waiting(expected))
    }
  }

  func testReadinessModeRequiresAKnownCurrentInterface() {
    let now = instant(seconds: 100)
    let current = NetworkSnapshot(
      ssid: "iPhone",
      interfaceName: nil,
      routeReachable: true,
      internetReachability: .confirmed,
      capturedAt: now
    )
    let readiness = HotspotTransitionPolicy(
      expectedSSID: "iPhone", requireNetworkIdentityChange: false
    )

    XCTAssertEqual(
      readiness.evaluate(origin: current, current: current, at: now),
      .waiting(.interfaceUnavailable)
    )
  }

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
    let now = MonotonicInstant(continuousNanoseconds: 100)
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
    let now = MonotonicInstant(continuousNanoseconds: 100)
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
