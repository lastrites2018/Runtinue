import CryptoKit
import Darwin
import Foundation
import RuntinueIPC

public enum SupervisorEventKind: String, Codable, Sendable {
  case supervisorStarted
  case commandRequested
  case commandAccepted
  case commandRejected
  case authorizationRejected
  case leaseAcquireRequested
  case leaseAcquireAccepted
  case leaseAcquireRejected
  case protectionConfirmed
  case releaseRequested
  case sleepRestored
  case recoveryPending
  case recoveryCompleted
  case normalSleepObserved
  case heartbeatFailed
  case lidStateConflict
  case sessionEnded
}

public enum SupervisorCommandKind: String, Codable, Sendable {
  case startTrip
  case enableAdaptive
  case disableAdaptive
  case enableDesk
  case disableDesk
  case stop
}

/// This exportable stream deliberately has no free-form detail, SSID, user or session name.
public struct SupervisorEvent: Codable, Equatable, Sendable {
  public let version: Int
  public let id: UUID
  public let sequence: UInt64
  public let recordedAt: Date
  public let buildID: String?
  public let kind: SupervisorEventKind
  public let attemptID: UUID?
  public let sessionID: UUID?
  public let command: SupervisorCommandKind?
  public let stopReason: WireSessionStopReason?

  public init(
    id: UUID = UUID(), sequence: UInt64 = 0, recordedAt: Date = Date(),
    buildID: String?, kind: SupervisorEventKind, attemptID: UUID? = nil,
    sessionID: UUID? = nil, command: SupervisorCommandKind? = nil,
    stopReason: WireSessionStopReason? = nil
  ) {
    version = 1
    self.id = id
    self.sequence = sequence
    self.recordedAt = recordedAt
    self.buildID = ExecutableBuildIdentity.validated(buildID)
    self.kind = kind
    self.attemptID = attemptID
    self.sessionID = sessionID
    self.command = command
    self.stopReason = stopReason
  }

  fileprivate func sequenced(_ sequence: UInt64) -> SupervisorEvent {
    SupervisorEvent(
      id: id, sequence: sequence, recordedAt: recordedAt, buildID: buildID,
      kind: kind, attemptID: attemptID, sessionID: sessionID, command: command,
      stopReason: stopReason
    )
  }
}

public enum ExecutableBuildIdentity {
  public static func current() -> String? {
    guard let executable = Bundle.main.executableURL,
      let data = try? Data(contentsOf: executable, options: .mappedIfSafe)
    else {
      return nil
    }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  public static func validated(_ value: String?) -> String? {
    guard let value, value.utf8.count == 64,
      value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    else {
      return nil
    }
    return value
  }
}

public protocol SupervisorEventRecording: Sendable {
  func record(_ event: SupervisorEvent) async throws
}

public enum SupervisorEventStoreError: Error {
  case invalidLog
  case unsafeFile
}

public actor FileSupervisorEventStore: SupervisorEventRecording {
  public static var productionURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Runtinue", isDirectory: true)
      .appendingPathComponent("events.jsonl")
  }

  private let fileURL: URL
  private let maximumEntries: Int

  public init(fileURL: URL = productionURL, maximumEntries: Int = 2_000) {
    self.fileURL = fileURL
    self.maximumEntries = max(1, maximumEntries)
  }

  public func record(_ event: SupervisorEvent) throws {
    try validateDirectory(create: true)
    var entries = try read()
    guard !entries.contains(where: { $0.id == event.id }) else {
      return
    }
    let sequence = entries.last?.sequence ?? 0
    guard sequence < UInt64.max else {
      throw SupervisorEventStoreError.invalidLog
    }
    entries.append(event.sequenced(sequence + 1))
    entries = Array(entries.suffix(maximumEntries))
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    var data = Data()
    for entry in entries {
      data.append(try encoder.encode(entry))
      data.append(0x0A)
    }
    try data.write(to: fileURL, options: .atomic)
    guard chmod(fileURL.path, 0o600) == 0 else {
      throw SupervisorEventStoreError.unsafeFile
    }
  }

  /// Reading the observation stream must not create files, chmod paths or repair corrupt data.
  public func read() throws -> [SupervisorEvent] {
    try validateDirectory(create: false)
    var info = stat()
    guard lstat(fileURL.path, &info) == 0 else {
      if errno == ENOENT { return [] }
      throw SupervisorEventStoreError.unsafeFile
    }
    guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(),
      info.st_mode & 0o777 == 0o600, info.st_nlink == 1,
      info.st_size <= 8 * 1_024 * 1_024
    else {
      throw SupervisorEventStoreError.unsafeFile
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let data = try Data(contentsOf: fileURL, options: .uncached)
    let entries = try data.split(separator: 0x0A).map {
      try decoder.decode(SupervisorEvent.self, from: Data($0))
    }
    var ids = Set<UUID>()
    for (index, entry) in entries.enumerated() {
      guard entry.version == 1, entry.sequence > 0,
        entry.buildID == nil || ExecutableBuildIdentity.validated(entry.buildID) != nil,
        ids.insert(entry.id).inserted,
        index == 0
          || (entries[index - 1].sequence < UInt64.max
            && entry.sequence == entries[index - 1].sequence + 1)
      else {
        throw SupervisorEventStoreError.invalidLog
      }
    }
    return entries
  }

  private func validateDirectory(create: Bool) throws {
    let directory = fileURL.deletingLastPathComponent()
    var info = stat()
    if lstat(directory.path, &info) != 0 {
      guard errno == ENOENT else { throw SupervisorEventStoreError.unsafeFile }
      guard create else { return }
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
      guard lstat(directory.path, &info) == 0 else {
        throw SupervisorEventStoreError.unsafeFile
      }
    }
    guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(),
      info.st_mode & 0o777 == 0o700
    else {
      throw SupervisorEventStoreError.unsafeFile
    }
  }
}

/// Observation failures stay sticky for this process: a later write cannot fill the lost evidence.
public actor SupervisorEventRecorder {
  public nonisolated let buildID: String?
  private let sink: any SupervisorEventRecording
  private var writeFailed = false
  private var previousStatus: StatusSignature?

  public init(sink: any SupervisorEventRecording, buildID: String?) {
    self.sink = sink
    self.buildID = ExecutableBuildIdentity.validated(buildID)
  }

  public func record(
    _ kind: SupervisorEventKind, attemptID: UUID? = nil, sessionID: UUID? = nil,
    command: SupervisorCommandKind? = nil, stopReason: WireSessionStopReason? = nil,
    at date: Date = Date()
  ) async {
    do {
      try await sink.record(
        SupervisorEvent(
          recordedAt: date, buildID: buildID, kind: kind, attemptID: attemptID,
          sessionID: sessionID, command: command, stopReason: stopReason
        ))
    } catch {
      writeFailed = true
    }
  }

  public func observe(_ status: SupervisorStatusWire) async {
    let signature = StatusSignature(status)
    let previous = previousStatus
    guard previous != signature else { return }
    previousStatus = signature
    if status.verdict == .protected {
      await record(.protectionConfirmed, sessionID: status.sessionID)
    }
    if status.verdict == .recoveryPending {
      await record(.recoveryPending, sessionID: status.sessionID, stopReason: status.stopReason)
    }
    if status.phase == .ended, let sessionID = status.sessionID {
      if previous?.sessionID == sessionID, previous?.verdict == .recoveryPending {
        await record(.recoveryCompleted, sessionID: sessionID, stopReason: status.stopReason)
      }
      await record(.sessionEnded, sessionID: sessionID, stopReason: status.stopReason)
    }
  }

  public func issues() -> [WireObservationIssue] {
    var result: [WireObservationIssue] = []
    if buildID == nil { result.append(.buildIdentityUnavailable) }
    if writeFailed { result.append(.eventsUnavailable) }
    return result
  }

  private struct StatusSignature: Equatable {
    let sessionID: UUID?
    let phase: WireTripPhase
    let verdict: WireProtectionVerdict
    let stopReason: WireSessionStopReason?

    init(_ status: SupervisorStatusWire) {
      sessionID = status.sessionID
      phase = status.phase
      verdict = status.verdict
      stopReason = status.stopReason
    }
  }
}
