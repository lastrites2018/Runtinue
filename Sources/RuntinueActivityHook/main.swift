import Foundation
import RuntinueIPC

@main
struct RuntinueActivityHook {
  static func main() async {
    do {
      let options = try HookOptions(arguments: Array(CommandLine.arguments.dropFirst()))
      try await SupervisorActivityXPCClient().ping(
        source: options.source,
        namedSession: options.namedSession
      )
    } catch {
      FileHandle.standardError.write(
        Data("활동 신호 전송 실패: \(error)\n".utf8)
      )
      Foundation.exit(1)
    }
  }
}

private struct HookOptions {
  let source: String
  let namedSession: String?

  init(arguments: [String]) throws {
    var source = "hook"
    var namedSession: String?
    var index = 0
    while index < arguments.count {
      let option = arguments[index]
      index += 1
      guard index < arguments.count else {
        throw HookError.missingValue(option)
      }
      switch option {
      case "--source":
        source = arguments[index]
      case "--session":
        namedSession = arguments[index]
      default:
        throw HookError.unknownOption(option)
      }
      index += 1
    }
    guard !source.isEmpty, source.utf8.count <= 1_024 else {
      throw HookError.invalidSource
    }
    guard namedSession?.utf8.count ?? 0 <= 1_024 else {
      throw HookError.invalidSession
    }
    self.source = source
    self.namedSession = namedSession
  }
}

private enum HookError: Error {
  case missingValue(String)
  case unknownOption(String)
  case invalidSource
  case invalidSession
}
