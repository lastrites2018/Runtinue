import Darwin
import Foundation
import RuntinueIPC

public struct SupervisorHistoryEntry: Codable, Equatable, Sendable {
  public static let currentVersion = 2

  public let version: Int
  public let id: UUID
  public let recordedAt: Date
  public let mode: WireSessionMode
  public let phase: WireTripPhase
  public let sessionID: UUID?
  public let verdict: WireProtectionVerdict
  public let closedLidAllowed: Bool
  public let remainingSeconds: Double?
  public let batteryPercent: Int?
  public let thermalLevel: String?
  public let lidState: String?
  public let stopReason: WireSessionStopReason?
  public let buildID: String?
  public var detail: String? { nil }

  public init(
    version: Int = Self.currentVersion,
    id: UUID = UUID(),
    recordedAt: Date = Date(),
    status: SupervisorStatusWire
  ) {
    self.version = version
    self.id = id
    self.recordedAt = recordedAt
    mode = status.mode
    phase = status.phase
    sessionID = status.sessionID
    verdict = status.verdict
    closedLidAllowed = status.closedLidAllowed
    remainingSeconds = status.remainingSeconds
    batteryPercent = status.batteryPercent
    thermalLevel = status.thermalLevel
    lidState = status.lidState
    stopReason = status.stopReason
    buildID = ExecutableBuildIdentity.validated(status.observation?.buildID)
  }
}

public protocol SupervisorHistoryRecording: Sendable {
  func record(_ status: SupervisorStatusWire) async throws
}

public actor FileSupervisorHistoryStore: SupervisorHistoryRecording {
  public static var productionURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Runtinue", isDirectory: true)
      .appendingPathComponent("history.jsonl", isDirectory: false)
  }

  private let fileURL: URL
  private let maximumEntries: Int

  public init(
    fileURL: URL = FileSupervisorHistoryStore.productionURL,
    maximumEntries: Int = 1_000
  ) {
    self.fileURL = fileURL
    self.maximumEntries = max(1, maximumEntries)
  }

  public func record(_ status: SupervisorStatusWire) throws {
    var entries = try loadAll()
    let entry = SupervisorHistoryEntry(status: status)
    if let last = entries.last, last.version == SupervisorHistoryEntry.currentVersion,
      last.signature == entry.signature
    {
      return
    }
    entries.append(entry)
    if entries.count > maximumEntries {
      entries = Array(entries.suffix(maximumEntries))
    }
    try save(entries)
  }

  public func recent(limit: Int = 50) throws -> [SupervisorHistoryEntry] {
    guard limit > 0 else {
      return []
    }
    return Array(try loadAll().suffix(min(limit, maximumEntries)))
  }

  private func loadAll() throws -> [SupervisorHistoryEntry] {
    try prepareDirectory()
    try validateFileIfPresent()
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      return []
    }
    let data = try Data(contentsOf: fileURL, options: [.uncached])
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return data.split(separator: 0x0A).compactMap { line in
      guard
        let entry = try? decoder.decode(
          SupervisorHistoryEntry.self,
          from: Data(line)
        ),
        entry.version == 1 || entry.version == SupervisorHistoryEntry.currentVersion
      else {
        return nil
      }
      return entry
    }
  }

  private func save(_ entries: [SupervisorHistoryEntry]) throws {
    var output = Data()
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    for entry in entries {
      output.append(try encoder.encode(entry))
      output.append(0x0A)
    }
    try output.write(to: fileURL, options: [.atomic])
    guard chmod(fileURL.path, 0o600) == 0 else {
      throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
    try validateFileIfPresent()
  }

  private func prepareDirectory() throws {
    let directory = fileURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    var info = stat()
    guard lstat(directory.path, &info) == 0,
      info.st_mode & S_IFMT == S_IFDIR,
      info.st_uid == geteuid()
    else {
      throw CocoaError(.fileWriteNoPermission)
    }
    guard chmod(directory.path, 0o700) == 0 else {
      throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
  }

  private func validateFileIfPresent() throws {
    var info = stat()
    guard lstat(fileURL.path, &info) == 0 else {
      if errno == ENOENT {
        return
      }
      throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
    guard info.st_mode & S_IFMT == S_IFREG,
      info.st_uid == geteuid(),
      info.st_mode & 0o777 == 0o600
    else {
      throw CocoaError(.fileReadNoPermission)
    }
  }
}

private struct SupervisorHistorySignature: Equatable {
  let mode: WireSessionMode
  let phase: WireTripPhase
  let sessionID: UUID?
  let verdict: WireProtectionVerdict
  let closedLidAllowed: Bool
  let batteryPercent: Int?
  let thermalLevel: String?
  let lidState: String?
  let stopReason: WireSessionStopReason?
  let buildID: String?
}

extension SupervisorHistoryEntry {
  fileprivate var signature: SupervisorHistorySignature {
    SupervisorHistorySignature(
      mode: mode,
      phase: phase,
      sessionID: sessionID,
      verdict: verdict,
      closedLidAllowed: closedLidAllowed,
      batteryPercent: batteryPercent,
      thermalLevel: thermalLevel,
      lidState: lidState,
      stopReason: stopReason,
      buildID: buildID
    )
  }
}
