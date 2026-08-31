import Darwin
import Foundation
import SafeClamIPC

public actor FileSupervisorStatusCache: SupervisorStatusCaching {
  public static var productionURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/SafeClam", isDirectory: true)
      .appendingPathComponent("session.json", isDirectory: false)
  }

  private let fileURL: URL

  public init(fileURL: URL = FileSupervisorStatusCache.productionURL) {
    self.fileURL = fileURL
  }

  public func save(_ status: SupervisorStatusWire) throws {
    try prepareDirectory()
    try rejectSymlink(at: fileURL)
    let data = try JSONEncoder().encode(status)
    try data.write(to: fileURL, options: [.atomic])
    guard chmod(fileURL.path, 0o600) == 0 else {
      throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
  }

  public func load() throws -> SupervisorStatusWire? {
    try prepareDirectory()
    try rejectSymlink(at: fileURL)
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      return nil
    }
    let data = try Data(contentsOf: fileURL, options: [.uncached])
    return try JSONDecoder().decode(SupervisorStatusWire.self, from: data)
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
