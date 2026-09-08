import AppKit
import RuntinueUserSupport

/// Keep the user's inputs visible when validation fails.
@MainActor
final class ValidatedConfigurationAlert: NSAlert {
  var validate: (() throws -> Void)?

  @objc func submit(_ sender: NSButton) {
    window.makeFirstResponder(nil)
    do {
      try validate?()
      NSApplication.shared.stopModal(withCode: .alertFirstButtonReturn)
      window.orderOut(nil)
    } catch {
      informativeText = error.localizedDescription
      NSAccessibility.post(element: window, notification: .layoutChanged)
    }
  }
}
