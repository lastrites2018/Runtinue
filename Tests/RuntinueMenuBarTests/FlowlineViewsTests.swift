import AppKit
import XCTest

@testable import RuntinueIPC
@testable import RuntinueMenuBar

final class FlowlineViewsTests: XCTestCase {
  func testFlowlineGeometryKeepsTheMeasuredIconProportions() {
    XCTAssertEqual(
      RuntinueGeometry.baseStroke,
      RuntinueGeometry.flowlineHeight * 72 / 916,
      accuracy: 0.001
    )
    XCTAssertEqual(
      RuntinueGeometry.nodeDiameter / RuntinueGeometry.baseStroke,
      2.05,
      accuracy: 0.001
    )
  }

  func testBrandPrimaryMatchesTheCurrentAppIconGraphite() async throws {
    try await MainActor.run {
      let color = try XCTUnwrap(RuntinuePalette.brandPrimary.usingColorSpace(.sRGB))
      XCTAssertEqual(color.redComponent, 32 / 255, accuracy: 0.001)
      XCTAssertEqual(color.greenComponent, 36 / 255, accuracy: 0.001)
      XCTAssertEqual(color.blueComponent, 44 / 255, accuracy: 0.001)
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

  func testHeaderExposesHeadlineGuidanceDetailAndFlowline() async throws {
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
      let flowline = try XCTUnwrap(
        findView(identifier: "runtinue.header.flowline", in: header) as? FlowlineRouteView
      )

      XCTAssertEqual(headline.stringValue, "보호 중, Trip")
      XCTAssertEqual(guidance.stringValue, "덮개 닫기 가능")
      XCTAssertTrue(detail.stringValue.contains("남은 시간"))
      XCTAssertFalse(flowline.isHidden)
      XCTAssertEqual(flowline.presentation?.steps.last?.state, .verified)
      XCTAssertTrue(flowline.accessibilityLabel()?.contains("보호 검증 완료") == true)
      XCTAssertEqual(header.frame.width, 320)
      XCTAssertEqual(header.frame.height, 142)
    }
  }

  func testFlowlineSilhouetteRendersWithoutHorizontalClippingAtBothScales() async throws {
    try await MainActor.run {
      let flowline = FlowlineRouteView()
      flowline.update(
        FlowlinePresentation(
          steps: [
            FlowlineStep(label: "네트워크", state: .passed),
            FlowlineStep(label: "인터넷", state: .passed),
            FlowlineStep(label: "기기", state: .passed),
            FlowlineStep(label: "보호", state: .verified),
          ]
        ),
        tone: .verified
      )

      for appearanceName: NSAppearance.Name in [.aqua, .darkAqua] {
        flowline.appearance = NSAppearance(named: appearanceName)
        for scale in [1, 2] {
          let bitmap = try render(flowline, scale: scale)
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
          XCTAssertGreaterThan(visiblePixels, 200 * scale * scale, context)
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
