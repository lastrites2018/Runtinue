import AppKit
import XCTest

@testable import RuntinueMenuBar

final class MenuBarIconTests: XCTestCase {
  func testBundledIconIsAnEighteenPointTemplateWithTransparentPadding() async throws {
    try await MainActor.run {
      let icon = try XCTUnwrap(MenuBarIcon.load())
      XCTAssertTrue(icon.isTemplate)
      XCTAssertEqual(icon.size.height, 18)
      XCTAssertGreaterThanOrEqual(icon.size.width, 18)
      XCTAssertLessThanOrEqual(icon.size.width, 30)

      let data = try XCTUnwrap(icon.tiffRepresentation)
      let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
      XCTAssertTrue(bitmap.hasAlpha)
      XCTAssertEqual(bitmap.colorAt(x: 0, y: 0)?.alphaComponent, 0)
      XCTAssertGreaterThan(bitmap.pixelsWide, 100)
      XCTAssertGreaterThan(bitmap.pixelsHigh, 100)
    }
  }

  func testMissingPackagedAssetReturnsNilWithoutUsingTheBuildDirectory() async {
    await MainActor.run {
      let testBundle = Bundle(for: MenuBarIconTests.self)
      XCTAssertNil(MenuBarIcon.load(from: testBundle))
    }
  }

  func testIconRendersVisiblePixelsAtStandardAndRetinaMenuBarSizes() async throws {
    try await MainActor.run {
      let icon = try XCTUnwrap(MenuBarIcon.load())
      for scale in [1, 2] {
        let width = Int(icon.size.width.rounded(.up)) * scale
        let height = 18 * scale
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
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
        ))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let frame = NSRect(x: 0, y: 0, width: width, height: height)
        NSColor.clear.setFill()
        frame.fill(using: .copy)
        icon.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        var visiblePixels = 0
        for y in 0..<height {
          for x in 0..<width where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
            visiblePixels += 1
          }
        }
        XCTAssertGreaterThan(visiblePixels, width * height / 10, "scale=\(scale)")
        XCTAssertLessThan(visiblePixels, width * height / 2, "scale=\(scale)")
      }
    }
  }
}
