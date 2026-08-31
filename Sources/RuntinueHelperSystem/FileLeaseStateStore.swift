import Darwin
import Foundation
import RuntinueHelperCore

public enum FileLeaseStateStoreError: Error, CustomStringConvertible, Sendable {
  case invalidDirectory(String)
  case invalidOwnership(expected: UInt32, observed: UInt32)
  case invalidGroupOwnership(expected: UInt32, observed: UInt32)
  case insecurePermissions(UInt16)
  case invalidStateFile(String)
  case symbolicLink(String)
  case systemCall(name: String, code: Int32)

  public var description: String {
    switch self {
    case .invalidDirectory(let path):
      "invalid lease state directory: \(path)"
    case .invalidOwnership(let expected, let observed):
      "invalid owner, expected \(expected), observed \(observed)"
    case .invalidGroupOwnership(let expected, let observed):
      "invalid group, expected \(expected), observed \(observed)"
    case .insecurePermissions(let mode):
      "insecure permissions: \(String(mode, radix: 8))"
    case .invalidStateFile(let path):
      "invalid lease state file: \(path)"
    case .symbolicLink(let path):
      "symbolic links are not allowed: \(path)"
    case .systemCall(let name, let code):
      "\(name) failed with errno \(code)"
    }
  }
}

public actor FileLeaseStateStore: LeaseStateStore {
  public static let productionDirectory = URL(
    fileURLWithPath: "/Library/Application Support/io.github.lastrites2018.runtinue/helper",
    isDirectory: true
  )

  private let directoryURL: URL
  private let leaseURL: URL
  private let requiredOwnerUID: UInt32?
  private let requiredGroupGID: UInt32?
  private let fileManager: FileManager
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  public init(
    directoryURL: URL = FileLeaseStateStore.productionDirectory,
    requiredOwnerUID: UInt32? = 0,
    requiredGroupGID: UInt32? = 0
  ) {
    self.directoryURL = directoryURL
    self.leaseURL = directoryURL.appendingPathComponent("lease.json", isDirectory: false)
    self.requiredOwnerUID = requiredOwnerUID
    self.requiredGroupGID = requiredGroupGID
    self.fileManager = FileManager.default
    self.encoder = JSONEncoder()
    self.decoder = JSONDecoder()
    self.encoder.outputFormatting = [.sortedKeys]
    self.encoder.dateEncodingStrategy = .iso8601
    self.decoder.dateDecodingStrategy = .iso8601
  }

  public func load() async -> StoredLeaseLoadResult {
    do {
      try ensureSecureDirectory()
      guard try stateFileExistsAndIsSecure() else {
        return .absent
      }
      let data = try Data(contentsOf: leaseURL, options: [.uncached])
      return .valid(try decoder.decode(PersistedLease.self, from: data))
    } catch {
      return .corrupt(String(describing: error))
    }
  }

  public func save(_ lease: PersistedLease) async throws {
    try ensureSecureDirectory()
    _ = try stateFileExistsAndIsSecure()

    let data = try encoder.encode(lease)
    let temporaryURL = directoryURL.appendingPathComponent(
      ".lease.\(UUID().uuidString).tmp",
      isDirectory: false
    )
    let temporaryPath = temporaryURL.path
    let destinationPath = leaseURL.path
    let descriptor = Darwin.open(
      temporaryPath,
      O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
      S_IRUSR | S_IWUSR
    )
    guard descriptor >= 0 else {
      throw FileLeaseStateStoreError.systemCall(name: "open", code: errno)
    }

    var shouldRemoveTemporaryFile = true
    defer {
      Darwin.close(descriptor)
      if shouldRemoveTemporaryFile {
        Darwin.unlink(temporaryPath)
      }
    }

    guard Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
      throw FileLeaseStateStoreError.systemCall(name: "fchmod", code: errno)
    }
    let owner = requiredOwnerUID ?? UInt32.max
    let group = requiredGroupGID ?? UInt32.max
    guard Darwin.fchown(descriptor, owner, group) == 0 else {
      throw FileLeaseStateStoreError.systemCall(name: "fchown", code: errno)
    }

    try data.withUnsafeBytes { rawBuffer in
      guard let baseAddress = rawBuffer.baseAddress else {
        return
      }
      var offset = 0
      while offset < rawBuffer.count {
        let written = Darwin.write(
          descriptor,
          baseAddress.advanced(by: offset),
          rawBuffer.count - offset
        )
        guard written > 0 else {
          throw FileLeaseStateStoreError.systemCall(name: "write", code: errno)
        }
        offset += written
      }
    }

    guard Darwin.fsync(descriptor) == 0 else {
      throw FileLeaseStateStoreError.systemCall(name: "fsync", code: errno)
    }
    guard Darwin.rename(temporaryPath, destinationPath) == 0 else {
      throw FileLeaseStateStoreError.systemCall(name: "rename", code: errno)
    }
    shouldRemoveTemporaryFile = false
    try fsyncDirectory()
  }

  public func remove() async throws {
    try ensureSecureDirectory()
    guard try stateFileExistsAndIsSecure() else {
      return
    }
    guard Darwin.unlink(leaseURL.path) == 0 else {
      throw FileLeaseStateStoreError.systemCall(name: "unlink", code: errno)
    }
    try fsyncDirectory()
  }

  public func quarantineCorruptState() async throws {
    try ensureSecureDirectory()
    var info = stat()
    guard Darwin.lstat(leaseURL.path, &info) == 0 else {
      if errno == ENOENT {
        return
      }
      throw FileLeaseStateStoreError.systemCall(name: "lstat", code: errno)
    }
    guard info.st_mode & S_IFMT != S_IFDIR else {
      throw FileLeaseStateStoreError.invalidStateFile(leaseURL.path)
    }
    let quarantineURL = directoryURL.appendingPathComponent(
      "lease.corrupt.\(UUID().uuidString).json",
      isDirectory: false
    )
    guard Darwin.rename(leaseURL.path, quarantineURL.path) == 0 else {
      throw FileLeaseStateStoreError.systemCall(name: "rename", code: errno)
    }
    if info.st_mode & S_IFMT == S_IFREG {
      guard Darwin.chmod(quarantineURL.path, 0o600) == 0 else {
        throw FileLeaseStateStoreError.systemCall(name: "chmod", code: errno)
      }
      let owner = requiredOwnerUID ?? UInt32.max
      let group = requiredGroupGID ?? UInt32.max
      guard Darwin.chown(quarantineURL.path, owner, group) == 0 else {
        throw FileLeaseStateStoreError.systemCall(name: "chown", code: errno)
      }
    }
    try fsyncDirectory()
  }

  private func ensureSecureDirectory() throws {
    if !fileManager.fileExists(atPath: directoryURL.path) {
      try fileManager.createDirectory(
        at: directoryURL,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
      let owner = requiredOwnerUID ?? UInt32.max
      let group = requiredGroupGID ?? UInt32.max
      guard Darwin.chown(directoryURL.path, owner, group) == 0 else {
        throw FileLeaseStateStoreError.systemCall(name: "chown", code: errno)
      }
    }

    var info = stat()
    guard Darwin.lstat(directoryURL.path, &info) == 0 else {
      throw FileLeaseStateStoreError.systemCall(name: "lstat", code: errno)
    }
    guard info.st_mode & S_IFMT == S_IFDIR else {
      throw FileLeaseStateStoreError.invalidDirectory(directoryURL.path)
    }
    let permissions = UInt16(info.st_mode & 0o777)
    guard permissions == 0o700 else {
      throw FileLeaseStateStoreError.insecurePermissions(permissions)
    }
    if let requiredOwnerUID, info.st_uid != requiredOwnerUID {
      throw FileLeaseStateStoreError.invalidOwnership(
        expected: requiredOwnerUID,
        observed: info.st_uid
      )
    }
    if let requiredGroupGID, info.st_gid != requiredGroupGID {
      throw FileLeaseStateStoreError.invalidGroupOwnership(
        expected: requiredGroupGID,
        observed: info.st_gid
      )
    }
  }

  private func stateFileExistsAndIsSecure() throws -> Bool {
    var info = stat()
    guard Darwin.lstat(leaseURL.path, &info) == 0 else {
      if errno == ENOENT {
        return false
      }
      throw FileLeaseStateStoreError.systemCall(name: "lstat", code: errno)
    }
    guard info.st_mode & S_IFMT != S_IFLNK else {
      throw FileLeaseStateStoreError.symbolicLink(leaseURL.path)
    }
    guard info.st_mode & S_IFMT == S_IFREG else {
      throw FileLeaseStateStoreError.invalidStateFile(leaseURL.path)
    }
    let permissions = UInt16(info.st_mode & 0o777)
    guard permissions == 0o600 else {
      throw FileLeaseStateStoreError.insecurePermissions(permissions)
    }
    if let requiredOwnerUID, info.st_uid != requiredOwnerUID {
      throw FileLeaseStateStoreError.invalidOwnership(
        expected: requiredOwnerUID,
        observed: info.st_uid
      )
    }
    if let requiredGroupGID, info.st_gid != requiredGroupGID {
      throw FileLeaseStateStoreError.invalidGroupOwnership(
        expected: requiredGroupGID,
        observed: info.st_gid
      )
    }
    return true
  }

  private func fsyncDirectory() throws {
    let descriptor = Darwin.open(directoryURL.path, O_RDONLY | O_DIRECTORY)
    guard descriptor >= 0 else {
      throw FileLeaseStateStoreError.systemCall(name: "open directory", code: errno)
    }
    defer { Darwin.close(descriptor) }
    guard Darwin.fsync(descriptor) == 0 else {
      throw FileLeaseStateStoreError.systemCall(name: "fsync directory", code: errno)
    }
  }
}
