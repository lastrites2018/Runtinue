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
      .appendingPathComponent("Library/Application Support/SafeClam", isDirectory: true)
      .appendingPathComponent("config.json", isDirectory: false)
  }

  private let fileURL: URL

  public init(fileURL: URL = FileSupervisorConfigurationStore.productionURL) {
    self.fileURL = fileURL
  }

  public func save(_ configuration: PersistedSupervisorConfiguration) throws {
    try prepareDirectory()
    try rejectSymlink(at: fileURL)
    let data = try JSONEncoder().encode(configuration)
    try data.write(to: fileURL, options: [.atomic])
    guard chmod(fileURL.path, 0o600) == 0 else {
      throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
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
