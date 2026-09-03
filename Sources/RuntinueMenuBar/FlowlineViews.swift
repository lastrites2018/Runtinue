import AppKit

@MainActor
enum RuntinuePalette {
  static let brandPrimary = NSColor(
    srgbRed: 32 / 255,
    green: 36 / 255,
    blue: 44 / 255,
    alpha: 1
  )

  static func progress(for appearance: NSAppearance) -> NSColor {
    switch appearance.bestMatch(from: [.darkAqua, .aqua]) {
    case .darkAqua:
      NSColor(srgbRed: 0.82, green: 0.84, blue: 0.88, alpha: 1)
    default:
      brandPrimary
    }
  }

  static func brandSurface(for appearance: NSAppearance) -> NSColor {
    progress(for: appearance).withAlphaComponent(0.12)
  }

  static func verified(for appearance: NSAppearance) -> NSColor {
    switch appearance.bestMatch(from: [.darkAqua, .aqua]) {
    case .darkAqua:
      .systemGreen
    default:
      NSColor(srgbRed: 0.04, green: 0.43, blue: 0.18, alpha: 1)
    }
  }

  static func attention(for appearance: NSAppearance) -> NSColor {
    switch appearance.bestMatch(from: [.darkAqua, .aqua]) {
    case .darkAqua:
      .systemOrange
    default:
      NSColor(srgbRed: 0.60, green: 0.29, blue: 0, alpha: 1)
    }
  }

  static func stopped(for appearance: NSAppearance) -> NSColor {
    switch appearance.bestMatch(from: [.darkAqua, .aqua]) {
    case .darkAqua:
      .systemRed
    default:
      NSColor(srgbRed: 0.71, green: 0.14, blue: 0.09, alpha: 1)
    }
  }

  static var subtleOutline: NSColor {
    NSColor.separatorColor.withAlphaComponent(0.72)
  }

  static func color(for tone: MenuBarTone, appearance: NSAppearance) -> NSColor {
    switch tone {
    case .neutral:
      .secondaryLabelColor
    case .progress:
      progress(for: appearance)
    case .verified:
      verified(for: appearance)
    case .attention:
      attention(for: appearance)
    case .stopped:
      stopped(for: appearance)
    case .unknown:
      .secondaryLabelColor
    }
  }
}

enum SafetyChecklistGeometry {
  static let width: CGFloat = 296
  static let height: CGFloat = 62
  static let titleHeight: CGFloat = 14
  static let itemTop: CGFloat = 22
  static let itemRowHeight: CGFloat = 19
  static let columnGap: CGFloat = 10
  static let horizontalInset: CGFloat = 2
  static let iconDiameter: CGFloat = 12
  static let iconTextGap: CGFloat = 6
}

@MainActor
enum MenuBarStatusTypography {
  static func attributedTitle(_ title: String) -> NSAttributedString {
    NSAttributedString(
      string: title,
      attributes: [
        .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold),
        .foregroundColor: NSColor.labelColor,
        .baselineOffset: 0.5,
      ]
    )
  }
}

@MainActor
enum MenuBarStatusVisuals {
  static func image(for style: MenuBarIconStyle) -> NSImage? {
    let image: NSImage?
    switch style {
    case .continuationMark:
      image = MenuBarIcon.load()?.copy() as? NSImage
    case .criticalWarning:
      let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
      image = NSImage(
        systemSymbolName: "exclamationmark.triangle.fill",
        accessibilityDescription: "보호 상태 확인 필요"
      )?.withSymbolConfiguration(configuration)
    }
    image?.isTemplate = true
    return image
  }
}

@MainActor
final class SafetyChecklistView: NSView {
  private(set) var presentation: SafetyChecklistPresentation?
  private(set) var tone: MenuBarTone = .neutral

  override var intrinsicContentSize: NSSize {
    NSSize(width: SafetyChecklistGeometry.width, height: SafetyChecklistGeometry.height)
  }

  override var isFlipped: Bool {
    true
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityIdentifier("runtinue.header.safetyChecklist")
  }

  convenience init() {
    self.init(
      frame: NSRect(
        origin: .zero,
        size: NSSize(
          width: SafetyChecklistGeometry.width,
          height: SafetyChecklistGeometry.height
        )
      )
    )
  }

  required init?(coder: NSCoder) {
    nil
  }

  func update(_ presentation: SafetyChecklistPresentation?, tone: MenuBarTone) {
    self.presentation = presentation
    self.tone = tone
    let description = presentation.map {
      ([$0.title] + $0.items.map(\.text)).joined(separator: ", ")
    }
    setAccessibilityLabel(description)
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard let presentation, !presentation.items.isEmpty else { return }

    drawTitle(presentation.title)
    for (item, frame) in zip(presentation.items, itemFrames(count: presentation.items.count)) {
      drawItem(item, in: frame)
    }
  }

  private func drawTitle(_ title: String) {
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
      .foregroundColor: RuntinuePalette.color(for: tone, appearance: effectiveAppearance),
    ]
    title.draw(
      in: NSRect(
        x: SafetyChecklistGeometry.horizontalInset,
        y: 0,
        width: bounds.width - (SafetyChecklistGeometry.horizontalInset * 2),
        height: SafetyChecklistGeometry.titleHeight
      ),
      withAttributes: attributes
    )
  }

  private func itemFrames(count: Int) -> [NSRect] {
    let contentWidth = bounds.width - (SafetyChecklistGeometry.horizontalInset * 2)
    if count <= 2 {
      return (0..<count).map { index in
        NSRect(
          x: SafetyChecklistGeometry.horizontalInset,
          y: SafetyChecklistGeometry.itemTop
            + CGFloat(index) * SafetyChecklistGeometry.itemRowHeight,
          width: contentWidth,
          height: SafetyChecklistGeometry.itemRowHeight
        )
      }
    }

    let columnWidth = (contentWidth - SafetyChecklistGeometry.columnGap) / 2
    return (0..<count).map { index in
      let column = index % 2
      let row = index / 2
      return NSRect(
        x: SafetyChecklistGeometry.horizontalInset
          + CGFloat(column) * (columnWidth + SafetyChecklistGeometry.columnGap),
        y: SafetyChecklistGeometry.itemTop
          + CGFloat(row) * SafetyChecklistGeometry.itemRowHeight,
        width: columnWidth,
        height: SafetyChecklistGeometry.itemRowHeight
      )
    }
  }

  private func drawItem(_ item: SafetyCheckItem, in frame: NSRect) {
    let iconFrame = NSRect(
      x: frame.minX,
      y: frame.minY + (frame.height - SafetyChecklistGeometry.iconDiameter) / 2,
      width: SafetyChecklistGeometry.iconDiameter,
      height: SafetyChecklistGeometry.iconDiameter
    )
    drawIcon(item.state, in: iconFrame)

    let textX = iconFrame.maxX + SafetyChecklistGeometry.iconTextGap
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 10, weight: .medium),
      .foregroundColor: textColor(for: item.state),
    ]
    item.text.draw(
      in: NSRect(
        x: textX,
        y: frame.minY + 1,
        width: frame.maxX - textX,
        height: frame.height - 1
      ),
      withAttributes: attributes
    )
  }

  private func drawIcon(_ state: SafetyCheckState, in frame: NSRect) {
    let center = NSPoint(x: frame.midX, y: frame.midY)
    let frame = NSRect(
      x: frame.minX + 0.5,
      y: frame.minY + 0.5,
      width: frame.width - 1,
      height: frame.height - 1
    )
    let circle = NSBezierPath(ovalIn: frame)
    circle.lineWidth = 1.25

    switch state {
    case .pending:
      NSColor.controlBackgroundColor.setFill()
      RuntinuePalette.subtleOutline.setStroke()
      circle.fill()
      circle.stroke()
    case .current:
      let color = RuntinuePalette.color(for: tone, appearance: effectiveAppearance)
      let surface =
        tone == .progress
        ? RuntinuePalette.brandSurface(for: effectiveAppearance)
        : color.withAlphaComponent(0.12)
      surface.setFill()
      color.setStroke()
      circle.fill()
      circle.stroke()
      color.setFill()
      let inset = frame.width * 0.32
      NSBezierPath(ovalIn: frame.insetBy(dx: inset, dy: inset)).fill()
    case .passed:
      let color =
        tone == .verified
        ? RuntinuePalette.verified(for: effectiveAppearance)
        : RuntinuePalette.progress(for: effectiveAppearance)
      color.setFill()
      circle.fill()
      drawCheckmark(center: center)
    case .failed:
      RuntinuePalette.stopped(for: effectiveAppearance).setFill()
      circle.fill()
      drawCross(center: center, color: .white)
    case .unknown:
      NSColor.controlBackgroundColor.setFill()
      NSColor.secondaryLabelColor.setStroke()
      circle.fill()
      circle.stroke()
      drawQuestionMark(center: center)
    case .verified:
      RuntinuePalette.verified(for: effectiveAppearance).setFill()
      circle.fill()
      drawCheckmark(center: center)
    }
  }

  private func textColor(for state: SafetyCheckState) -> NSColor {
    switch state {
    case .pending, .unknown:
      .secondaryLabelColor
    case .current, .passed, .failed, .verified:
      .labelColor
    }
  }

  private func drawCheckmark(center: NSPoint) {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: center.x - 2.2, y: center.y))
    path.line(to: NSPoint(x: center.x - 0.5, y: center.y + 1.6))
    path.line(to: NSPoint(x: center.x + 2.5, y: center.y - 2.1))
    path.lineWidth = 1.35
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    NSColor.white.setStroke()
    path.stroke()
  }

  private func drawCross(center: NSPoint, color: NSColor) {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: center.x - 1.8, y: center.y - 1.8))
    path.line(to: NSPoint(x: center.x + 1.8, y: center.y + 1.8))
    path.move(to: NSPoint(x: center.x - 1.8, y: center.y + 1.8))
    path.line(to: NSPoint(x: center.x + 1.8, y: center.y - 1.8))
    path.lineWidth = 1.25
    path.lineCapStyle = .round
    color.setStroke()
    path.stroke()
  }

  private func drawQuestionMark(center: NSPoint) {
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 6.5, weight: .bold),
      .foregroundColor: NSColor.secondaryLabelColor,
    ]
    let value = "?" as NSString
    let size = value.size(withAttributes: attributes)
    value.draw(
      at: NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2),
      withAttributes: attributes
    )
  }
}

@MainActor
final class ProtectionStatusHeaderView: NSView {
  private static let width: CGFloat = 320
  private let iconView = NSImageView()
  private let headlineLabel = NSTextField(labelWithString: "")
  private let guidanceLabel = NSTextField(labelWithString: "")
  private let detailLabel = NSTextField(labelWithString: "")
  private let checklistView = SafetyChecklistView()
  private let contentStack = NSStackView()

  override var intrinsicContentSize: NSSize {
    let height: CGFloat
    if !checklistView.isHidden {
      height = detailLabel.isHidden ? 130 : 158
    } else if !detailLabel.isHidden {
      height = 92
    } else {
      height = 68
    }
    return NSSize(width: Self.width, height: height)
  }

  convenience init() {
    self.init(frame: NSRect(origin: .zero, size: NSSize(width: Self.width, height: 92)))
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    configure()
  }

  required init?(coder: NSCoder) {
    nil
  }

  func update(_ presentation: MenuBarPresentation) {
    iconView.image = MenuBarStatusVisuals.image(for: presentation.iconStyle)
    headlineLabel.stringValue = presentation.headline
    guidanceLabel.stringValue = presentation.guidance
    guidanceLabel.textColor = RuntinuePalette.color(
      for: presentation.tone,
      appearance: effectiveAppearance
    )
    detailLabel.stringValue = presentation.detail
    detailLabel.isHidden = presentation.detail.isEmpty
    checklistView.update(presentation.safetyChecklist, tone: presentation.tone)
    checklistView.isHidden = presentation.safetyChecklist == nil
    setAccessibilityLabel(
      [presentation.headline, presentation.guidance, presentation.detail]
        .filter { !$0.isEmpty }
        .joined(separator: ", ")
    )
    invalidateIntrinsicContentSize()
    setFrameSize(intrinsicContentSize)
    needsLayout = true
  }

  private func configure() {
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityIdentifier("runtinue.header")

    iconView.imageScaling = .scaleProportionallyDown
    iconView.contentTintColor = .labelColor
    iconView.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      iconView.widthAnchor.constraint(equalToConstant: 24),
      iconView.heightAnchor.constraint(equalToConstant: 24),
    ])

    headlineLabel.font = .systemFont(ofSize: 14, weight: .semibold)
    headlineLabel.textColor = .labelColor
    headlineLabel.lineBreakMode = .byTruncatingTail
    headlineLabel.setAccessibilityIdentifier("runtinue.header.headline")

    guidanceLabel.font = .systemFont(ofSize: 12, weight: .semibold)
    guidanceLabel.lineBreakMode = .byTruncatingTail
    guidanceLabel.setAccessibilityIdentifier("runtinue.header.guidance")

    detailLabel.font = .systemFont(ofSize: 10.5, weight: .regular)
    detailLabel.textColor = .secondaryLabelColor
    detailLabel.lineBreakMode = .byWordWrapping
    detailLabel.maximumNumberOfLines = 2
    detailLabel.setAccessibilityIdentifier("runtinue.header.detail")

    let titleStack = NSStackView(views: [headlineLabel, guidanceLabel])
    titleStack.orientation = .vertical
    titleStack.alignment = .leading
    titleStack.spacing = 2

    let topRow = NSStackView(views: [iconView, titleStack])
    topRow.orientation = .horizontal
    topRow.alignment = .top
    topRow.spacing = 9

    contentStack.orientation = .vertical
    contentStack.alignment = .leading
    contentStack.spacing = 6
    contentStack.addArrangedSubview(topRow)
    contentStack.addArrangedSubview(detailLabel)
    contentStack.addArrangedSubview(checklistView)
    addSubview(contentStack)

    contentStack.translatesAutoresizingMaskIntoConstraints = false
    checklistView.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
      contentStack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
      contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
      checklistView.widthAnchor.constraint(equalToConstant: SafetyChecklistGeometry.width),
      checklistView.heightAnchor.constraint(equalToConstant: SafetyChecklistGeometry.height),
    ])
  }
}
