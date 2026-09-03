import AppKit
import XCTest

@testable import RuntinueIPC
@testable import RuntinueMenuBar

final class SafetyChecklistViewsTests: XCTestCase {
  func testChecklistGeometryFitsTheMenuHeaderGrid() {
    XCTAssertEqual(SafetyChecklistGeometry.width, 296)
    XCTAssertEqual(SafetyChecklistGeometry.height, 62)
    XCTAssertEqual(SafetyChecklistGeometry.iconDiameter, 12)
    XCTAssertGreaterThan(SafetyChecklistGeometry.itemTop, SafetyChecklistGeometry.titleHeight)
  }

  func testBrandPrimaryMatchesTheCurrentAppIconGraphite() async throws {
    try await MainActor.run {
      let color = try XCTUnwrap(RuntinuePalette.brandPrimary.usingColorSpace(.sRGB))
      XCTAssertEqual(color.redComponent, 32 / 255, accuracy: 0.001)
      XCTAssertEqual(color.greenComponent, 36 / 255, accuracy: 0.001)
      XCTAssertEqual(color.blueComponent, 44 / 255, accuracy: 0.001)
    }
  }

  func testSafetyToneColorsMeetTextContrastOnLightSurface() async throws {
    try await MainActor.run {
      let appearance = try XCTUnwrap(NSAppearance(named: .aqua))
      let colors = [
        RuntinuePalette.verified(for: appearance),
        RuntinuePalette.attention(for: appearance),
        RuntinuePalette.stopped(for: appearance),
      ]
      for color in colors {
        XCTAssertGreaterThanOrEqual(contrastRatio(color, against: .white), 4.5)
      }
    }
  }

  func testMenuBarStatusUsesMonospacedSemiboldTypography() async throws {
    try await MainActor.run {
      let title = MenuBarStatusTypography.attributedTitle("✓")
      let font = try XCTUnwrap(title.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
      let baseline = try XCTUnwrap(
        title.attribute(.baselineOffset, at: 0, effectiveRange: nil) as? NSNumber
      )

      XCTAssertEqual(font.pointSize, 11)
      XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.monoSpace))
      XCTAssertEqual(baseline.doubleValue, 0.5)
    }
  }

  func testEveryStatusCharacterHasStableSingleGlyphMetrics() async {
    await MainActor.run {
      let widths = ["…", "✓", "!", "?"].map {
        MenuBarStatusTypography.attributedTitle($0).size().width
      }
      XCTAssertLessThan((widths.max() ?? 0) - (widths.min() ?? 0), 1)
      XCTAssertLessThan(widths.max() ?? 0, 12)
    }
  }

  func testHeaderExposesHeadlineGuidanceDetailAndSafetyChecklist() async throws {
    try await MainActor.run {
      let presentation = MenuBarPresentation(
        status: protectedTripStatus(closedLidAllowed: true)
      )
      let header = ProtectionStatusHeaderView()
      header.update(presentation)
      header.layoutSubtreeIfNeeded()

      let headline = try XCTUnwrap(
        findView(identifier: "runtinue.header.headline", in: header) as? NSTextField
      )
      let guidance = try XCTUnwrap(
        findView(identifier: "runtinue.header.guidance", in: header) as? NSTextField
      )
      let detail = try XCTUnwrap(
        findView(identifier: "runtinue.header.detail", in: header) as? NSTextField
      )
      let checklist = try XCTUnwrap(
        findView(
          identifier: "runtinue.header.safetyChecklist", in: header
        ) as? SafetyChecklistView
      )

      XCTAssertEqual(headline.stringValue, "보호 중, Trip")
      XCTAssertEqual(guidance.stringValue, "덮개 닫기 가능")
      XCTAssertTrue(detail.stringValue.contains("남은 시간"))
      XCTAssertFalse(checklist.isHidden)
      XCTAssertEqual(checklist.presentation?.title, "안전 확인 4개 완료")
      XCTAssertEqual(checklist.presentation?.items.last?.state, .verified)
      XCTAssertTrue(checklist.accessibilityLabel()?.contains("수면 보호 적용됨") == true)
      XCTAssertEqual(header.frame.width, 320)
      XCTAssertEqual(header.frame.height, 158)
    }
  }

  func testChecklistRendersWithoutHorizontalClippingAtBothScales() async throws {
    try await MainActor.run {
      let checklist = SafetyChecklistView()
      checklist.update(
        SafetyChecklistPresentation(
          title: "안전 확인 4개 완료",
          items: [
            SafetyCheckItem(text: "시작 시 네트워크 확인", state: .passed),
            SafetyCheckItem(text: "시작 시 인터넷 확인", state: .passed),
            SafetyCheckItem(text: "기기 상태 안전", state: .passed),
            SafetyCheckItem(text: "수면 보호 적용됨", state: .verified),
          ]
        ),
        tone: .verified
      )

      for appearanceName: NSAppearance.Name in [.aqua, .darkAqua] {
        checklist.appearance = NSAppearance(named: appearanceName)
        for scale in [1, 2] {
          let bitmap = try render(checklist, scale: scale)
          var visiblePixels = 0
          var edgePixels = 0
          for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
              guard (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 else {
                continue
              }
              visiblePixels += 1
              if x == 0 || x == bitmap.pixelsWide - 1 {
                edgePixels += 1
              }
            }
          }

          let context = "appearance=\(appearanceName.rawValue), scale=\(scale)"
          XCTAssertGreaterThan(visiblePixels, 300 * scale * scale, context)
          XCTAssertLessThan(
            visiblePixels,
            bitmap.pixelsWide * bitmap.pixelsHigh / 2,
            context
          )
          XCTAssertEqual(edgePixels, 0, context)
        }
      }
    }
  }

  func testCriticalWarningUsesASeparateTemplateSymbol() async throws {
    try await MainActor.run {
      let continuation = try XCTUnwrap(MenuBarStatusVisuals.image(for: .continuationMark))
      let warning = try XCTUnwrap(MenuBarStatusVisuals.image(for: .criticalWarning))

      XCTAssertTrue(continuation.isTemplate)
      XCTAssertTrue(warning.isTemplate)
    }
  }
}

@MainActor
private func protectedTripStatus(closedLidAllowed: Bool) -> SupervisorStatusWire {
  SupervisorStatusWire(
    phase: .active,
    mode: .trip,
    sessionID: UUID(),
    verdict: .protected,
    closedLidAllowed: closedLidAllowed,
    remainingSeconds: 5_400,
    batteryPercent: 80,
    thermalLevel: "nominal",
    lidState: "open",
    detail: nil,
    updatedAt: Date(timeIntervalSince1970: 1)
  )
}

@MainActor
private func findView(identifier: String, in root: NSView) -> NSView? {
  if root.accessibilityIdentifier() == identifier {
    return root
  }
  for subview in root.subviews {
    if let match = findView(identifier: identifier, in: subview) {
      return match
    }
  }
  return nil
}

@MainActor
private func render(_ view: NSView, scale: Int) throws -> NSBitmapImageRep {
  let width = Int(view.bounds.width) * scale
  let height = Int(view.bounds.height) * scale
  let bitmap = try XCTUnwrap(
    NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: width,
      pixelsHigh: height,
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0
    )
  )
  let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = context
  NSColor.clear.setFill()
  NSRect(x: 0, y: 0, width: width, height: height).fill(using: .copy)
  context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
  view.effectiveAppearance.performAsCurrentDrawingAppearance {
    view.draw(view.bounds)
  }
  NSGraphicsContext.restoreGraphicsState()
  return bitmap
}

@MainActor
private func contrastRatio(_ foreground: NSColor, against background: NSColor) -> CGFloat {
  let foregroundLuminance = relativeLuminance(foreground)
  let backgroundLuminance = relativeLuminance(background)
  let lighter = max(foregroundLuminance, backgroundLuminance)
  let darker = min(foregroundLuminance, backgroundLuminance)
  return (lighter + 0.05) / (darker + 0.05)
}

@MainActor
private func relativeLuminance(_ color: NSColor) -> CGFloat {
  guard let color = color.usingColorSpace(.sRGB) else { return 0 }
  return 0.2126 * linearComponent(color.redComponent)
    + 0.7152 * linearComponent(color.greenComponent)
    + 0.0722 * linearComponent(color.blueComponent)
}

private func linearComponent(_ value: CGFloat) -> CGFloat {
  value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
}
