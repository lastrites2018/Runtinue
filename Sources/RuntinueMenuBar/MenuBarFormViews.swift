import AppKit

@MainActor
final class TripConfigurationView: NSView {
  private let targetPopUp = NSPopUpButton()
  private let hotspotLabel = NSTextField(labelWithString: "핫스팟 이름")
  private let hotspotField = NSTextField(string: "")
  private let useCurrentWiFiButton = NSButton(title: "사용", target: nil, action: nil)
  private let currentWiFiSSID: String?
  private let protectionField = NSTextField(string: "90")
  private let handoffTimeoutField = NSTextField(string: "15")

  init(rememberedHotspotSSID: String? = nil, currentWiFiSSID: String? = nil) {
    self.currentWiFiSSID = currentWiFiSSID.flatMap {
      try? TripFormInput.validatedHotspotSSID($0)
    }
    super.init(frame: NSRect(x: 0, y: 0, width: 390, height: 235))

    targetPopUp.addItems(withTitles: ["Wi-Fi 핫스팟", "USB 테더링"])
    targetPopUp.target = self
    targetPopUp.action = #selector(targetChanged)
    hotspotField.placeholderString = "예: iPhone"
    hotspotField.stringValue = rememberedHotspotSSID ?? ""
    targetPopUp.setAccessibilityIdentifier("runtinue.trip.target")
    hotspotField.setAccessibilityIdentifier("runtinue.trip.hotspot")
    protectionField.setAccessibilityIdentifier("runtinue.trip.duration")
    handoffTimeoutField.setAccessibilityIdentifier("runtinue.trip.handoff")

    let currentWiFiLabel = NSTextField(
      labelWithString: self.currentWiFiSSID ?? "이름을 읽을 수 없음"
    )
    currentWiFiLabel.lineBreakMode = .byTruncatingMiddle
    currentWiFiLabel.toolTip = self.currentWiFiSSID
    currentWiFiLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    currentWiFiLabel.setAccessibilityIdentifier("runtinue.trip.currentWiFi")
    useCurrentWiFiButton.target = self
    useCurrentWiFiButton.action = #selector(useCurrentWiFi)
    useCurrentWiFiButton.toolTip = "현재 Wi-Fi 이름을 핫스팟 이름으로 사용"
    useCurrentWiFiButton.setAccessibilityLabel("현재 Wi-Fi 이름 사용")
    useCurrentWiFiButton.setAccessibilityIdentifier("runtinue.trip.useCurrentWiFi")
    let currentWiFiRow = NSStackView(views: [currentWiFiLabel, useCurrentWiFiButton])
    currentWiFiRow.orientation = .horizontal
    currentWiFiRow.spacing = 6
    currentWiFiRow.widthAnchor.constraint(equalToConstant: 210).isActive = true

    let stack = makeFormStack(
      rows: [
        makeFormRow(label: "연결 방식", control: targetPopUp),
        makeFormRow(label: hotspotLabel, control: hotspotField),
        makeFormRow(label: "현재 Wi-Fi", control: currentWiFiRow),
        makeFormRow(label: "보호 시간(분)", control: protectionField),
        makeFormRow(label: "연결 대기(분)", control: handoffTimeoutField),
      ],
      note: "핫스팟에 연결한 뒤 시작해도 됩니다. 입력한 이름은 다음에도 기억합니다. "
        + "USB 테더링은 연결 전환을 확인합니다."
    )
    addPinnedSubview(stack)
    targetChanged()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  var input: TripFormInput {
    TripFormInput(
      target: targetPopUp.indexOfSelectedItem == 1 ? .usbTethering : .wifiHotspot,
      hotspotSSID: hotspotField.stringValue,
      protectionMinutes: protectionField.stringValue,
      handoffTimeoutMinutes: handoffTimeoutField.stringValue
    )
  }

  var initialFirstResponder: NSView {
    hotspotField
  }

  @objc private func useCurrentWiFi() {
    guard targetPopUp.indexOfSelectedItem == 0, let currentWiFiSSID else {
      return
    }
    hotspotField.stringValue = currentWiFiSSID
  }

  @objc private func targetChanged() {
    let requiresSSID = targetPopUp.indexOfSelectedItem == 0
    hotspotLabel.textColor = requiresSSID ? .labelColor : .secondaryLabelColor
    hotspotField.isEnabled = requiresSSID
    useCurrentWiFiButton.isEnabled = requiresSSID && currentWiFiSSID != nil
  }
}

@MainActor
final class AdaptiveConfigurationView: NSView {
  private let idleGraceField = NSTextField(string: "2")
  private let maximumProtectionField = NSTextField(string: "480")

  override init(frame frameRect: NSRect) {
    super.init(frame: NSRect(x: 0, y: 0, width: 390, height: 110))
    idleGraceField.setAccessibilityIdentifier("runtinue.adaptive.grace")
    maximumProtectionField.setAccessibilityIdentifier("runtinue.adaptive.duration")

    let stack = makeFormStack(
      rows: [
        makeFormRow(label: "활동 종료 유예(분)", control: idleGraceField),
        makeFormRow(label: "최대 보호 시간(분)", control: maximumProtectionField),
      ],
      note: "서명된 activity hook이 도착할 때 보호하고, 활동이 멈추면 유예 시간 뒤 해제합니다."
    )
    addPinnedSubview(stack)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  var input: AdaptiveFormInput {
    AdaptiveFormInput(
      idleGraceMinutes: idleGraceField.stringValue,
      maximumProtectionMinutes: maximumProtectionField.stringValue
    )
  }

  var initialFirstResponder: NSView {
    idleGraceField
  }
}

@MainActor
final class DeskConfigurationView: NSView {
  private let maximumProtectionField = NSTextField(string: "120")
  private let closedLidButton = NSButton(
    checkboxWithTitle: "덮개를 닫은 상태도 허용",
    target: nil,
    action: nil
  )

  override init(frame frameRect: NSRect) {
    super.init(frame: NSRect(x: 0, y: 0, width: 390, height: 115))
    maximumProtectionField.setAccessibilityIdentifier("runtinue.desk.duration")
    closedLidButton.setAccessibilityIdentifier("runtinue.desk.closedLid")

    let stack = makeFormStack(
      rows: [
        makeFormRow(label: "최대 보호 시간(분)", control: maximumProtectionField),
        makeFormRow(label: "사용 방식", control: closedLidButton),
      ],
      note: "덮개 닫기를 허용하지 않으면 자동 해제되는 일반 macOS assertion만 사용합니다."
    )
    addPinnedSubview(stack)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  var input: DeskFormInput {
    DeskFormInput(
      maximumProtectionMinutes: maximumProtectionField.stringValue,
      allowClosedLid: closedLidButton.state == .on
    )
  }

  var initialFirstResponder: NSView {
    maximumProtectionField
  }
}

@MainActor
private func makeFormStack(
  rows: [NSView],
  note: String
) -> NSStackView {
  let noteLabel = NSTextField(wrappingLabelWithString: note)
  noteLabel.textColor = .secondaryLabelColor
  noteLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

  let stack = NSStackView(views: rows + [noteLabel])
  stack.orientation = .vertical
  stack.alignment = .leading
  stack.spacing = 8
  stack.translatesAutoresizingMaskIntoConstraints = false
  noteLabel.widthAnchor.constraint(equalToConstant: 370).isActive = true
  return stack
}

@MainActor
private func makeFormRow(label: String, control: NSView) -> NSView {
  makeFormRow(label: NSTextField(labelWithString: label), control: control)
}

@MainActor
private func makeFormRow(label: NSTextField, control: NSView) -> NSView {
  control.setAccessibilityLabel(label.stringValue)
  label.alignment = .right
  label.widthAnchor.constraint(equalToConstant: 135).isActive = true
  control.widthAnchor.constraint(greaterThanOrEqualToConstant: 210).isActive = true

  let row = NSStackView(views: [label, control])
  row.orientation = .horizontal
  row.alignment = .centerY
  row.spacing = 10
  return row
}

@MainActor
extension NSView {
  fileprivate func addPinnedSubview(_ subview: NSView) {
    addSubview(subview)
    NSLayoutConstraint.activate([
      subview.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
      subview.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
      subview.topAnchor.constraint(equalTo: topAnchor, constant: 8),
    ])
  }
}
