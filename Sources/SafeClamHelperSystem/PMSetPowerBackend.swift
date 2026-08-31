import Darwin
import Dispatch
import Foundation
import IOKit
import SafeClamHelperCore

public enum PMSetPowerBackendError: Error, CustomStringConvertible, Sendable {
  case notPrivileged
  case launchFailed(String)
  case timedOut
  case nonzeroExit(Int32)
  case verificationFailed(ObservedSleepOverride)

  public var description: String {
    switch self {
    case .notPrivileged:
      "pmset sleep override requires root"
    case .launchFailed(let detail):
      "pmset launch failed: \(detail)"
    case .timedOut:
      "pmset exceeded its execution timeout"
    case .nonzeroExit(let status):
      "pmset exited with status \(status)"
    case .verificationFailed(let observed):
      "sleep override read-back verification failed: \(observed)"
    }
  }
}

public actor PMSetPowerBackend: SleepPowerBackend {
  private let executableURL: URL
  private let executionTimeout: TimeInterval
  private let verificationAttempts: Int
  private let verificationDelay: TimeInterval

  public init(
    executableURL: URL = URL(fileURLWithPath: "/usr/bin/pmset"),
    executionTimeout: TimeInterval = 10,
    verificationAttempts: Int = 10,
    verificationDelay: TimeInterval = 0.1
  ) {
    self.executableURL = executableURL
    self.executionTimeout = executionTimeout
    self.verificationAttempts = verificationAttempts
    self.verificationDelay = verificationDelay
  }

  public func readSleepOverride() async -> ObservedSleepOverride {
    readSleepOverrideSynchronously()
  }

  public func writeAndVerify(_ state: SleepOverrideState) async throws {
    guard geteuid() == 0 else {
      throw PMSetPowerBackendError.notPrivileged
    }

    let process = Process()
    process.executableURL = executableURL
    process.arguments = ["-a", "disablesleep", state == .disabled ? "1" : "0"]
    process.environment = [
      "LANG": "C",
      "LC_ALL": "C",
      "PATH": "/usr/bin:/usr/sbin",
    ]
    process.currentDirectoryURL = URL(fileURLWithPath: "/", isDirectory: true)
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice

    do {
      try process.run()
    } catch {
      throw PMSetPowerBackendError.launchFailed(String(describing: error))
    }

    let deadline =
      DispatchTime.now().uptimeNanoseconds
      + UInt64(executionTimeout * 1_000_000_000)
    while process.isRunning && DispatchTime.now().uptimeNanoseconds < deadline {
      try? await Task.sleep(nanoseconds: 50_000_000)
    }
    if process.isRunning {
      process.terminate()
      let terminationDeadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
      while process.isRunning && DispatchTime.now().uptimeNanoseconds < terminationDeadline {
        try? await Task.sleep(nanoseconds: 50_000_000)
      }
      if process.isRunning {
        Darwin.kill(process.processIdentifier, SIGKILL)
      }
      throw PMSetPowerBackendError.timedOut
    }
    guard process.terminationStatus == 0 else {
      throw PMSetPowerBackendError.nonzeroExit(process.terminationStatus)
    }

    let expected: ObservedSleepOverride = state == .disabled ? .disabled : .normal
    var observed = readSleepOverrideSynchronously()
    for _ in 0..<verificationAttempts {
      if observed == expected {
        return
      }
      try? await Task.sleep(
        nanoseconds: UInt64(verificationDelay * 1_000_000_000)
      )
      observed = readSleepOverrideSynchronously()
    }
    throw PMSetPowerBackendError.verificationFailed(observed)
  }

  private func readSleepOverrideSynchronously() -> ObservedSleepOverride {
    let service = IOServiceGetMatchingService(
      kIOMainPortDefault,
      IOServiceMatching("IOPMrootDomain")
    )
    guard service != IO_OBJECT_NULL else {
      return .unavailable("IOPMrootDomain is unavailable")
    }
    defer { IOObjectRelease(service) }

    guard
      let value = IORegistryEntryCreateCFProperty(
        service,
        "SleepDisabled" as CFString,
        kCFAllocatorDefault,
        0
      )?.takeRetainedValue() as? Bool
    else {
      return .unavailable("SleepDisabled is unavailable")
    }
    return value ? .disabled : .normal
  }
}
