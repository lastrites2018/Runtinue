import Darwin
import Foundation
import RuntinueActivity
import RuntinueIPC

@main
struct RuntinueActivityAdapter {
  static func main() async {
    do {
      let command = try AdapterCommand(arguments: Array(CommandLine.arguments.dropFirst()))
      try await run(command)
    } catch {
      FileHandle.standardError.write(Data("활동 어댑터 오류: \(error)\n".utf8))
      Foundation.exit(1)
    }
  }

  private static func run(_ command: AdapterCommand) async throws {
    let client = SupervisorActivityXPCClient()
    switch command.kind {
    case .transcript(let path):
      var detector = TranscriptActivityDetector(path: path)
      while !Task.isCancelled {
        switch detector.poll() {
        case .activity:
          try await client.ping(
            source: "transcript",
            namedSession: command.namedSession
          )
        case .baseline, .unchanged:
          break
        case .unavailable:
          throw AdapterError.transcriptUnavailable(path)
        }
        try await ContinuousClock().sleep(for: command.pollInterval)
      }
    case .process(let processID):
      let detector = ProcessActivityDetector(processID: processID)
      while detector.isRunning(), !Task.isCancelled {
        try await client.ping(
          source: "process",
          namedSession: command.namedSession
        )
        try await ContinuousClock().sleep(for: command.pollInterval)
      }
    case .remote:
      let detector = RemoteSessionDetector()
      guard detector.isActive() else {
        throw AdapterError.remoteSessionUnavailable
      }
      while detector.isActive(), !Task.isCancelled {
        try await client.ping(
          source: "remote",
          namedSession: command.namedSession
        )
        try await ContinuousClock().sleep(for: command.pollInterval)
      }
    }
  }
}

private struct AdapterCommand {
  enum Kind {
    case transcript(path: String)
    case process(processID: pid_t)
    case remote
  }

  let kind: Kind
  let namedSession: String?
  let pollInterval: Duration

  init(arguments: [String]) throws {
    guard let name = arguments.first else {
      throw AdapterError.usage
    }
    var path: String?
    var processID: pid_t?
    var namedSession: String?
    var pollSeconds = 15.0
    var index = 1
    while index < arguments.count {
      let option = arguments[index]
      index += 1
      guard index < arguments.count else {
        throw AdapterError.missingValue(option)
      }
      let value = arguments[index]
      index += 1
      switch option {
      case "--path":
        path = value
      case "--pid":
        guard let parsed = Int32(value), parsed > 0 else {
          throw AdapterError.invalidValue(option)
        }
        processID = parsed
      case "--session":
        guard !value.isEmpty, value.utf8.count <= 1_024 else {
          throw AdapterError.invalidValue(option)
        }
        namedSession = value
      case "--poll-seconds":
        guard let parsed = Double(value), parsed.isFinite,
          parsed >= 1, parsed <= 60
        else {
          throw AdapterError.invalidValue(option)
        }
        pollSeconds = parsed
      default:
        throw AdapterError.unknownOption(option)
      }
    }

    switch name {
    case "transcript":
      guard let path, !path.isEmpty else {
        throw AdapterError.missingValue("--path")
      }
      kind = .transcript(path: path)
    case "process":
      guard let processID else {
        throw AdapterError.missingValue("--pid")
      }
      kind = .process(processID: processID)
    case "remote":
      guard path == nil, processID == nil else {
        throw AdapterError.usage
      }
      kind = .remote
    default:
      throw AdapterError.usage
    }
    self.namedSession = namedSession
    pollInterval = .seconds(pollSeconds)
  }
}

private enum AdapterError: Error, CustomStringConvertible {
  case usage
  case missingValue(String)
  case invalidValue(String)
  case unknownOption(String)
  case transcriptUnavailable(String)
  case remoteSessionUnavailable

  var description: String {
    switch self {
    case .usage:
      "사용법: runtinue-activity transcript --path <파일> 또는 process --pid <PID> 또는 remote"
    case .missingValue(let option):
      "필수 값 누락: \(option)"
    case .invalidValue(let option):
      "잘못된 값: \(option)"
    case .unknownOption(let option):
      "알 수 없는 옵션: \(option)"
    case .transcriptUnavailable(let path):
      "transcript 파일을 읽을 수 없음: \(path)"
    case .remoteSessionUnavailable:
      "현재 프로세스 환경에서 원격 세션을 확인할 수 없음"
    }
  }
}
