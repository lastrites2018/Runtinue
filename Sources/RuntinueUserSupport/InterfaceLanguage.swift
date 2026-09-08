import Foundation

public enum InterfaceLanguage: String, CaseIterable, Sendable {
  case system, ko, en

  public static let preferenceKey = "interfaceLanguage"
  @TaskLocal public static var override: InterfaceLanguage?

  public static var selected: InterfaceLanguage {
    InterfaceLanguage(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "")
      ?? .system
  }

  public static var current: InterfaceLanguage {
    resolve(override ?? selected, preferredLanguages: Locale.preferredLanguages)
  }

  public static func resolve(_ selection: InterfaceLanguage, preferredLanguages: [String])
    -> InterfaceLanguage
  {
    guard selection == .system else { return selection }
    for language in preferredLanguages {
      let code = language.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first
      if code == "ko" { return .ko }
      if code == "en" { return .en }
    }
    return .en
  }
}

/// Keep each message's Korean and English variants together, including interpolation.
public func L(_ korean: String, _ english: String) -> String {
  InterfaceLanguage.current == .ko ? korean : english
}
