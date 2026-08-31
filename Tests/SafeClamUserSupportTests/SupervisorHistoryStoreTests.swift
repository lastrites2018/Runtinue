import Foundation
import XCTest

@testable import SafeClamIPC
@testable import SafeClamUserSupport

@MainActor
final class SupervisorHistoryStoreTests: XCTestCase {
  func testHistoryRetainsTypedStopReasonWithoutPersistingFreeFormDetail() throws {
    let status = SupervisorStatusWire(
      phase: .ended,
      mode: .none,
      sessionID: UUID(),
      verdict: .unsafe,
      remainingSeconds: nil,
      batteryPercent: nil,
      thermalLevel: nil,
      lidState: nil,
      stopReason: .safety,
      detail: "private-session-name / private-network-name",
      updatedAt: Date()
    )
    let data = try JSONEncoder().encode(SupervisorHistoryEntry(status: status))
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(object["stopReason"] as? String, "safety")
    XCTAssertNil(object["detail"])
    XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private-"))
  }

  func testProductionURLMatchesDocumentedUserStateLocation() {
    let expected = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/SafeClam", isDirectory: true)
      .appendingPathComponent("history.jsonl", isDirectory: false)
    XCTAssertEqual(FileSupervisorHistoryStore.productionURL, expected)
  }

  func testLegacyHistoryDoesNotExposeOrRewriteFreeFormDetail() throws {
    let original = SupervisorHistoryEntry(
      version: 1, status: status(verdict: .inactive, detail: nil))
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any]
    )
    object["detail"] = "legacy-private-session"
    let decoded = try JSONDecoder().decode(
      SupervisorHistoryEntry.self, from: JSONSerialization.data(withJSONObject: object)
    )
    XCTAssertNil(decoded.detail)
    let rewritten = try JSONEncoder().encode(decoded)
    XCTAssertFalse(String(decoding: rewritten, as: UTF8.self).contains("legacy-private-session"))
  }

  func testHistoryIsPrivateDeduplicatedAndBounded() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "safeclam-history-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("history.jsonl")
    let store = FileSupervisorHistoryStore(
      fileURL: fileURL,
      maximumEntries: 2
    )

    let inactive = status(verdict: .inactive, detail: nil)
    try await store.record(inactive)
    try await store.record(inactive)
    try await store.record(status(verdict: .acquiring, detail: nil))
    try await store.record(status(verdict: .unsafe, detail: "thermal"))

    let entries = try await store.recent(limit: 10)
    XCTAssertEqual(entries.map(\.verdict), [.acquiring, .unsafe])
    XCTAssertNil(entries.last?.detail)

    let fileAttributes = try FileManager.default.attributesOfItem(
      atPath: fileURL.path
    )
    XCTAssertEqual(
      (fileAttributes[.posixPermissions] as? NSNumber)?.intValue,
      0o600
    )
    let directoryAttributes = try FileManager.default.attributesOfItem(
      atPath: directory.path
    )
    XCTAssertEqual(
      (directoryAttributes[.posixPermissions] as? NSNumber)?.intValue,
      0o700
    )
  }

  func testMalformedLineDoesNotBecomeTrustedHistory() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "safeclam-history-corrupt-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let fileURL = directory.appendingPathComponent("history.jsonl")
    try Data("not-json\n".utf8).write(to: fileURL)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: fileURL.path
    )
    let store = FileSupervisorHistoryStore(fileURL: fileURL)

    let entries = try await store.recent(limit: 10)
    XCTAssertEqual(entries, [])
  }
}

private func status(
  verdict: WireProtectionVerdict,
  detail: String?
) -> SupervisorStatusWire {
  SupervisorStatusWire(
    phase: verdict == .inactive ? .idle : .active,
    mode: verdict == .inactive ? .none : .trip,
    sessionID: verdict == .inactive ? nil : UUID(),
    verdict: verdict,
    closedLidAllowed: verdict == .protected,
    remainingSeconds: verdict == .protected ? 600 : nil,
    batteryPercent: 80,
    thermalLevel: "nominal",
    lidState: "open",
    detail: detail,
    updatedAt: Date(timeIntervalSince1970: 1)
  )
}
