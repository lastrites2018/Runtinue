import AppKit
import RuntinueUserSupport

/// Reject invalid edits as a whole: pasting "1e2" must never silently become "12".
final class MinutesFormatter: Formatter {
  let maximum: Int

  init(maximum: Int) {
    self.maximum = maximum
    super.init()
  }

  required init?(coder: NSCoder) { nil }

  func acceptsEdit(_ value: String) -> Bool {
    value.isEmpty
      || (value.utf8.allSatisfy { (48...57).contains($0) }
        && value.count <= String(maximum).count
        && Int(value).map { $0 <= maximum } == true)
  }

  override func string(for obj: Any?) -> String? {
    if let text = obj as? String { return text }
    return (obj as? NSNumber)?.stringValue
  }

  override func getObjectValue(
    _ obj: AutoreleasingUnsafeMutablePointer<AnyObject?>?,
    for string: String, errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?
  ) -> Bool {
    guard acceptsEdit(string) else { return false }
    obj?.pointee = string as NSString
    return true
  }

  override func isPartialStringValid(
    _ partialString: String,
    newEditingString newString: AutoreleasingUnsafeMutablePointer<NSString?>?,
    errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?
  ) -> Bool {
    acceptsEdit(partialString)
  }
}

@MainActor
final class MinutesField: NSTextField {
  init(_ value: Int, maximum: Int = 1440) {
    super.init(frame: .zero)
    stringValue = String(value)
    formatter = MinutesFormatter(maximum: maximum)
    alignment = .right
    placeholderString = "1–\(maximum)"
    toolTip = L(
      "1부터 \(maximum)까지 정수로 입력하세요. 단위는 분입니다.",
      "Enter a whole number from 1 to \(maximum), in minutes.")
  }

  required init?(coder: NSCoder) { nil }
}
