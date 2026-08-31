import Darwin
import Foundation
import XCTest

@testable import RuntinueActivity

final class ActivityDetectorsTests: XCTestCase {
  func testTranscriptOnlySignalsAfterObservedFileChanges() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "runtinue-transcript-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    let file = directory.appendingPathComponent("transcript.jsonl")
    try Data("first\n".utf8).write(to: file)
    var detector = TranscriptActivityDetector(path: file.path)

    XCTAssertEqual(detector.poll(), .baseline)
    XCTAssertEqual(detector.poll(), .unchanged)

    try Data("first\nsecond\n".utf8).write(to: file)
    XCTAssertEqual(detector.poll(), .activity)
    XCTAssertEqual(detector.poll(), .unchanged)
  }

  func testTranscriptRejectsSymbolicLink() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "runtinue-transcript-link-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let target = directory.appendingPathComponent("target")
    let link = directory.appendingPathComponent("link")
    try Data().write(to: target)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

    var detector = TranscriptActivityDetector(path: link.path)
    XCTAssertEqual(detector.poll(), .unavailable)
  }

  func testProcessDetectorSeesCurrentProcessAndRejectsInvalidPID() {
    XCTAssertTrue(ProcessActivityDetector(processID: getpid()).isRunning())
    XCTAssertFalse(ProcessActivityDetector(processID: 0).isRunning())
  }

  func testRemoteDetectorUsesExplicitSessionMarkers() {
    let detector = RemoteSessionDetector()
    XCTAssertTrue(detector.isActive(environment: ["SSH_CONNECTION": "client server"]))
    XCTAssertTrue(detector.isActive(environment: ["MOSH_CONNECTION": "client server"]))
    XCTAssertFalse(detector.isActive(environment: ["SSH_CONNECTION": "  "]))
    XCTAssertFalse(detector.isActive(environment: [:]))
  }
}
