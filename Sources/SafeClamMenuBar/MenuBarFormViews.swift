import AppKit

@MainActor
final class TripConfigurationView: NSView {
  private let targetPopUp = NSPopUpButton()
  private let hotspotLabel = NSTextField(labelWithString: "핫스팟 이름")
  private let hotspotField = NSTextField(string: "")
  private let protectionField = NSTextField(string: "90")
  private let handoffTimeoutField = NSTextField(string: "15")

  override init(frame frameRect: NSRect) {
    super.init(frame: NSRect(x: 0, y: 0, width: 390, height: 170))

    targetPopUp.addItems(withTitles: ["Wi-Fi 핫스팟", "USB 테더링"])
    targetPopUp.target = self
    targetPopUp.action = #selector(targetChanged)
    hotspotField.placeholderString = "예: iPhone"
    targetPopUp.setAccessibilityIdentifier("safeclam.trip.target")
    hotspotField.setAccessibilityIdentifier("safeclam.trip.hotspot")
    protectionField.setAccessibilityIdentifier("safeclam.trip.duration")
    handoffTimeoutField.setAccessibilityIdentifier("safeclam.trip.handoff")

    let stack = makeFormStack(
      rows: [
        makeFormRow(label: "전환 대상", control: targetPopUp),
        makeFormRow(label: hotspotLabel, control: hotspotField),
        makeFormRow(label: "보호 시간(분)", control: protectionField),
        makeFormRow(label: "전환 대기(분)", control: handoffTimeoutField),
      ],
      note: "핫스팟 또는 USB 전환과 인터넷 도달이 확인된 뒤에만 보호를 시작합니다."
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

  @objc private func targetChanged() {
    let requiresSSID = targetPopUp.indexOfSelectedItem == 0
    hotspotLabel.textColor = requiresSSID ? .labelColor : .secondaryLabelColor
    hotspotField.isEnabled = requiresSSID
  }
}

@MainActor
final class AdaptiveConfigurationView: NSView {
  private let idleGraceField = NSTextField(string: "2")
  private let maximumProtectionField = NSTextField(string: "480")

  override init(frame frameRect: NSRect) {
    super.init(frame: NSRect(x: 0, y: 0, width: 390, height: 110))
    idleGraceField.setAccessibilityIdentifier("safeclam.adaptive.grace")
    maximumProtectionField.setAccessibilityIdentifier("safeclam.adaptive.duration")

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
    maximumProtectionField.setAccessibilityIdentifier("safeclam.desk.duration")
    closedLidButton.setAccessibilityIdentifier("safeclam.desk.closedLid")

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
