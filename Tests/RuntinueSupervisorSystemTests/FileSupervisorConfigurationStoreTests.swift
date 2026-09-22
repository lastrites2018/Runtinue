import Darwin
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

  func testRemoveDurablyClearsPublishedConfiguration() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "runtinue-configuration-remove-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("config.json")
    let store = FileSupervisorConfigurationStore(fileURL: fileURL)
    try await store.save(
      PersistedSupervisorConfiguration(
        adaptiveIdleGraceSeconds: 120,
        adaptiveHardCapSeconds: 3_600
      )
    )

    try await store.remove()

    let loaded = try await store.load()
    XCTAssertNil(loaded)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
  }

  func testSaveRetriesInterruptedDirectorySyncAfterPublishingCompleteBytes() async throws {
    let directory = temporaryDirectory(named: "save-sync")
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("config.json")
    let recorder = DirectorySyncRecorder(
      fileURL: fileURL,
      outcomes: [.failure(EINTR), .success]
    )
    let store = instrumentedStore(fileURL: fileURL, recorder: recorder)
    let expected = PersistedSupervisorConfiguration(
      adaptiveIdleGraceSeconds: 120,
      adaptiveHardCapSeconds: 3_600
    )

    try await store.save(expected)

    let observations = recorder.snapshot()
    XCTAssertEqual(observations.count, 2)
    XCTAssertEqual(observations.map(\.configuration), [expected, expected])
    XCTAssertEqual(observations.map(\.names), [["config.json"], ["config.json"]])
  }

  func testSaveReportsPostRenameDirectorySyncFailureWithoutLeavingATemporaryFile() async throws {
    let directory = temporaryDirectory(named: "save-sync-failure")
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("config.json")
    let originalStore = FileSupervisorConfigurationStore(fileURL: fileURL)
    let original = PersistedSupervisorConfiguration(
      adaptiveIdleGraceSeconds: 120,
      adaptiveHardCapSeconds: 3_600
    )
    let replacement = PersistedSupervisorConfiguration(
      adaptiveIdleGraceSeconds: 300,
      adaptiveHardCapSeconds: 7_200
    )
    try await originalStore.save(original)
    let recorder = DirectorySyncRecorder(fileURL: fileURL, outcomes: [.failure(EIO)])
    let failingStore = instrumentedStore(fileURL: fileURL, recorder: recorder)

    do {
      try await failingStore.save(replacement)
      XCTFail("expected post-rename directory sync failure")
    } catch {
      // A visible rename with unconfirmed directory durability is reported as
      // ambiguous so SupervisorRuntime can persist a disabled tombstone.
    }

    let visibleConfiguration = try await originalStore.load()
    XCTAssertEqual(visibleConfiguration, replacement)
    XCTAssertEqual(recorder.snapshot().map(\.configuration), [replacement])
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: directory.path),
      ["config.json"]
    )
  }

  func testRemoveRetriesDirectorySyncEvenWhenTheEntryIsAlreadyAbsent() async throws {
    let directory = temporaryDirectory(named: "remove-sync-failure")
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("config.json")
    let originalStore = FileSupervisorConfigurationStore(fileURL: fileURL)
    try await originalStore.save(
      PersistedSupervisorConfiguration(
        adaptiveIdleGraceSeconds: 120,
        adaptiveHardCapSeconds: 3_600
      )
    )
    let recorder = DirectorySyncRecorder(
      fileURL: fileURL,
      outcomes: [.failure(EIO), .success]
    )
    let store = instrumentedStore(fileURL: fileURL, recorder: recorder)

    do {
      try await store.remove()
      XCTFail("expected post-unlink directory sync failure")
    } catch {
      // unlink succeeded, but durable absence was not yet confirmed.
    }
    try await store.remove()

    let observations = recorder.snapshot()
    XCTAssertEqual(observations.count, 2)
    XCTAssertEqual(observations.map(\.fileExists), [false, false])
    XCTAssertEqual(observations.map(\.names), [[], []])
  }

  func testRemovingAnInitiallyAbsentConfigurationStillSyncsTheDirectory() async throws {
    let directory = temporaryDirectory(named: "remove-absent")
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("config.json")
    let recorder = DirectorySyncRecorder(fileURL: fileURL, outcomes: [.success])
    let store = instrumentedStore(fileURL: fileURL, recorder: recorder)

    try await store.remove()

    let observations = recorder.snapshot()
    XCTAssertEqual(observations.count, 1)
    XCTAssertFalse(observations[0].fileExists)
    XCTAssertEqual(observations[0].names, [])
  }

  private func temporaryDirectory(named name: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "runtinue-configuration-\(name)-\(UUID().uuidString)",
      isDirectory: true
    )
  }

  private func instrumentedStore(
    fileURL: URL,
    recorder: DirectorySyncRecorder
  ) -> FileSupervisorConfigurationStore {
    FileSupervisorConfigurationStore(
      fileURL: fileURL,
      setTemporaryFilePermissions: { descriptor, permissions in
        Darwin.fchmod(descriptor, permissions)
      },
      synchronizeDirectoryDescriptor: { descriptor in
        recorder.synchronize(descriptor)
      }
    )
  }
}

private final class DirectorySyncRecorder: @unchecked Sendable {
  enum Outcome {
    case success
    case failure(Int32)
  }

  struct Observation {
    let fileExists: Bool
    let configuration: PersistedSupervisorConfiguration?
    let names: [String]
  }

  private let fileURL: URL
  private let lock = NSLock()
  private var outcomes: [Outcome]
  private var observations: [Observation] = []

  init(fileURL: URL, outcomes: [Outcome]) {
    self.fileURL = fileURL
    self.outcomes = outcomes
  }

  func synchronize(_ descriptor: Int32) -> Int32 {
    let data = try? Data(contentsOf: fileURL)
    let configuration = data.flatMap {
      try? JSONDecoder().decode(PersistedSupervisorConfiguration.self, from: $0)
    }
    let names =
      (try? FileManager.default.contentsOfDirectory(
        atPath: fileURL.deletingLastPathComponent().path
      ).sorted()) ?? []
    lock.lock()
    observations.append(
      Observation(
        fileExists: FileManager.default.fileExists(atPath: fileURL.path),
        configuration: configuration,
        names: names
      )
    )
    let outcome = outcomes.isEmpty ? .success : outcomes.removeFirst()
    lock.unlock()
    switch outcome {
    case .success:
      return 0
    case .failure(let code):
      errno = code
      return -1
    }
  }

  func snapshot() -> [Observation] {
    lock.lock()
    defer { lock.unlock() }
    return observations
  }
}
