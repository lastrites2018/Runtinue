import Darwin
import Foundation

public struct PersistedSupervisorConfiguration: Codable, Equatable, Sendable {
  public static let currentVersion = 1

  public let version: Int
  public let adaptiveIdleGraceSeconds: Double?
  public let adaptiveHardCapSeconds: Double?
  public let deskAllowClosedLid: Bool?
  public let deskHardCapSeconds: Double?

  public init(
    version: Int = Self.currentVersion,
    adaptiveIdleGraceSeconds: Double?,
    adaptiveHardCapSeconds: Double?,
    deskAllowClosedLid: Bool? = nil,
    deskHardCapSeconds: Double? = nil
  ) {
    self.version = version
    self.adaptiveIdleGraceSeconds = adaptiveIdleGraceSeconds
    self.adaptiveHardCapSeconds = adaptiveHardCapSeconds
    self.deskAllowClosedLid = deskAllowClosedLid
    self.deskHardCapSeconds = deskHardCapSeconds
  }
}

public protocol SupervisorConfigurationCaching: Sendable {
  func save(_ configuration: PersistedSupervisorConfiguration) async throws
  func load() async throws -> PersistedSupervisorConfiguration?
  func remove() async throws
}

public actor FileSupervisorConfigurationStore: SupervisorConfigurationCaching {
  public static var productionURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Runtinue", isDirectory: true)
      .appendingPathComponent("config.json", isDirectory: false)
  }

  private let fileURL: URL
  private let setTemporaryFilePermissions: @Sendable (Int32, mode_t) -> Int32

  public init(fileURL: URL = FileSupervisorConfigurationStore.productionURL) {
    self.fileURL = fileURL
    self.setTemporaryFilePermissions = { descriptor, permissions in
      Darwin.fchmod(descriptor, permissions)
    }
  }

  init(
    fileURL: URL,
    setTemporaryFilePermissions: @escaping @Sendable (Int32, mode_t) -> Int32
  ) {
    self.fileURL = fileURL
    self.setTemporaryFilePermissions = setTemporaryFilePermissions
  }

  public func save(_ configuration: PersistedSupervisorConfiguration) throws {
    try prepareDirectory()
    try rejectSymlink(at: fileURL)
    let data = try JSONEncoder().encode(configuration)
    let temporaryURL = fileURL.deletingLastPathComponent().appendingPathComponent(
      ".config.\(UUID().uuidString).tmp",
      isDirectory: false
    )
    let temporaryPath = temporaryURL.path
    let descriptor = Darwin.open(
      temporaryPath,
      O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
      S_IRUSR | S_IWUSR
    )
    guard descriptor >= 0 else {
      throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
    var shouldRemoveTemporaryFile = true
    defer {
      Darwin.close(descriptor)
      if shouldRemoveTemporaryFile {
        Darwin.unlink(temporaryPath)
      }
    }
    guard setTemporaryFilePermissions(descriptor, S_IRUSR | S_IWUSR) == 0 else {
      throw POSIXError(.init(rawValue: errno) ?? .EIO)
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
        if written < 0, errno == EINTR {
          continue
        }
        guard written > 0 else {
          throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        offset += written
      }
    }
    guard Darwin.fsync(descriptor) == 0 else {
      throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
    guard Darwin.rename(temporaryPath, fileURL.path) == 0 else {
      throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
    shouldRemoveTemporaryFile = false
  }

  public func load() throws -> PersistedSupervisorConfiguration? {
    try prepareDirectory()
    try rejectSymlink(at: fileURL)
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      return nil
    }
    let data = try Data(contentsOf: fileURL, options: [.uncached])
    let decoded = try JSONDecoder().decode(
      PersistedSupervisorConfiguration.self,
      from: data
    )
    guard decoded.version == PersistedSupervisorConfiguration.currentVersion else {
      throw CocoaError(.fileReadCorruptFile)
    }
    return decoded
  }

  public func remove() throws {
    try prepareDirectory()
    try rejectSymlink(at: fileURL)
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      return
    }
    try FileManager.default.removeItem(at: fileURL)
  }

  private func prepareDirectory() throws {
    let directory = fileURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try rejectSymlink(at: directory)
    guard chmod(directory.path, 0o700) == 0 else {
      throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
  }

  private func rejectSymlink(at url: URL) throws {
    var info = stat()
    guard lstat(url.path, &info) == 0 else {
      if errno == ENOENT {
        return
      }
      throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
    guard info.st_mode & S_IFMT != S_IFLNK else {
      throw CocoaError(.fileReadInvalidFileName)
    }
  }
}
