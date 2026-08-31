import AppKit
import CoreLocation
import Foundation
import SafeClamIPC
import SafeClamSystem
import SafeClamUserSupport

@main
enum SafeClamMenuBarMain {
  @MainActor
  static func main() {
    let application = NSApplication.shared
    let delegate = MenuBarDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    application.run()
    withExtendedLifetime(delegate) {}
  }
}

@MainActor
private final class MenuBarDelegate: NSObject, NSApplicationDelegate {
  private let client = SupervisorXPCClient()
  private let networkProbe = MacNetworkProbe()
  private let wifiAuthorization = WiFiLocationAuthorization()
  private let statusItem = NSStatusBar.system.statusItem(
    withLength: NSStatusItem.variableLength
  )
  private let summaryItem = NSMenuItem(title: "상태 확인 중", action: nil, keyEquivalent: "")
  private let detailItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
  private let wifiPermissionItem = NSMenuItem(
    title: "Wi-Fi 감지 권한 확인 중",
    action: nil,
    keyEquivalent: ""
  )
  private let startTripItem = NSMenuItem(
    title: "통근 보호 시작…",
    action: nil,
    keyEquivalent: ""
  )
  private let startAdaptiveItem = NSMenuItem(
    title: "Adaptive 시작…",
    action: nil,
    keyEquivalent: ""
  )
  private let startDeskItem = NSMenuItem(
    title: "Desk 시작…",
    action: nil,
    keyEquivalent: ""
  )
  private let stopItem = NSMenuItem(title: "현재 모드 중단", action: nil, keyEquivalent: "")
  private let diagnosticsItem = NSMenuItem(
    title: "진단 정보 보기…",
    action: nil,
    keyEquivalent: ""
  )
  private let historyItem = NSMenuItem(
    title: "최근 기록 보기…",
    action: nil,
    keyEquivalent: ""
  )
  private let eventsItem = NSMenuItem(title: "통근 관찰 요약…", action: nil, keyEquivalent: "")

  private var timer: Timer?
  private let refreshController = MenuBarRefreshController()
  private let commandController = MenuBarCommandController()
  private var informationTask: Task<Void, Never>?

  func applicationDidFinishLaunching(_ notification: Notification) {
    configureMenu()
    refresh()
    let refreshTimer = Timer(timeInterval: 5, repeats: true) {
      [weak self] _ in
      Task { @MainActor in
        self?.refresh()
      }
    }
    RunLoop.main.add(refreshTimer, forMode: .common)
    timer = refreshTimer
  }

  func applicationWillTerminate(_ notification: Notification) {
    timer?.invalidate()
    refreshController.cancel()
    commandController.cancel()
    informationTask?.cancel()
  }

  private func configureMenu() {
    statusItem.button?.title = "SafeClam"
    statusItem.button?.toolTip = "SafeClam 기기 우선 보호 상태"
    statusItem.button?.setAccessibilityIdentifier("safeclam.status")

    summaryItem.isEnabled = false
    detailItem.isEnabled = false
    wifiPermissionItem.target = self
    wifiPermissionItem.action = #selector(requestWiFiPermission)
    startTripItem.target = self
    startTripItem.action = #selector(startTrip)
    startAdaptiveItem.target = self
    startAdaptiveItem.action = #selector(startAdaptive)
    startDeskItem.target = self
    startDeskItem.action = #selector(startDesk)
    stopItem.target = self
    stopItem.action = #selector(stopCurrentMode)
    diagnosticsItem.target = self
    diagnosticsItem.action = #selector(showDiagnostics)
    historyItem.target = self
    historyItem.action = #selector(showHistory)
    eventsItem.target = self
    eventsItem.action = #selector(showEvents)
    startTripItem.identifier = NSUserInterfaceItemIdentifier("safeclam.startTrip")
    startAdaptiveItem.identifier = NSUserInterfaceItemIdentifier("safeclam.startAdaptive")
    startDeskItem.identifier = NSUserInterfaceItemIdentifier("safeclam.startDesk")
    stopItem.identifier = NSUserInterfaceItemIdentifier("safeclam.stop")

    let refreshItem = NSMenuItem(
      title: "새로 고침",
      action: #selector(refreshFromMenu),
      keyEquivalent: "r"
    )
    refreshItem.target = self
    let quitItem = NSMenuItem(
      title: "메뉴바 종료",
      action: #selector(quit),
      keyEquivalent: "q"
    )
    quitItem.target = self

    let menu = NSMenu()
    menu.autoenablesItems = false
    menu.addItem(summaryItem)
    menu.addItem(detailItem)
    menu.addItem(wifiPermissionItem)
    menu.addItem(.separator())
    menu.addItem(startTripItem)
    menu.addItem(startAdaptiveItem)
    menu.addItem(startDeskItem)
    menu.addItem(stopItem)
    menu.addItem(.separator())
    menu.addItem(diagnosticsItem)
    menu.addItem(historyItem)
    menu.addItem(eventsItem)
    menu.addItem(refreshItem)
    menu.addItem(.separator())
    menu.addItem(quitItem)
    statusItem.menu = menu

    updateCommandAvailability(status: nil)
  }

  private func refresh() {
    updateWiFiPermissionItem()
    guard !commandController.isCommandInFlight else {
      return
    }
    refreshController.refresh(
      observeWiFi: { [weak self] in
        guard let self, wifiAuthorization.isAuthorized else {
          return MenuBarWiFiObservation(ssid: nil, interfaceName: nil)
        }
        let network = await networkProbe.snapshot()
        return MenuBarWiFiObservation(
          ssid: network.ssid,
          interfaceName: network.interfaceName
        )
      },
      submitWiFi: { [client] observation in
        try await client.submitWiFiObservation(
          ssid: observation.ssid,
          interfaceName: observation.interfaceName
        )
      },
      readStatus: { [client] in
        try await client.status()
      },
      render: { [weak self] status in
        self?.render(status)
      }
    )
  }

  private func updateWiFiPermissionItem() {
    switch wifiAuthorization.status {
    case .authorizedAlways:
      wifiPermissionItem.title = "Wi-Fi 감지 권한 허용됨"
      wifiPermissionItem.isEnabled = false
    case .notDetermined:
      wifiPermissionItem.title = "Wi-Fi 감지 권한 허용"
      wifiPermissionItem.isEnabled = true
    case .denied, .restricted:
      wifiPermissionItem.title = "시스템 설정에서 위치 권한 허용"
      wifiPermissionItem.isEnabled = true
    @unknown default:
      wifiPermissionItem.title = "Wi-Fi 감지 권한 확인 불가"
      wifiPermissionItem.isEnabled = false
    }
  }

  private func render(_ status: SupervisorStatusWire?) {
    let presentation = MenuBarPresentation(
      status: status,
      isCommandInFlight: commandController.isCommandInFlight
    )
    statusItem.button?.title = presentation.buttonTitle
    summaryItem.title = presentation.summary
    detailItem.title = presentation.detail
    if let issues = status?.observation?.issues, !issues.isEmpty {
      detailItem.title += (detailItem.title.isEmpty ? "" : " | ") + "관찰 기록 경고: 진단 정보를 확인하세요."
    }
    detailItem.isHidden = detailItem.title.isEmpty
    updateCommandAvailability(status: status)
  }

  private func updateCommandAvailability(status: SupervisorStatusWire?) {
    let availability = MenuBarActionAvailability(
      status: status,
      isCommandInFlight: commandController.isCommandInFlight
    )
    startTripItem.isEnabled = availability.canStart
    startAdaptiveItem.isEnabled = availability.canStart
    startDeskItem.isEnabled = availability.canStart
    stopItem.isEnabled = availability.canStop
  }

  @objc private func startTrip() {
    let form = TripConfigurationView()
    let alert = configurationAlert(
      title: "통근 보호 시작",
      message: "회사 또는 집 네트워크에서 이동할 대상을 지정하세요.",
      accessoryView: form
    )
    alert.window.initialFirstResponder = form.initialFirstResponder
    guard alert.runModal() == .alertFirstButtonReturn else {
      return
    }

    do {
      let request = try form.input.makeRequest()
      if request.networkTargetKind == .wifiHotspot, !wifiAuthorization.isAuthorized {
        wifiAuthorization.request()
        updateWiFiPermissionItem()
        throw MenuBarUIError.wifiPermissionRequired
      }
      performCommand { [client] in
        try await client.startTrip(request)
      }
    } catch {
      showError(error)
    }
  }

  @objc private func startAdaptive() {
    let form = AdaptiveConfigurationView()
    let alert = configurationAlert(
      title: "Adaptive 시작",
      message: "활동 신호가 있을 때만 보호하는 시간을 지정하세요.",
      accessoryView: form
    )
    alert.window.initialFirstResponder = form.initialFirstResponder
    guard alert.runModal() == .alertFirstButtonReturn else {
      return
    }

    do {
      let settings = try form.input.validatedSettings()
      performCommand { [client] in
        try await client.enableAdaptive(
          idleGraceSeconds: settings.idleGraceSeconds,
          hardCapSeconds: settings.hardCapSeconds
        )
      }
    } catch {
      showError(error)
    }
  }

  @objc private func startDesk() {
    let form = DeskConfigurationView()
    let alert = configurationAlert(
      title: "Desk 시작",
      message: "책상에서 사용할 보호 방식과 최대 시간을 지정하세요.",
      accessoryView: form
    )
    alert.window.initialFirstResponder = form.initialFirstResponder
    guard alert.runModal() == .alertFirstButtonReturn else {
      return
    }

    do {
      let settings = try form.input.validatedSettings()
      performCommand { [client] in
        try await client.enableDesk(
          allowClosedLid: settings.allowClosedLid,
          hardCapSeconds: settings.hardCapSeconds
        )
      }
    } catch {
      showError(error)
    }
  }

  @objc private func stopCurrentMode() {
    performCommand { [client] in
      let current = try await client.status()
      switch current.mode {
      case .trip:
        return try await client.stop(expectedSessionID: current.sessionID)
      case .adaptive:
        return try await client.disableAdaptive()
      case .desk:
        return try await client.disableDesk()
      case .none:
        return current
      }
    }
  }

  private func performCommand(
    operation: @escaping @MainActor () async throws -> SupervisorStatusWire
  ) {
    guard !commandController.isCommandInFlight else {
      return
    }
    refreshController.cancel()
    commandController.perform(operation: operation) { [weak self] update in
      guard let self else {
        return
      }
      render(update.status)
      switch update {
      case .pending:
        break
      case .succeeded:
        refresh()
      case .failed(let error):
        refresh()
        showError(error)
      }
    }
  }

  @objc private func showDiagnostics() {
    guard informationTask == nil else {
      return
    }
    setInformationItemsEnabled(false)
    informationTask = Task { @MainActor [weak self] in
      guard let self else {
        return
      }
      async let network = networkProbe.snapshot(confirmInternet: true)
      let device = MacDeviceProbe().snapshot()
      let sleepOverride = MacSleepOverrideProbe().read()

      let status: SupervisorStatusWire?
      let statusError: String?
      do {
        status = try await client.status()
        statusError = nil
      } catch {
        status = nil
        statusError = userFacingDescription(error)
      }
      let currentNetwork = await network

      var lines = ["SafeClam 진단"]
      lines.append(contentsOf: SupervisorDiagnostics.observationLines(status?.observation))
      if let status {
        let presentation = MenuBarPresentation(status: status)
        lines.append("Supervisor: 연결됨")
        lines.append("상태: \(presentation.summary)")
        if !presentation.detail.isEmpty {
          lines.append("상세: \(presentation.detail)")
        }
      } else {
        lines.append("Supervisor: 연결 실패")
        lines.append("상세: \(statusError ?? "확인 불가")")
      }
      if let warning = SupervisorDiagnostics.sleepOverrideWarning(
        isSleepDisabled: sleepOverride == .disabled,
        status: status
      ) {
        lines.append(warning)
      }
      switch sleepOverride {
      case .normal:
        lines.append("SleepDisabled: 정상 수면 허용")
      case .disabled:
        lines.append("SleepDisabled: 수면 비활성화")
      case .unavailable(let detail):
        lines.append("SleepDisabled: 확인 불가, \(detail)")
      }
      lines.append("")
      lines.append("현재 센서")
      lines.append("배터리: \(device.batteryPercent.map { "\($0)%" } ?? "확인 불가")")
      lines.append("전원: \(device.powerConnection.rawValue)")
      lines.append("열 상태: \(device.thermalLevel.rawValue)")
      lines.append("덮개: \(device.lidState.rawValue)")
      lines.append("외장 화면: \(device.externalDisplayState.rawValue)")
      lines.append("")
      lines.append("현재 네트워크")
      lines.append("SSID: \(currentNetwork.ssid ?? "확인 불가")")
      lines.append("인터페이스: \(currentNetwork.interfaceName ?? "확인 불가")")
      lines.append("게이트웨이: \(currentNetwork.gateway ?? "확인 불가")")
      lines.append("인터넷: \(currentNetwork.internetReachability.rawValue)")

      showTextPanel(title: "진단 정보", text: lines.joined(separator: "\n"))
      informationTask = nil
      setInformationItemsEnabled(true)
    }
  }

  @objc private func showHistory() {
    guard informationTask == nil else {
      return
    }
    setInformationItemsEnabled(false)
    informationTask = Task { @MainActor [weak self] in
      guard let self else {
        return
      }
      do {
        let entries = try await FileSupervisorHistoryStore().recent(limit: 20)
        let formatter = ISO8601DateFormatter()
        let lines = entries.reversed().map { entry in
          var fields = [
            formatter.string(from: entry.recordedAt),
            "모드 \(entry.mode.rawValue)",
            "상태 \(entry.verdict.rawValue)",
          ]
          if let reason = entry.stopReason {
            fields.append("종료 사유 \(reason.rawValue)")
          }
          if let buildID = entry.buildID {
            fields.append("빌드 \(buildID.prefix(12))")
          }
          return fields.joined(separator: " | ")
        }
        showTextPanel(
          title: "최근 상태 기록",
          text: lines.isEmpty ? "기록된 상태 전이가 없습니다." : lines.joined(separator: "\n")
        )
      } catch {
        showError(error)
      }
      informationTask = nil
      setInformationItemsEnabled(true)
    }
  }

  @objc private func showEvents() {
    guard informationTask == nil else { return }
    setInformationItemsEnabled(false)
    informationTask = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let status = try await client.status()
        let events = try await FileSupervisorEventStore().read()
        let text =
          (SupervisorDiagnostics.observationLines(status.observation)
          + [SupervisorEventSummary(events: events, buildID: status.observation?.buildID).text])
          .joined(separator: "\n")
        showTextPanel(title: "통근 관찰 요약", text: text)
      } catch {
        showError(error)
      }
      informationTask = nil
      setInformationItemsEnabled(true)
    }
  }

  private func setInformationItemsEnabled(_ enabled: Bool) {
    diagnosticsItem.isEnabled = enabled
    historyItem.isEnabled = enabled
    eventsItem.isEnabled = enabled
  }

  private func configurationAlert(
    title: String,
    message: String,
    accessoryView: NSView
  ) -> NSAlert {
    NSApplication.shared.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.alertStyle = .informational
    alert.accessoryView = accessoryView
    alert.addButton(withTitle: "시작")
    alert.addButton(withTitle: "취소")
    return alert
  }

  private func showError(_ error: Error) {
    NSApplication.shared.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = "요청을 완료하지 못했습니다"
    alert.informativeText = userFacingDescription(error)
    alert.alertStyle = .warning
    alert.addButton(withTitle: "확인")
    alert.runModal()
  }

  private func showTextPanel(title: String, text: String) {
    NSApplication.shared.activate(ignoringOtherApps: true)
    let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 260))
    textView.string = text
    textView.isEditable = false
    textView.isSelectable = true
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.textContainer?.widthTracksTextView = true
    textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    textView.textContainerInset = NSSize(width: 8, height: 8)

    let scrollView = NSScrollView(frame: textView.frame)
    scrollView.documentView = textView
    scrollView.hasVerticalScroller = true
    scrollView.borderType = .bezelBorder

    let alert = NSAlert()
    alert.messageText = title
    alert.accessoryView = scrollView
    alert.addButton(withTitle: "확인")
    alert.runModal()
  }

  private func userFacingDescription(_ error: Error) -> String {
    if let error = error as? SupervisorXPCClientError {
      switch error {
      case .encodingFailed:
        return "Supervisor 요청을 만들 수 없습니다."
      case .unavailable:
        return "Supervisor에 연결할 수 없습니다. 설치와 LaunchAgent 상태를 확인하세요."
      case .protocolMismatch:
        return "앱과 Supervisor의 프로토콜 버전이 맞지 않습니다."
      case .rejected(let detail):
        return "Supervisor가 요청을 거부했습니다: \(detail)"
      case .malformedResponse:
        return "Supervisor 응답을 해석할 수 없습니다."
      }
    }
    if let localized = error as? LocalizedError,
      let description = localized.errorDescription
    {
      return description
    }
    return error.localizedDescription
  }

  @objc private func refreshFromMenu() {
    refresh()
  }

  @objc private func requestWiFiPermission() {
    wifiAuthorization.request()
    refresh()
  }

  @objc private func quit() {
    NSApplication.shared.terminate(nil)
  }
}

@MainActor
private final class WiFiLocationAuthorization {
  private let manager = CLLocationManager()

  var status: CLAuthorizationStatus {
    manager.authorizationStatus
  }

  var isAuthorized: Bool {
    status == .authorizedAlways
  }

  func request() {
    NSApplication.shared.activate(ignoringOtherApps: true)
    switch status {
    case .notDetermined:
      manager.requestWhenInUseAuthorization()
    case .denied, .restricted:
      guard
        let url = URL(
          string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices"
        )
      else {
        return
      }
      NSWorkspace.shared.open(url)
    case .authorizedAlways:
      break
    @unknown default:
      break
    }
  }
}

private enum MenuBarUIError: LocalizedError {
  case wifiPermissionRequired

  var errorDescription: String? {
    switch self {
    case .wifiPermissionRequired:
      "Wi-Fi Trip을 시작하려면 위치 권한을 허용한 뒤 다시 시도하세요."
    }
  }
}
