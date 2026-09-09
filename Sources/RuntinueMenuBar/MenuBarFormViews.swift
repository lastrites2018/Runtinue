import AppKit
import RuntinueUserSupport

@MainActor
final class TripConfigurationView: NSView, NSTextFieldDelegate {
  private let targetPopUp = NSPopUpButton()
  private let hotspotLabel = NSTextField(labelWithString: L("핫스팟 이름", "Hotspot name"))
  private let hotspotField = NSTextField(string: "")
  private let useCurrentWiFiButton = NSButton(
    title: L("현재 이름 사용", "Use current"), target: nil, action: nil)
  private let currentWiFiSSID: String?
  private let hotspotConfirmation = NSButton(
    checkboxWithTitle: L("내 휴대전화 핫스팟입니다", "This is my phone's hotspot"), target: nil, action: nil
  )
  private var confirmedSSID: String?
  private let protectionField = MinutesField(90)
  private let handoffTimeoutField = MinutesField(15)

  init(
    rememberedHotspotSSID: String? = nil, currentWiFiSSID: String? = nil,
    confirmedHotspotSSID: String? = nil
  ) {
    self.currentWiFiSSID = currentWiFiSSID.flatMap {
      try? TripFormInput.validatedHotspotSSID($0)
    }
    super.init(frame: NSRect(x: 0, y: 0, width: 420, height: 265))

    targetPopUp.addItems(withTitles: [
      L("Wi-Fi 핫스팟", "Wi-Fi hotspot"), L("USB 테더링", "USB tethering"),
    ])
    targetPopUp.target = self
    targetPopUp.action = #selector(targetChanged)
    hotspotField.placeholderString = L("예: 내 iPhone", "Example: My iPhone")
    hotspotField.stringValue = rememberedHotspotSSID ?? ""
    hotspotField.delegate = self
    hotspotConfirmation.target = self
    hotspotConfirmation.action = #selector(confirmHotspot)
    hotspotConfirmation.setAccessibilityIdentifier("runtinue.trip.confirmHotspot")
    if let rememberedHotspotSSID, rememberedHotspotSSID == confirmedHotspotSSID {
      confirmedSSID = rememberedHotspotSSID
      hotspotConfirmation.state = .on
    }
    targetPopUp.setAccessibilityIdentifier("runtinue.trip.target")
    hotspotField.setAccessibilityIdentifier("runtinue.trip.hotspot")
    protectionField.setAccessibilityIdentifier("runtinue.trip.duration")
    handoffTimeoutField.setAccessibilityIdentifier("runtinue.trip.handoff")

    let currentWiFiLabel = NSTextField(
      labelWithString: self.currentWiFiSSID ?? L("이름 확인 불가", "Name unavailable")
    )
    currentWiFiLabel.lineBreakMode = .byTruncatingMiddle
    currentWiFiLabel.toolTip = self.currentWiFiSSID
    currentWiFiLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    currentWiFiLabel.setAccessibilityIdentifier("runtinue.trip.currentWiFi")
    useCurrentWiFiButton.target = self
    useCurrentWiFiButton.action = #selector(useCurrentWiFi)
    useCurrentWiFiButton.toolTip = L(
      "현재 Wi-Fi 이름을 핫스팟 이름으로 사용", "Use the connected Wi-Fi name as the hotspot")
    useCurrentWiFiButton.setAccessibilityLabel(L("현재 Wi-Fi 이름 사용", "Use current Wi-Fi name"))
    useCurrentWiFiButton.setAccessibilityIdentifier("runtinue.trip.useCurrentWiFi")
    let currentWiFiRow = NSStackView(views: [currentWiFiLabel, useCurrentWiFiButton])
    currentWiFiRow.orientation = .horizontal
    currentWiFiRow.spacing = 6
    currentWiFiRow.widthAnchor.constraint(equalToConstant: 230).isActive = true

    let stack = makeFormStack(
      rows: [
        makeFormRow(label: L("연결 방식", "Connection"), control: targetPopUp),
        makeFormRow(label: hotspotLabel, control: hotspotField),
        makeFormRow(label: L("현재 Wi-Fi", "Connected Wi-Fi"), control: currentWiFiRow),
        makeFormRow(label: L("대상 확인", "Confirm hotspot"), control: hotspotConfirmation),
        makeFormRow(label: L("실행 유지 시간(분)", "Keep awake (min)"), control: protectionField),
        makeFormRow(label: L("연결 대기 한도(분)", "Connection wait (min)"), control: handoffTimeoutField),
      ],
      note: L(
        "핫스팟 연결을 기다린 뒤 실행을 유지합니다. 연결 대기 한도 안에 연결되지 않으면 시작을 취소합니다. ",
        "Keeps your Mac awake after connecting. Cancels the start if the connection wait expires. ")
        + L(
          "USB 테더링은 시작 후 연결 전환이 필요합니다.", "For USB tethering, switch the connection after starting.")
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
      handoffTimeoutMinutes: handoffTimeoutField.stringValue,
      hotspotConfirmed: hotspotConfirmation.state == .on
        && confirmedSSID == (try? TripFormInput.validatedHotspotSSID(hotspotField.stringValue))
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
    clearChangedConfirmation()
  }

  @objc private func confirmHotspot() {
    confirmedSSID =
      hotspotConfirmation.state == .on
      ? try? TripFormInput.validatedHotspotSSID(hotspotField.stringValue) : nil
  }

  func controlTextDidChange(_ notification: Notification) {
    clearChangedConfirmation()
  }

  private func clearChangedConfirmation() {
    if confirmedSSID != (try? TripFormInput.validatedHotspotSSID(hotspotField.stringValue)) {
      confirmedSSID = nil
      hotspotConfirmation.state = .off
    }
  }

  @objc private func targetChanged() {
    let requiresSSID = targetPopUp.indexOfSelectedItem == 0
    hotspotLabel.textColor = requiresSSID ? .labelColor : .secondaryLabelColor
    hotspotField.isEnabled = requiresSSID
    useCurrentWiFiButton.isEnabled = requiresSSID && currentWiFiSSID != nil
    hotspotConfirmation.isEnabled = requiresSSID
  }
}

@MainActor
final class AdaptiveConfigurationView: NSView {
  private let idleGraceField = MinutesField(2, maximum: 60)
  private let maximumProtectionField = MinutesField(480)

  override init(frame frameRect: NSRect) {
    super.init(frame: NSRect(x: 0, y: 0, width: 420, height: 140))
    idleGraceField.setAccessibilityIdentifier("runtinue.adaptive.grace")
    maximumProtectionField.setAccessibilityIdentifier("runtinue.adaptive.duration")

    let stack = makeFormStack(
      rows: [
        makeFormRow(label: L("활동 종료 후 대기(분)", "Idle wait (min)"), control: idleGraceField),
        makeFormRow(label: L("실행 유지 한도(분)", "Maximum time (min)"), control: maximumProtectionField),
      ],
      note: L(
        "연동한 작업 도구가 활동을 알리는 동안 실행을 유지합니다. 활동이 멈추면 대기 시간 뒤 수면을 허용합니다. 작업 도구 연동이 필요합니다.",
        "Keeps your Mac awake while an integrated tool reports activity. Allows sleep after the idle wait. Requires a connected activity tool."
      )
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
  private let maximumProtectionField = MinutesField(120)
  private let closedLidButton = NSButton(
    checkboxWithTitle: L("덮개를 닫아도 실행 유지", "Keep awake with lid closed"),
    target: nil,
    action: nil
  )

  override init(frame frameRect: NSRect) {
    super.init(frame: NSRect(x: 0, y: 0, width: 420, height: 140))
    maximumProtectionField.setAccessibilityIdentifier("runtinue.desk.duration")
    closedLidButton.setAccessibilityIdentifier("runtinue.desk.closedLid")

    let stack = makeFormStack(
      rows: [
        makeFormRow(label: L("실행 유지 한도(분)", "Maximum time (min)"), control: maximumProtectionField),
        makeFormRow(label: L("사용 방식", "Lid behavior"), control: closedLidButton),
      ],
      note: L(
        "설정한 시간 동안 실행을 유지합니다. 위 항목을 끄면 덮개를 열어 둬야 합니다. 시간이 끝나면 수면을 허용합니다.",
        "Keeps your Mac awake for the set time, then allows sleep. Leave the lid open when the option above is off."
      )
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
  noteLabel.widthAnchor.constraint(equalToConstant: 400).isActive = true
  return stack
}

@MainActor
private func makeFormRow(label: String, control: NSView) -> NSView {
  makeFormRow(label: NSTextField(labelWithString: label), control: control)
}

@MainActor
private func makeFormRow(label: NSTextField, control: NSView) -> NSView {
  control.setAccessibilityLabel(label.stringValue)
  label.alignment = .left
  label.lineBreakMode = .byWordWrapping
  label.maximumNumberOfLines = 0
  label.preferredMaxLayoutWidth = 150
  label.widthAnchor.constraint(equalToConstant: 155).isActive = true
  control.widthAnchor.constraint(equalToConstant: control is MinutesField ? 76 : 230).isActive =
    true

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
