import AppKit
import CoreLocation
import Foundation
import RuntinueIPC
import RuntinueSystem
import RuntinueUserSupport

@main
enum RuntinueMenuBarMain {
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
  private let tripPreferences = TripPreferences()
  private let statusItem = NSStatusBar.system.statusItem(
    withLength: NSStatusItem.variableLength
  )
  private let statusHeaderItem = NSMenuItem()
  private let statusHeaderView = ProtectionStatusHeaderView()
  private let wifiPermissionItem = NSMenuItem(
    title: L("Wi-Fi 이름 접근 권한 확인 중", "Checking Wi-Fi name access"),
    action: nil,
    keyEquivalent: ""
  )
  private let startTripItem = NSMenuItem(
    title: L("이동 중 실행 유지…", "Keep awake on the go…"),
    action: nil,
    keyEquivalent: ""
  )
  private let startAdaptiveItem = NSMenuItem(
    title: L("작업 중 자동 유지…", "Keep awake during tasks…"),
    action: nil,
    keyEquivalent: ""
  )
  private let startDeskItem = NSMenuItem(
    title: L("시간을 정해 유지…", "Keep awake for a set time…"),
    action: nil,
    keyEquivalent: ""
  )
  private let stopItem = NSMenuItem(
    title: L("실행 유지 중단", "Stop keeping awake"), action: nil, keyEquivalent: "")
  private let diagnosticsItem = NSMenuItem(
    title: L("진단 정보 보기…", "Diagnostics…"),
    action: nil,
    keyEquivalent: ""
  )
  private let historyItem = NSMenuItem(
    title: L("최근 기록 보기…", "Recent history…"),
    action: nil,
    keyEquivalent: ""
  )
  private let eventsItem = NSMenuItem(
    title: L("이동 모드 기록 요약…", "Travel activity summary…"), action: nil, keyEquivalent: "")

  private var timer: Timer?
  private let refreshController = MenuBarRefreshController()
  private let commandController = MenuBarCommandController()
  private var informationTask: Task<Void, Never>?
  // 불확실 상태에서 아이콘을 격상하는 표현 전용 기록이다. 동작 허용 판단에는 사용하지 않는다.
  private var lastKnownStatus: SupervisorStatusWire?

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
    startTripItem.title = L("이동 중 실행 유지…", "Keep awake on the go…")
    startAdaptiveItem.title = L("작업 중 자동 유지…", "Keep awake during tasks…")
    startDeskItem.title = L("시간을 정해 유지…", "Keep awake for a set time…")
    stopItem.title = L("실행 유지 중단", "Stop keeping awake")
    diagnosticsItem.title = L("진단 정보 보기…", "Diagnostics…")
    historyItem.title = L("최근 기록 보기…", "Recent history…")
    eventsItem.title = L("이동 모드 기록 요약…", "Travel activity summary…")
    statusItem.button?.image = MenuBarStatusVisuals.image(for: .continuationMark)
    statusItem.button?.imagePosition = .imageLeading
    statusItem.button?.imageScaling = .scaleProportionallyDown
    statusItem.button?.setAccessibilityIdentifier("runtinue.status")
    statusItem.button?.setAccessibilityLabel("Runtinue")

    statusHeaderItem.view = statusHeaderView
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
    startTripItem.identifier = NSUserInterfaceItemIdentifier("runtinue.startTrip")
    startAdaptiveItem.identifier = NSUserInterfaceItemIdentifier("runtinue.startAdaptive")
    startDeskItem.identifier = NSUserInterfaceItemIdentifier("runtinue.startDesk")
    stopItem.identifier = NSUserInterfaceItemIdentifier("runtinue.stop")

    let refreshItem = NSMenuItem(
      title: L("새로 고침", "Refresh"),
      action: #selector(refreshFromMenu),
      keyEquivalent: "r"
    )
    refreshItem.target = self
    let quitItem = NSMenuItem(
      title: L("메뉴바만 종료", "Quit menu bar only"),
      action: #selector(quit),
      keyEquivalent: "q"
    )
    quitItem.target = self
    quitItem.toolTip = L(
      "실행 유지도 끝내려면 먼저 실행 유지 중단을 선택하세요.",
      "To stop keeping awake too, choose Stop keeping awake first.")

    let menu = NSMenu()
    menu.autoenablesItems = false
    menu.addItem(statusHeaderItem)
    menu.addItem(.separator())
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
    let languageMenu = NSMenu()
    for (index, language) in InterfaceLanguage.allCases.enumerated() {
      let titles = [L("시스템 언어 사용", "Use system language"), "한국어", "English"]
      let item = NSMenuItem(
        title: titles[index], action: #selector(changeLanguage(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = language.rawValue
      item.state = InterfaceLanguage.selected == language ? .on : .off
      languageMenu.addItem(item)
    }
    let languageItem = NSMenuItem(title: L("언어", "Language"), action: nil, keyEquivalent: "")
    languageItem.submenu = languageMenu
    menu.addItem(languageItem)
    menu.addItem(.separator())
    menu.addItem(quitItem)
    statusItem.menu = menu

    render(nil)
  }

  @objc private func changeLanguage(_ sender: NSMenuItem) {
    guard let value = sender.representedObject as? String,
      let language = InterfaceLanguage(rawValue: value)
    else { return }
    UserDefaults.standard.set(language.rawValue, forKey: InterfaceLanguage.preferenceKey)
    // Rebuild labels without briefly presenting the last successful status as current.
    statusItem.menu?.removeAllItems()
    configureMenu()
    refresh()
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
      wifiPermissionItem.title = L("Wi-Fi 이름 접근 허용됨", "Wi-Fi name access granted")
      wifiPermissionItem.isEnabled = false
    case .notDetermined:
      wifiPermissionItem.title = L("Wi-Fi 이름 접근 허용…", "Allow Wi-Fi name access…")
      wifiPermissionItem.isEnabled = true
    case .denied, .restricted:
      wifiPermissionItem.title = L("위치 권한 설정 열기…", "Open Location Services settings…")
      wifiPermissionItem.isEnabled = true
    @unknown default:
      wifiPermissionItem.title = L("Wi-Fi 이름 접근 권한 확인 불가", "Wi-Fi name access unavailable")
      wifiPermissionItem.isEnabled = false
    }
  }

  private func render(_ status: SupervisorStatusWire?) {
    if let status, tripPreferences.hasPendingVerification {
      tripPreferences.observeProtection(
        status, network: wifiAuthorization.isAuthorized ? networkProbe.currentConnection() : nil
      )
    }
    let sleepOverrideUnavailable = isSleepOverrideUnavailable(status: status)
    let iconStyle: MenuBarIconStyle =
      MenuBarCriticalWarningPolicy.shouldReplaceContinuationMark(
        currentStatus: status,
        lastKnownStatus: lastKnownStatus,
        sleepOverrideUnavailable: sleepOverrideUnavailable
      ) ? .criticalWarning : .continuationMark
    let presentation = MenuBarPresentation(
      status: status,
      isCommandInFlight: commandController.isCommandInFlight,
      iconStyle: iconStyle
    )
    if let status {
      lastKnownStatus = status
    }
    if let button = statusItem.button {
      button.image = MenuBarStatusVisuals.image(for: presentation.iconStyle)
      let title = button.image == nil ? presentation.buttonTitle : presentation.statusIndicator
      button.attributedTitle = MenuBarStatusTypography.attributedTitle(title)
      button.toolTip =
        "Runtinue: \(presentation.summary)"
        + (presentation.detail.isEmpty ? "" : "\n\(presentation.detail)")
      button.setAccessibilityValue(presentation.summary)
    }
    statusHeaderView.update(presentation)
    updateCommandAvailability(status: status)
  }

  private func isSleepOverrideUnavailable(status: SupervisorStatusWire?) -> Bool {
    let shouldProbe =
      status == nil
      || status?.verdict == .unknown
      || status?.verdict == .recoveryPending
      || status?.phase == .recoveryPending
    guard shouldProbe else { return false }
    if case .unavailable = MacSleepOverrideProbe().read() {
      return true
    }
    return false
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
    let currentNetwork = wifiAuthorization.isAuthorized ? networkProbe.currentConnection() : nil
    let form = TripConfigurationView(
      rememberedHotspotSSID: tripPreferences.lastHotspotSSID,
      currentWiFiSSID: currentNetwork?.ssid,
      confirmedHotspotSSID: tripPreferences.confirmedHotspotSSID(for: currentNetwork)
    )
    let alert = configurationAlert(
      title: L("이동 중 실행 유지", "Keep awake on the go"),
      message: L(
        "휴대전화 인터넷으로 전환한 뒤에도 작업이 계속 실행되도록 설정합니다.",
        "Keep tasks running after switching to your phone's internet connection."),
      accessoryView: form,
      validate: { _ = try form.input.makeRequest() }
    )
    alert.window.initialFirstResponder = form.initialFirstResponder
    guard alert.runModal() == .alertFirstButtonReturn else {
      return
    }

    do {
      let request = try form.input.makeRequest()
      tripPreferences.rememberInput(request)
      if request.networkTargetKind == .wifiHotspot, !wifiAuthorization.isAuthorized {
        wifiAuthorization.request()
        updateWiFiPermissionItem()
        throw MenuBarUIError.wifiPermissionRequired
      }
      performCommand { [client, tripPreferences] in
        let status = try await client.startTrip(request)
        tripPreferences.registerAcceptedRequest(request, status: status)
        return status
      }
    } catch {
      showError(error)
    }
  }

  @objc private func startAdaptive() {
    let form = AdaptiveConfigurationView()
    let alert = configurationAlert(
      title: L("작업 중 자동 유지", "Keep awake during tasks"),
      message: L(
        "작업 도구의 활동에 맞춰 실행 유지와 수면 허용을 자동으로 전환합니다.",
        "Automatically keep awake or allow sleep based on activity from an integrated tool."),
      accessoryView: form,
      validate: { _ = try form.input.validatedSettings() }
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
      title: L("시간을 정해 유지", "Keep awake for a set time"),
      message: L(
        "다운로드나 긴 작업이 끝날 때까지 Mac이 잠들지 않도록 시간을 정합니다.",
        "Set how long your Mac should stay awake for a download or a long-running task."),
      accessoryView: form,
      validate: { _ = try form.input.validatedSettings() }
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

      var lines = [L("Runtinue 진단", "Runtinue diagnostics")]
      lines.append(contentsOf: SupervisorDiagnostics.observationLines(status?.observation))
      if let status {
        let presentation = MenuBarPresentation(status: status)
        lines.append(L("백그라운드 서비스: 연결됨", "Background service: connected"))
        lines.append(L("상태: \(presentation.summary)", "Status: \(presentation.summary)"))
        if !presentation.detail.isEmpty {
          lines.append(L("상세: \(presentation.detail)", "Details: \(presentation.detail)"))
          if let raw = status.detail {
            lines.append(L("서비스 원문: \(raw)", "Service details: \(raw)"))
          }
        }
      } else {
        lines.append(L("백그라운드 서비스: 연결 실패", "Background service: disconnected"))
        lines.append(
          L("상세: \(statusError ?? "확인 불가")", "Details: \(statusError ?? L("확인 불가", "Unavailable"))")
        )
      }
      if let warning = SupervisorDiagnostics.sleepOverrideWarning(
        isSleepDisabled: sleepOverride == .disabled,
        status: status
      ) {
        lines.append(warning)
      }
      switch sleepOverride {
      case .normal:
        lines.append(L("시스템 수면: 허용됨", "System sleep: allowed"))
      case .disabled:
        lines.append(L("시스템 수면: 억제 중", "System sleep: inhibited"))
      case .unavailable(let detail):
        lines.append(L("시스템 수면: 확인 불가, \(detail)", "System sleep: unavailable, \(detail)"))
      }
      lines.append("")
      lines.append(L("현재 센서", "Current sensors"))
      lines.append(
        L(
          "배터리: \(device.batteryPercent.map { "\($0)%" } ?? "확인 불가")",
          "Battery: \(device.batteryPercent.map { "\($0)%" } ?? L("확인 불가", "Unavailable"))"))
      lines.append(
        L(
          "전원: \(InterfaceStatusText.value(device.powerConnection.rawValue))",
          "Power: \(InterfaceStatusText.value(device.powerConnection.rawValue))"))
      lines.append(
        L(
          "macOS 열 압력: \(InterfaceStatusText.value(device.thermalLevel.rawValue))",
          "macOS thermal pressure: \(InterfaceStatusText.value(device.thermalLevel.rawValue))"))
      lines.append(
        L("  macOS가 보고하는 시스템의 열 제약 상태입니다.", "  System thermal restrictions reported by macOS."))
      lines.append(
        L(
          "덮개: \(InterfaceStatusText.value(device.lidState.rawValue))",
          "Lid: \(InterfaceStatusText.value(device.lidState.rawValue))"))
      lines.append(
        L(
          "외장 화면: \(InterfaceStatusText.value(device.externalDisplayState.rawValue))",
          "External display: \(InterfaceStatusText.value(device.externalDisplayState.rawValue))"))
      lines.append("")
      lines.append(
        contentsOf: SupervisorDiagnostics.temperatureDiagnosticLines(
          status?.temperatureTelemetry
        ))
      lines.append("")
      lines.append(L("현재 네트워크", "Current network"))
      lines.append(
        L(
          "SSID: \(currentNetwork.ssid ?? "확인 불가")",
          "SSID: \(currentNetwork.ssid ?? L("확인 불가", "Unavailable"))"))
      lines.append(
        L(
          "인터페이스: \(currentNetwork.interfaceName ?? "확인 불가")",
          "Interface: \(currentNetwork.interfaceName ?? L("확인 불가", "Unavailable"))"))
      lines.append(
        L(
          "게이트웨이: \(currentNetwork.gateway ?? "확인 불가")",
          "Gateway: \(currentNetwork.gateway ?? L("확인 불가", "Unavailable"))"))
      lines.append(
        L(
          "인터넷: \(InterfaceStatusText.value(currentNetwork.internetReachability.rawValue))",
          "Internet: \(InterfaceStatusText.value(currentNetwork.internetReachability.rawValue))"))

      showTextPanel(title: L("진단 정보", "Diagnostics"), text: lines.joined(separator: "\n"))
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
            L(
              "모드 \(InterfaceStatusText.mode(entry.mode))",
              "Mode \(InterfaceStatusText.mode(entry.mode))"),
            L(
              "상태 \(InterfaceStatusText.value(entry.verdict.rawValue))",
              "Status \(InterfaceStatusText.value(entry.verdict.rawValue))"),
          ]
          if let reason = entry.stopReason {
            fields.append(
              L(
                "종료 사유 \(InterfaceStatusText.value(reason.rawValue))",
                "Stop reason \(InterfaceStatusText.value(reason.rawValue))"))
          }
          if let buildID = entry.buildID {
            fields.append(L("빌드 \(buildID.prefix(12))", "Build \(buildID.prefix(12))"))
          }
          return fields.joined(separator: " | ")
        }
        showTextPanel(
          title: L("최근 상태 기록", "Recent status history"),
          text: lines.isEmpty
            ? L("기록된 상태 변경이 없습니다.", "No status changes recorded.") : lines.joined(separator: "\n")
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
        showTextPanel(title: L("이동 모드 기록 요약", "Travel activity summary"), text: text)
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
    accessoryView: NSView,
    validate: @escaping () throws -> Void
  ) -> NSAlert {
    NSApplication.shared.activate(ignoringOtherApps: true)
    let alert = ValidatedConfigurationAlert()
    alert.validate = validate
    alert.messageText = title
    alert.informativeText = message
    alert.alertStyle = .informational
    alert.accessoryView = accessoryView
    let submit = alert.addButton(withTitle: L("시작", "Start"))
    submit.target = alert
    submit.action = #selector(ValidatedConfigurationAlert.submit(_:))
    alert.addButton(withTitle: L("취소", "Cancel"))
    return alert
  }

  private func showError(_ error: Error) {
    NSApplication.shared.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = L("요청을 완료하지 못했습니다", "Could not complete the request")
    alert.informativeText = userFacingDescription(error)
    alert.alertStyle = .warning
    alert.addButton(withTitle: L("확인", "OK"))
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
    alert.addButton(withTitle: L("확인", "OK"))
    alert.runModal()
  }

  private func userFacingDescription(_ error: Error) -> String {
    if let error = error as? SupervisorXPCClientError {
      switch error {
      case .encodingFailed:
        return L(
          "백그라운드 서비스에 보낼 요청을 만들지 못했습니다.",
          "Could not prepare the request for the background service.")
      case .unavailable:
        return L(
          "백그라운드 서비스에 연결하지 못했습니다. 앱을 다시 설치하거나 진단 정보를 확인하세요.",
          "Could not reach the background service. Reinstall the app or check Diagnostics.")
      case .protocolMismatch:
        return L(
          "앱과 백그라운드 서비스의 버전이 맞지 않습니다. 앱을 다시 설치하세요.",
          "The app and background service versions are incompatible. Reinstall the app.")
      case .rejected(let detail):
        return InterfaceStatusText.rejection(detail)
      case .malformedResponse:
        return L("백그라운드 서비스의 응답을 읽지 못했습니다.", "Could not read the background service response.")
      }
    }
    if let localized = error as? LocalizedError,
      let description = localized.errorDescription
    {
      return description
    }
    let code = (error as NSError).code
    return L("요청을 처리하지 못했습니다. 오류 코드: \(code)", "Could not process the request. Error code: \(code)")
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
      L(
        "핫스팟 이름을 확인하려면 위치 권한이 필요합니다. 시스템 설정에서 Runtinue의 위치 접근을 허용한 뒤 다시 시작하세요.",
        "Location access is needed to read the hotspot name. Allow Runtinue in System Settings, then start again."
      )
    }
  }
}
