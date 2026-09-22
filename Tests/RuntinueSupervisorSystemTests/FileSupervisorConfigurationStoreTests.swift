import Foundation
import XCTest

@testable import RuntinueSupervisorSystem

final class FileSupervisorConfigurationStoreTests: XCTestCase {
  func testSavePublishesOnlyAfterPrivateTemporaryFileIsReady() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "runtinue-configuration-store-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("config.json")
    let store = FileSupervisorConfigurationStore(fileURL: fileURL)
    let original = PersistedSupervisorConfiguration(
      adaptiveIdleGraceSeconds: 120,
      adaptiveHardCapSeconds: 3_600
    )
    try await store.save(original)
    let failingStore = FileSupervisorConfigurationStore(
      fileURL: fileURL,
      setTemporaryFilePermissions: { _, _ in -1 }
    )

    do {
      try await failingStore.save(
        PersistedSupervisorConfiguration(
          adaptiveIdleGraceSeconds: 300,
          adaptiveHardCapSeconds: 7_200
        )
      )
      XCTFail("expected temporary-file permission failure")
    } catch {
      // The original configuration must remain the only published file.
    }

    let loaded = try await store.load()
    XCTAssertEqual(loaded, original)
    let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    XCTAssertEqual(names, ["config.json"])
  }
}
