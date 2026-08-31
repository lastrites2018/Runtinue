import Darwin
import Foundation
import Security

struct CallerAuthenticator: Sendable {
  static let productionRequirementURL = URL(
    fileURLWithPath:
      "/Library/Application Support/io.github.lastrites2018.runtinue/helper/supervisor.requirement"
  )

  let requirementURL: URL

  init(requirementURL: URL = Self.productionRequirementURL) {
    self.requirementURL = requirementURL
  }

  func accepts(_ connection: NSXPCConnection) -> Bool {
    guard connection.effectiveUserIdentifier != 0,
      connection.processIdentifier > 0,
      let requirement = loadRequirement()
    else {
      return false
    }

    let attributes =
      [
        kSecGuestAttributePid as String: NSNumber(value: connection.processIdentifier)
      ] as CFDictionary
    var code: SecCode?
    guard
      SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(), &code) == errSecSuccess,
      let code
    else {
      return false
    }

    // SecCode is dynamic code. Static-only validation flags are rejected by
    // SecCodeCheckValidity on current macOS; the package verifier performs the
    // separate strict, all-architectures check before installation.
    return SecCodeCheckValidity(code, SecCSFlags(), requirement) == errSecSuccess
  }

  private func loadRequirement() -> SecRequirement? {
    var info = stat()
    guard Darwin.lstat(requirementURL.path, &info) == 0,
      info.st_mode & S_IFMT == S_IFREG,
      info.st_uid == 0,
      info.st_mode & 0o077 == 0,
      info.st_size > 0,
      info.st_size <= 16 * 1_024,
      let data = try? Data(contentsOf: requirementURL, options: [.uncached]),
      let requirementText = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !requirementText.isEmpty
    else {
      return nil
    }

    var requirement: SecRequirement?
    guard
      SecRequirementCreateWithString(
        requirementText as CFString,
        SecCSFlags(),
        &requirement
      ) == errSecSuccess
    else {
      return nil
    }
    return requirement
  }
}
