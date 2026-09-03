import AppKit
import XCTest

@testable import RuntinueIPC
@testable import RuntinueMenuBar

@MainActor
final class READMEAssetRenderingTests: XCTestCase {
  func testRenderREADMEStatusAssetsFromProductionViews() throws {
    guard ProcessInfo.processInfo.environment["RUNTINUE_RENDER_README_ASSETS"] == "1" else {
      throw XCTSkip("README 이미지 렌더링을 요청한 경우에만 실행합니다.")
    }
    let outputPath = try XCTUnwrap(
      ProcessInfo.processInfo.environment["RUNTINUE_README_ASSET_ROOT"]
    )
    let outputDirectory = URL(fileURLWithPath: outputPath, isDirectory: true)
    _ = NSApplication.shared

    try renderStatus(
      protectedStatus(), to: outputDirectory.appendingPathComponent("trip-protected.png")
    )
    try renderStatus(
      recoveryStatus(), to: outputDirectory.appendingPathComponent("recovery.png")
    )
  }

  private func renderStatus(_ status: SupervisorStatusWire, to url: URL) throws {
    let header = ProtectionStatusHeaderView()
    header.update(MenuBarPresentation(status: status))
    header.layoutSubtreeIfNeeded()

    let card = READMEStatusCard(contentView: header)
    card.appearance = NSAppearance(named: .aqua)
    card.layoutSubtreeIfNeeded()
    try writePNG(of: card, to: url)
  }

  private func writePNG(of view: NSView, to url: URL, scale: Int = 2) throws {
    view.layoutSubtreeIfNeeded()
    let bitmap = try XCTUnwrap(
      NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(view.bounds.width) * scale,
        pixelsHigh: Int(view.bounds.height) * scale,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
      )
    )
    bitmap.size = view.bounds.size
    view.cacheDisplay(in: view.bounds, to: bitmap)
    let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    try data.write(to: url, options: .atomic)
  }

  private func protectedStatus() -> SupervisorStatusWire {
    SupervisorStatusWire(
      phase: .active,
      mode: .trip,
      sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000001"),
      verdict: .protected,
      closedLidAllowed: true,
      remainingSeconds: 2_880,
      batteryPercent: 78,
      thermalLevel: "nominal",
      lidState: "open",
      detail: nil,
      updatedAt: Date(timeIntervalSince1970: 1)
    )
  }

  private func recoveryStatus() -> SupervisorStatusWire {
    SupervisorStatusWire(
      phase: .recoveryPending,
      mode: .trip,
      sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000002"),
      verdict: .recoveryPending,
      closedLidAllowed: false,
      remainingSeconds: nil,
      batteryPercent: nil,
      thermalLevel: nil,
      lidState: nil,
      detail: nil,
      updatedAt: Date(timeIntervalSince1970: 1)
    )
  }
}

@MainActor
private final class READMEStatusCard: NSView {
  private static let padding: CGFloat = 12

  init(contentView: NSView) {
    let size = NSSize(
      width: contentView.frame.width + (Self.padding * 2),
      height: contentView.frame.height + (Self.padding * 2)
    )
    super.init(frame: NSRect(origin: .zero, size: size))
    contentView.frame.origin = NSPoint(x: Self.padding, y: Self.padding)
    addSubview(contentView)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    nil
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    let frame = bounds.insetBy(dx: 0.5, dy: 0.5)
    let path = NSBezierPath(roundedRect: frame, xRadius: 11.5, yRadius: 11.5)
    NSColor.windowBackgroundColor.setFill()
    path.fill()
    NSColor.separatorColor.withAlphaComponent(0.8).setStroke()
    path.lineWidth = 0.5
    path.stroke()
  }
}
