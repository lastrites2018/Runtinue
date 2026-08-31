import Darwin
import Foundation
import XCTest

@testable import SafeClamHelperCore
@testable import SafeClamHelperSystem

@MainActor
final class FileLeaseStateStoreTests: XCTestCase {
  func testRoundTripUsesPrivateFilePermissionsAndRemove() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = FileLeaseStateStore(
      directoryURL: directory,
      requiredOwnerUID: nil,
      requiredGroupGID: nil
    )
    let lease = persistedLeaseForStore()

    try await store.save(lease)

    let loaded = await store.load()
    XCTAssertEqual(loaded, .valid(lease))
    let leaseURL = directory.appendingPathComponent("lease.json")
    let attributes = try FileManager.default.attributesOfItem(atPath: leaseURL.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

    try await store.remove()
    let removed = await store.load()
    XCTAssertEqual(removed, .absent)
  }

  func testCorruptStateCanBeQuarantined() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let leaseURL = directory.appendingPathComponent("lease.json")
    try Data("not-json".utf8).write(to: leaseURL)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: leaseURL.path
    )
    let store = FileLeaseStateStore(
      directoryURL: directory,
      requiredOwnerUID: nil,
      requiredGroupGID: nil
    )

    guard case .corrupt = await store.load() else {
      return XCTFail("expected corrupt state")
    }
    try await store.quarantineCorruptState()

    let afterQuarantine = await store.load()
    XCTAssertEqual(afterQuarantine, .absent)
    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    XCTAssertEqual(names.filter { $0.hasPrefix("lease.corrupt.") }.count, 1)
  }

  func testSymbolicLinkLeaseIsRejected() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let target = directory.appendingPathComponent("target.json")
    try Data("{}".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(
      at: directory.appendingPathComponent("lease.json"),
      withDestinationURL: target
    )
    let store = FileLeaseStateStore(
      directoryURL: directory,
      requiredOwnerUID: nil,
      requiredGroupGID: nil
    )

    guard case .corrupt(let detail) = await store.load() else {
      return XCTFail("expected symbolic link rejection")
    }
    XCTAssertTrue(detail.contains("symbolic links are not allowed"))
  }

  func testGroupWritableDirectoryIsRejected() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o770]
    )
    chmod(directory.path, 0o770)
    let store = FileLeaseStateStore(
      directoryURL: directory,
      requiredOwnerUID: nil,
      requiredGroupGID: nil
    )

    guard case .corrupt(let detail) = await store.load() else {
      return XCTFail("expected insecure permission rejection")
    }
    XCTAssertTrue(detail.contains("insecure permissions"))
  }

  func testDirectoryPermissionsMustBeExactlyPrivateAndSearchable() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: directory.path
    )
    let store = FileLeaseStateStore(
      directoryURL: directory,
      requiredOwnerUID: nil,
      requiredGroupGID: nil
    )

    let result = await store.load()

    guard case .corrupt(let detail) = result else {
      return XCTFail("expected insecure directory to be rejected")
    }
    XCTAssertTrue(detail.contains("insecure permissions"))
  }

  func testInsecureExistingLeasePermissionsAreRejected() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = FileLeaseStateStore(
      directoryURL: directory,
      requiredOwnerUID: nil,
      requiredGroupGID: nil
    )
    try await store.save(persistedLeaseForStore())
    let leaseURL = directory.appendingPathComponent("lease.json")
    chmod(leaseURL.path, 0o644)

    guard case .corrupt(let detail) = await store.load() else {
      return XCTFail("expected insecure file permission rejection")
    }
    XCTAssertTrue(detail.contains("insecure permissions"))
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "safeclam-store-tests-\(UUID().uuidString)",
      isDirectory: true
    )
  }
}

private func persistedLeaseForStore() -> PersistedLease {
  let now = Date(timeIntervalSince1970: 2_000)
  return PersistedLease(
    leaseID: UUID(),
    ownerUID: 501,
    createdAt: now,
    hardDeadline: now.addingTimeInterval(7_200),
    rollbackBaseline: .normal,
    reason: "commute",
    phase: .active,
    lastRenewedAt: now,
    ttlExpiresAt: now.addingTimeInterval(90)
  )
}
