import Darwin
import Foundation

public enum TranscriptPollResult: Equatable, Sendable {
  case baseline
  case unchanged
  case activity
  case unavailable
}

public struct TranscriptActivityDetector: Sendable {
  private struct Signature: Equatable, Sendable {
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let size: off_t
  }

  private let path: String
  private var lastSignature: Signature?

  public init(path: String) {
    self.path = path
  }

  public mutating func poll() -> TranscriptPollResult {
    guard let signature = readSignature() else {
      return .unavailable
    }
    guard let lastSignature else {
      self.lastSignature = signature
      return .baseline
    }
    guard signature != lastSignature else {
      return .unchanged
    }
    self.lastSignature = signature
    return .activity
  }

  private func readSignature() -> Signature? {
    var info = stat()
    guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
      return nil
    }
    return Signature(
      modifiedSeconds: info.st_mtimespec.tv_sec,
      modifiedNanoseconds: info.st_mtimespec.tv_nsec,
      size: info.st_size
    )
  }
}

public struct ProcessActivityDetector: Sendable {
  public let processID: pid_t

  public init(processID: pid_t) {
    self.processID = processID
  }

  public func isRunning() -> Bool {
    guard processID > 0 else {
      return false
    }
    if kill(processID, 0) == 0 {
      return true
    }
    return errno == EPERM
  }
}

public struct RemoteSessionDetector: Sendable {
  public init() {}

  public func isActive(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Bool {
    ["SSH_CONNECTION", "SSH_TTY", "MOSH_CONNECTION"].contains { key in
      guard let value = environment[key] else {
        return false
      }
      return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
  }
}
