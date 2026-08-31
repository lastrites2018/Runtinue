import Foundation

public enum InjectedPowerBackendError: Error, Equatable, Sendable {
  case writeFailed(String)
  case writeAppliedThenFailed(String)
  case timedOut(String)
}

public enum InjectedReadFault: Sendable {
  case unavailable(String)
  case override(ObservedSleepOverride)
  case delay(Duration)
  case timeout(after: Duration, detail: String)
}

public enum InjectedWriteFault: Sendable {
  case fail(String)
  case applyThenFail(String)
  case delay(Duration)
  case timeout(after: Duration, detail: String)
}

public struct FaultInjectingPowerSnapshot: Equatable, Sendable {
  public let state: ObservedSleepOverride
  public let readCallCount: Int
  public let writeCallCount: Int
}

public actor FaultInjectingPowerBackend: SleepPowerBackend {
  private var state: ObservedSleepOverride
  private var readFaults: [Int: InjectedReadFault]
  private var writeFaults: [Int: InjectedWriteFault]
  private var readCallCount = 0
  private var writeCallCount = 0

  public init(
    initialState: ObservedSleepOverride = .normal,
    readFaults: [Int: InjectedReadFault] = [:],
    writeFaults: [Int: InjectedWriteFault] = [:]
  ) {
    state = initialState
    self.readFaults = readFaults
    self.writeFaults = writeFaults
  }

  public func readSleepOverride() async -> ObservedSleepOverride {
    readCallCount += 1
    guard let fault = readFaults.removeValue(forKey: readCallCount) else {
      return state
    }
    switch fault {
    case .unavailable(let detail):
      return .unavailable(detail)
    case .override(let observation):
      return observation
    case .delay(let duration):
      try? await ContinuousClock().sleep(for: duration)
      return state
    case .timeout(let duration, let detail):
      try? await ContinuousClock().sleep(for: duration)
      return .unavailable(detail)
    }
  }

  public func writeAndVerify(_ requested: SleepOverrideState) async throws {
    writeCallCount += 1
    let nextState: ObservedSleepOverride =
      requested == .disabled ? .disabled : .normal
    guard let fault = writeFaults.removeValue(forKey: writeCallCount) else {
      state = nextState
      return
    }
    switch fault {
    case .fail(let detail):
      throw InjectedPowerBackendError.writeFailed(detail)
    case .applyThenFail(let detail):
      state = nextState
      throw InjectedPowerBackendError.writeAppliedThenFailed(detail)
    case .delay(let duration):
      try await ContinuousClock().sleep(for: duration)
      state = nextState
    case .timeout(let duration, let detail):
      try await ContinuousClock().sleep(for: duration)
      throw InjectedPowerBackendError.timedOut(detail)
    }
  }

  public func snapshot() -> FaultInjectingPowerSnapshot {
    FaultInjectingPowerSnapshot(
      state: state,
      readCallCount: readCallCount,
      writeCallCount: writeCallCount
    )
  }
}
