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

  static var routeBase: NSColor {
    NSColor.separatorColor.withAlphaComponent(0.72)
  }

  static func color(for tone: MenuBarTone, appearance: NSAppearance) -> NSColor {
    switch tone {
    case .neutral:
      .secondaryLabelColor
    case .progress:
      progress(for: appearance)
    case .verified:
      .systemGreen
    case .attention:
      .systemOrange
    case .stopped:
      .systemRed
    case .unknown:
      .secondaryLabelColor
    }
  }
}

enum RuntinueGeometry {
  // RuntinueTemplate.png의 50% 알파 실루엣을 기준으로 측정했다.
  // 유효 높이 916px에서 화살표 축은 72px이다.
  static let sourceSilhouetteHeight: CGFloat = 916
  static let sourceArrowShaftWidth: CGFloat = 72
  static let flowlineHeight: CGFloat = 46
  static let baseStroke = flowlineHeight * sourceArrowShaftWidth / sourceSilhouetteHeight
  static let nodeDiameter = baseStroke * 2.05
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
final class FlowlineRouteView: NSView {
  private(set) var presentation: FlowlinePresentation?
  private(set) var tone: MenuBarTone = .neutral

  override var intrinsicContentSize: NSSize {
    NSSize(width: 296, height: RuntinueGeometry.flowlineHeight)
  }

  override var isFlipped: Bool {
    false
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityIdentifier("runtinue.header.flowline")
  }

  convenience init() {
    self.init(
      frame: NSRect(
        origin: .zero,
        size: NSSize(width: 296, height: RuntinueGeometry.flowlineHeight)
      )
    )
  }

  required init?(coder: NSCoder) {
    nil
  }

  func update(_ presentation: FlowlinePresentation?, tone: MenuBarTone) {
    self.presentation = presentation
    self.tone = tone
    let description = presentation?.steps.map {
      "\($0.label) \(Self.accessibilityDescription(for: $0.state))"
    }.joined(separator: ", ")
    setAccessibilityLabel(description.map { "보호 진행 상태, \($0)" })
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard let presentation, !presentation.steps.isEmpty else { return }

    let nodePositions = positions(count: presentation.steps.count)
    let routeY = bounds.height - 14
    let basePath = NSBezierPath()
    basePath.move(to: NSPoint(x: nodePositions[0], y: routeY))
    basePath.line(to: NSPoint(x: nodePositions[nodePositions.count - 1], y: routeY))
    basePath.lineWidth = RuntinueGeometry.baseStroke
    basePath.lineCapStyle = .round
    RuntinuePalette.routeBase.setStroke()
    basePath.stroke()

    for index in 1..<nodePositions.count {
      let step = presentation.steps[index]
      guard step.state != .pending && step.state != .unknown else { continue }
      let segment = NSBezierPath()
      segment.move(to: NSPoint(x: nodePositions[index - 1], y: routeY))
      segment.line(to: NSPoint(x: nodePositions[index], y: routeY))
      segment.lineWidth = RuntinueGeometry.baseStroke
      segment.lineCapStyle = .round
      segmentColor(for: step.state).setStroke()
      segment.stroke()
    }

    let labelWidth = max(58, bounds.width / CGFloat(presentation.steps.count))
    for (index, step) in presentation.steps.enumerated() {
      let center = NSPoint(x: nodePositions[index], y: routeY)
      drawNode(step.state, center: center)
      drawLabel(step.label, centerX: center.x, width: labelWidth)
    }
  }

  private func positions(count: Int) -> [CGFloat] {
    guard count > 1 else { return [bounds.midX] }
    let inset: CGFloat = count == 2 ? 52 : 26
    let interval = (bounds.width - (inset * 2)) / CGFloat(count - 1)
    return (0..<count).map { inset + CGFloat($0) * interval }
  }

  private func drawLabel(_ label: String, centerX: CGFloat, width: CGFloat) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 9.5, weight: .medium),
      .foregroundColor: NSColor.secondaryLabelColor,
      .paragraphStyle: paragraph,
    ]
    let originX = min(max(0, centerX - width / 2), bounds.width - width)
    label.draw(
      in: NSRect(x: originX, y: 0, width: width, height: 13),
      withAttributes: attributes
    )
  }

  private func drawNode(_ state: FlowlineNodeState, center: NSPoint) {
    let radius = RuntinueGeometry.nodeDiameter / 2
    let frame = NSRect(
      x: center.x - radius,
      y: center.y - radius,
      width: radius * 2,
      height: radius * 2
    )
    let circle = NSBezierPath(ovalIn: frame)
    circle.lineWidth = RuntinueGeometry.baseStroke * 0.42

    switch state {
    case .pending:
      NSColor.controlBackgroundColor.setFill()
      RuntinuePalette.routeBase.setStroke()
      circle.fill()
      circle.stroke()
    case .current:
      let color = RuntinuePalette.color(for: tone, appearance: effectiveAppearance)
      let surface = tone == .progress
        ? RuntinuePalette.brandSurface(for: effectiveAppearance)
        : color.withAlphaComponent(0.12)
      surface.setFill()
      color.setStroke()
      circle.fill()
      circle.stroke()
      color.setFill()
      let inset = RuntinueGeometry.nodeDiameter * 0.31
      NSBezierPath(ovalIn: frame.insetBy(dx: inset, dy: inset)).fill()
    case .passed:
      nodeColor(for: state).setFill()
      circle.fill()
    case .failed:
      NSColor.systemRed.setFill()
      circle.fill()
      drawCross(center: center, color: .white)
    case .unknown:
      NSColor.controlBackgroundColor.setFill()
      NSColor.secondaryLabelColor.setStroke()
      circle.fill()
      circle.stroke()
      drawQuestionMark(center: center)
    case .verified:
      NSColor.systemGreen.setFill()
      circle.fill()
      drawCheckmark(center: center)
    }
  }

  private func nodeColor(for state: FlowlineNodeState) -> NSColor {
    switch state {
    case .failed:
      .systemRed
    case .verified:
      .systemGreen
    case .passed:
      RuntinuePalette.progress(for: effectiveAppearance)
    default:
      RuntinuePalette.color(for: tone, appearance: effectiveAppearance)
    }
  }

  private func segmentColor(for state: FlowlineNodeState) -> NSColor {
    switch state {
    case .failed:
      .systemRed
    case .current:
      RuntinuePalette.color(for: tone, appearance: effectiveAppearance)
    default:
      RuntinuePalette.progress(for: effectiveAppearance)
    }
  }

  private func drawCheckmark(center: NSPoint) {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: center.x - 2.2, y: center.y))
    path.line(to: NSPoint(x: center.x - 0.5, y: center.y - 1.6))
    path.line(to: NSPoint(x: center.x + 2.5, y: center.y + 2.1))
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
      at: NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2 - 0.5),
      withAttributes: attributes
    )
  }

  private static func accessibilityDescription(for state: FlowlineNodeState) -> String {
    switch state {
    case .pending: "대기"
    case .current: "진행 중"
    case .passed: "통과"
    case .failed: "실패"
    case .unknown: "확인 불가"
    case .verified: "검증 완료"
    }
  }
}

@MainActor
final class ProtectionStatusHeaderView: NSView {
  private static let width: CGFloat = 320
  private let iconView = NSImageView()
  private let headlineLabel = NSTextField(labelWithString: "")
  private let guidanceLabel = NSTextField(labelWithString: "")
  private let detailLabel = NSTextField(labelWithString: "")
  private let routeView = FlowlineRouteView()
  private let contentStack = NSStackView()

  override var intrinsicContentSize: NSSize {
    let height: CGFloat
    if !routeView.isHidden {
      height = 142
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
    routeView.update(presentation.flowline, tone: presentation.tone)
    routeView.isHidden = presentation.flowline == nil
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
    contentStack.addArrangedSubview(routeView)
    addSubview(contentStack)

    contentStack.translatesAutoresizingMaskIntoConstraints = false
    routeView.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
      contentStack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
      contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
      routeView.widthAnchor.constraint(equalToConstant: 296),
      routeView.heightAnchor.constraint(equalToConstant: RuntinueGeometry.flowlineHeight),
    ])
  }
}
