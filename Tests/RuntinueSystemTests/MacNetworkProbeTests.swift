import Foundation
import XCTest

@testable import RuntinueSystem

final class MacNetworkProbeTests: XCTestCase {
  private let expectedURL = URL(
    string: "https://captive.apple.com/hotspot-detect.html"
  )!

  func testAppleHTMLSuccessResponseConfirmsInternet() throws {
    let response = try XCTUnwrap(
      HTTPURLResponse(
        url: expectedURL,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "text/html"]
      )
    )
    let body = "<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>\n"

    XCTAssertTrue(
      InternetProbeResponseValidator.confirmsInternet(
        data: Data(body.utf8), response: response, expectedURL: expectedURL
      )
    )
  }

  func testHTMLWithSuccessAndSignInContentIsRejected() throws {
    let response = try XCTUnwrap(
      HTTPURLResponse(url: expectedURL, statusCode: 200, httpVersion: nil, headerFields: nil)
    )
    let body = "<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Sign in. Success</BODY></HTML>"

    XCTAssertFalse(
      InternetProbeResponseValidator.confirmsInternet(
        data: Data(body.utf8), response: response, expectedURL: expectedURL
      )
    )
  }

  func testExactSuccessResponseConfirmsInternet() throws {
    let response = try XCTUnwrap(
      HTTPURLResponse(
        url: expectedURL,
        statusCode: 200,
        httpVersion: nil,
        headerFields: nil
      )
    )

    XCTAssertTrue(
      InternetProbeResponseValidator.confirmsInternet(
        data: Data("Success\n".utf8),
        response: response,
        expectedURL: expectedURL
      )
    )
  }

  func testPortalPageContainingSuccessIsRejected() throws {
    let response = try XCTUnwrap(
      HTTPURLResponse(
        url: expectedURL,
        statusCode: 200,
        httpVersion: nil,
        headerFields: nil
      )
    )

    XCTAssertFalse(
      InternetProbeResponseValidator.confirmsInternet(
        data: Data("Sign in to continue. Success is one click away.".utf8),
        response: response,
        expectedURL: expectedURL
      )
    )
  }

  func testRedirectedSuccessResponseIsRejected() throws {
    let portalURL = try XCTUnwrap(URL(string: "https://login.example/portal"))
    let response = try XCTUnwrap(
      HTTPURLResponse(
        url: portalURL,
        statusCode: 200,
        httpVersion: nil,
        headerFields: nil
      )
    )

    XCTAssertFalse(
      InternetProbeResponseValidator.confirmsInternet(
        data: Data("Success\n".utf8),
        response: response,
        expectedURL: expectedURL
      )
    )
  }
}
