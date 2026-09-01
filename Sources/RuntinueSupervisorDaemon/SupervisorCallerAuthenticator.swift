import Darwin
import Foundation
import Security

enum SupervisorCallerRole: String, Sendable {
  case control
  case activity
}

struct SupervisorCallerAuthenticator: Sendable {
  static let productionDirectory = URL(
    fileURLWithPath: "/Library/Application Support/io.github.lastrites2018.runtinue/supervisor",
    isDirectory: true
  )

  let role: SupervisorCallerRole
  let requirementURL: URL

  init(
    role: SupervisorCallerRole,
    requirementURL: URL? = nil
  ) {
    self.role = role
    self.requirementURL =
      requirementURL
      ?? Self.productionDirectory.appendingPathComponent(
        "\(role.rawValue).requirement",
        isDirectory: false
      )
  }

  func configureAuthentication(on connection: NSXPCConnection) -> Bool {
    guard connection.effectiveUserIdentifier == geteuid(),
      let requirement = loadRequirement()
    else {
      return false
    }

    connection.setCodeSigningRequirement(requirement)
    return true
  }

  private func loadRequirement() -> String? {
    var info = stat()
    guard lstat(requirementURL.path, &info) == 0,
      info.st_mode & S_IFMT == S_IFREG,
      info.st_uid == 0,
      info.st_mode & 0o022 == 0,
      info.st_size > 0,
      info.st_size <= 16 * 1_024,
      let data = try? Data(contentsOf: requirementURL, options: [.uncached]),
      let text = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !text.isEmpty
    else {
      return nil
    }

    var requirement: SecRequirement?
    guard
      SecRequirementCreateWithString(
        text as CFString,
        SecCSFlags(),
        &requirement
      ) == errSecSuccess
    else {
      return nil
    }
    return text
  }
}
