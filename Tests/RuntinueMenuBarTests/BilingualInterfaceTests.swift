import AppKit
import RuntinueUserSupport
import XCTest

@testable import RuntinueIPC
@testable import RuntinueMenuBar

@MainActor
final class BilingualInterfaceTests: XCTestCase {
  func testNumericEditingRejectsWholeInvalidPasteAndAllowsDeletion() {
    let formatter = MinutesFormatter(maximum: 1440)
    for input in ["", "1", "90", "1440"] {
      XCTAssertTrue(
        formatter.isPartialStringValid(input, newEditingString: nil, errorDescription: nil), input)
    }
    for input in ["abc", "1e2", "2.5", "-10", "+10", "1 2", "１２", "1441", "99999", "90\n"] {
      XCTAssertFalse(
        formatter.isPartialStringValid(input, newEditingString: nil, errorDescription: nil), input)
      XCTAssertFalse(formatter.getObjectValue(nil, for: input, errorDescription: nil), input)
    }
    XCTAssertFalse(MinutesFormatter(maximum: 60).acceptsEdit("61"))
  }

  func testSubmissionStillRejectsInvalidNumbersWhenFormatterIsBypassed() {
    for input in ["", "0", "1e2", "2.5", "-1", "NaN", "1441"] {
      XCTAssertThrowsError(
        try DeskFormInput(maximumProtectionMinutes: input, allowClosedLid: false)
          .validatedSettings(), input)
    }
  }

  func testFieldEditorRejectsLettersWithoutChangingThePreviousNumber() throws {
    _ = NSApplication.shared
    let field = MinutesField(90)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 120, height: 50),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = field
    window.makeFirstResponder(field)
    let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
    editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
    editor.insertText("1e2", replacementRange: editor.selectedRange())
    XCTAssertEqual(editor.string, "90")
    editor.insertText(
      "60", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
    XCTAssertEqual(editor.string, "60")
  }

  func testSystemLanguageAndExplicitSelection() {
    XCTAssertEqual(
      InterfaceLanguage.resolve(.system, preferredLanguages: ["fr-FR", "ko-KR", "en-US"]), .ko)
    XCTAssertEqual(InterfaceLanguage.resolve(.system, preferredLanguages: ["en-GB", "ko"]), .en)
    XCTAssertEqual(InterfaceLanguage.resolve(.system, preferredLanguages: ["fr"]), .en)
    XCTAssertEqual(InterfaceLanguage.resolve(.ko, preferredLanguages: ["en"]), .ko)
    XCTAssertEqual(InterfaceLanguage.resolve(.en, preferredLanguages: ["ko"]), .en)
  }

  func testBundleFallbackMatchesSystemResolverAndPermissionDescriptions() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let info = try XCTUnwrap(
      try PropertyListSerialization.propertyList(
        from: Data(contentsOf: root.appendingPathComponent("Packaging/Runtinue.app.Info.plist")),
        format: nil
      ) as? [String: Any])
    let fallback = try XCTUnwrap(info["CFBundleDevelopmentRegion"] as? String)
    for preferences: [String] in [[], ["fr-FR"], ["ja-JP", "de-DE"]] {
      XCTAssertEqual(
        InterfaceLanguage.resolve(.system, preferredLanguages: preferences).rawValue, fallback)
    }
    XCTAssertEqual(info["CFBundleLocalizations"] as? [String], ["ko", "en"])
    let localized = try XCTUnwrap(
      try PropertyListSerialization.propertyList(
        from: Data(
          contentsOf: root.appendingPathComponent("Packaging/\(fallback).lproj/InfoPlist.strings")),
        format: nil
      ) as? [String: String])
    for key in ["NSLocationUsageDescription", "NSLocationWhenInUseUsageDescription"] {
      let description = try XCTUnwrap(localized[key])
      XCTAssertFalse(description.isEmpty)
      XCTAssertEqual(info[key] as? String, description)
    }
  }

  func testBothLanguagesPreserveProtectionDecisionsWithoutMixedStatusText() {
    for verdict: WireProtectionVerdict in [
      .protected, .inactive, .waitingForHotspot, .acquiring, .releasing, .recoveryPending, .unsafe,
      .unknown,
    ] {
      let status = SupervisorStatusWire(
        phase: .active, mode: .trip, sessionID: UUID(),
        verdict: verdict, closedLidAllowed: verdict == .protected, remainingSeconds: 90,
        batteryPercent: 80, thermalLevel: "nominal", lidState: "open", detail: nil,
        updatedAt: Date())
      let ko = InterfaceLanguage.$override.withValue(.ko) { MenuBarPresentation(status: status) }
      let en = InterfaceLanguage.$override.withValue(.en) { MenuBarPresentation(status: status) }
      XCTAssertEqual(ko.statusIndicator, en.statusIndicator)
      XCTAssertEqual(ko.tone, en.tone)
      XCTAssertEqual(ko.safetyChecklist?.items.map(\.state), en.safetyChecklist?.items.map(\.state))
      let english =
        [en.summary, en.headline, en.guidance, en.detail]
        + (en.safetyChecklist?.items.map(\.text) ?? [])
      XCTAssertFalse(
        english.joined().unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) })
    }
  }

  func testInvalidSubmissionPreservesFormAndShowsLocalizedError() {
    for language: InterfaceLanguage in [.ko, .en] {
      InterfaceLanguage.$override.withValue(language) {
        let form = DeskConfigurationView()
        let alert = ValidatedConfigurationAlert()
        alert.accessoryView = form
        alert.validate = {
          _ = try DeskFormInput(maximumProtectionMinutes: "0", allowClosedLid: false)
            .validatedSettings()
        }
        alert.submit(NSButton())
        XCTAssertTrue(alert.accessoryView === form)
        XCTAssertTrue(alert.informativeText.contains(language == .ko ? "정수" : "whole number"))
      }
    }
  }

  func testFormsFitInBothLanguagesAndOptionallyRender() throws {
    _ = NSApplication.shared
    for language: InterfaceLanguage in [.ko, .en] {
      try InterfaceLanguage.$override.withValue(language) {
        let forms: [(String, NSView)] = [
          ("travel", TripConfigurationView(currentWiFiSSID: "My iPhone")),
          ("activity", AdaptiveConfigurationView()), ("timed", DeskConfigurationView()),
        ]
        for (name, form) in forms {
          let window = NSWindow(
            contentRect: form.frame, styleMask: [.titled], backing: .buffered, defer: false)
          window.contentView = form
          form.appearance = NSAppearance(named: .aqua)
          form.wantsLayer = true
          form.layer?.backgroundColor = NSColor.white.cgColor
          form.layoutSubtreeIfNeeded()
          for field in descendants(form).compactMap({ $0 as? MinutesField }) {
            XCTAssertEqual(field.frame.width, 76, accuracy: 1)
            XCTAssertNotNil(field.formatter as? MinutesFormatter)
          }
          for label in descendants(form).compactMap({ $0 as? NSTextField }).filter({
            !$0.isEditable
          }) {
            let rect = label.convert(label.bounds, to: form)
            XCTAssertGreaterThanOrEqual(rect.minX, 0, name)
            XCTAssertLessThanOrEqual(rect.maxX, form.bounds.width + 1, name)
            XCTAssertGreaterThanOrEqual(rect.minY, 0, name)
            XCTAssertLessThanOrEqual(rect.maxY, form.bounds.height + 1, name)
          }
          if let output = ProcessInfo.processInfo.environment["RUNTINUE_UI_RENDER_ROOT"] {
            let bitmap = try XCTUnwrap(form.bitmapImageRepForCachingDisplay(in: form.bounds))
            form.cacheDisplay(in: form.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(
              to: URL(fileURLWithPath: output).appendingPathComponent(
                "\(name)-\(language.rawValue).png"))
          }
        }
      }
    }
  }

  private func descendants(_ view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + descendants($0) }
  }
}
