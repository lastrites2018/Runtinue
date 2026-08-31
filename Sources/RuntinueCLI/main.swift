import Foundation
import RuntinueCore
import RuntinueIPC
import RuntinueSystem
import RuntinueUserSupport

@main
struct RuntinueCLI {
  static func main() async {
    do {
      try await run(arguments: Array(CommandLine.arguments.dropFirst()))
    } catch {
      writeError("오류: \(error)\n")
      Foundation.exit(1)
    }
  }

  private static func run(arguments: [String]) async throws {
    guard let command = arguments.first else {
      printUsage()
      return
    }

    switch command {
    case "trip":
      guard arguments.dropFirst().first == "start" else {
        throw CLIError.invalidSubcommand("trip")
      }
      let options = try TripOptions(arguments: Array(arguments.dropFirst(2)))
      try await startTrip(options: options)
    case "start":
      let options = try TripOptions(arguments: Array(arguments.dropFirst()))
      try await startTrip(options: options)
    case "adaptive":
      guard let subcommand = arguments.dropFirst().first else {
        throw CLIError.invalidSubcommand("adaptive")
      }
      switch subcommand {
      case "enable":
        let options = try AdaptiveOptions(arguments: Array(arguments.dropFirst(2)))
        try await enableAdaptive(options: options)
      case "disable":
        guard arguments.count == 2 else {
          throw CLIError.unknownOption(arguments[2])
        }
        try await disableAdaptive()
      default:
        throw CLIError.invalidSubcommand("adaptive")
      }
    case "desk":
      guard let subcommand = arguments.dropFirst().first else {
        throw CLIError.invalidSubcommand("desk")
      }
      switch subcommand {
      case "enable":
        let options = try DeskOptions(arguments: Array(arguments.dropFirst(2)))
        try await enableDesk(options: options)
      case "disable":
        guard arguments.count == 2 else {
          throw CLIError.unknownOption(arguments[2])
        }
        try await disableDesk()
      default:
        throw CLIError.invalidSubcommand("desk")
      }
    case "status":
      guard arguments.count == 1 || arguments == ["status", "--json"] else {
        throw CLIError.unknownOption(arguments[1])
      }
      try await showSupervisorStatus(asJSON: arguments.count == 2)
    case "stop":
      guard arguments.count == 1 else {
        throw CLIError.unknownOption(arguments[1])
      }
      try await stopTrip()
    case "history":
      let options = try HistoryOptions(arguments: Array(arguments.dropFirst()))
      try await showHistory(limit: options.limit)
    case "events":
      guard arguments.count == 1 else {
        throw CLIError.unknownOption(arguments[1])
      }
      let status = try await SupervisorXPCClient().status()
      let events = try await FileSupervisorEventStore().read()
      for line in SupervisorDiagnostics.observationLines(status.observation) { print(line) }
      print(SupervisorEventSummary(events: events, buildID: status.observation?.buildID).text)
      print("이벤트 파일: \(FileSupervisorEventStore.productionURL.path)")
    case "diagnose":
      guard arguments.count == 1 else {
        throw CLIError.unknownOption(arguments[1])
      }
      await diagnose()
    case "verify-helper-boundary":
      guard arguments.count == 1 else {
        throw CLIError.unknownOption(arguments[1])
      }
      try await verifyHelperBoundary()
    case "inspect":
      await inspect()
    case "watch-handoff":
      let options = try WatchOptions(arguments: Array(arguments.dropFirst()))
      try await watchHandoff(options: options)
    case "help", "--help", "-h":
      printUsage()
    default:
      throw CLIError.unknownCommand(command)
    }
  }

  private static func inspect() async {
    let clock = SystemUptimeClock()
    let network = await MacNetworkProbe(clock: clock).snapshot(confirmInternet: true)
    let device = MacDeviceProbe(clock: clock).snapshot()
    let verdict = DeviceSafetyPolicy().evaluate(device, at: clock.now())

    print("네트워크")
    print("  SSID: \(network.ssid ?? "확인 불가")")
    print("  인터페이스: \(network.interfaceName ?? "확인 불가")")
    print("  게이트웨이: \(network.gateway ?? "확인 불가")")
    print("  기본 경로 도달 가능: \(network.routeReachable ? "예" : "아니요")")
    print("  인터넷 확인: \(network.internetReachability.rawValue)")
    print("기기")
    print("  배터리: \(device.batteryPercent.map(String.init) ?? "확인 불가")%")
    print("  전원: \(device.powerConnection.rawValue)")
    print("  열 상태: \(device.thermalLevel.rawValue)")
    print("  덮개: \(device.lidState.rawValue)")
    print("  외장 화면: \(device.externalDisplayState.rawValue)")
    print("  저전력 모드: \(device.lowPowerModeEnabled ? "켜짐" : "꺼짐")")
    print("판정: \(describe(verdict))")
  }

  private static func showHistory(limit: Int) async throws {
    let entries = try await FileSupervisorHistoryStore().recent(limit: limit)
    guard !entries.isEmpty else {
      print("기록된 상태 전이가 없습니다.")
      return
    }
    let formatter = ISO8601DateFormatter()
    for entry in entries {
      var fields = [
        formatter.string(from: entry.recordedAt),
        "mode=\(entry.mode.rawValue)",
        "phase=\(entry.phase.rawValue)",
        "verdict=\(entry.verdict.rawValue)",
      ]
      if let stopReason = entry.stopReason {
        fields.append("stopReason=\(stopReason.rawValue)")
      }
      if let buildID = entry.buildID {
        fields.append("build=\(buildID.prefix(12))")
      }
      print(fields.joined(separator: " | "))
    }
  }

  private static func diagnose() async {
    let clock = SystemUptimeClock()
    async let network = MacNetworkProbe(clock: clock).snapshot(confirmInternet: true)
    let device = MacDeviceProbe(clock: clock).snapshot()
    let sleepOverride = MacSleepOverrideProbe().read()

    print("Runtinue 진단")
    do {
      let status = try await SupervisorXPCClient().status()
      print("Supervisor: 연결됨")
      printStatus(status)
      if let warning = SupervisorDiagnostics.sleepOverrideWarning(
        isSleepDisabled: sleepOverride == .disabled,
        status: status
      ) {
        print(warning)
      }
    } catch {
      print("Supervisor: 연결 실패")
      print("상세: \(error)")
      if let warning = SupervisorDiagnostics.sleepOverrideWarning(
        isSleepDisabled: sleepOverride == .disabled,
        status: nil
      ) {
        print(warning)
      }
    }

    switch sleepOverride {
    case .normal:
      print("SleepDisabled: 정상 수면 허용")
    case .disabled:
      print("SleepDisabled: 수면 비활성화")
    case .unavailable(let detail):
      print("SleepDisabled: 확인 불가, \(detail)")
    }
    print("현재 센서")
    print("  배터리: \(device.batteryPercent.map { "\($0)%" } ?? "확인 불가")")
    print("  전원: \(device.powerConnection.rawValue)")
    print("  열 상태: \(device.thermalLevel.rawValue)")
    print("  덮개: \(device.lidState.rawValue)")

    let currentNetwork = await network
    print("현재 네트워크")
    print("  SSID: \(currentNetwork.ssid ?? "확인 불가")")
    print("  인터페이스: \(currentNetwork.interfaceName ?? "확인 불가")")
    print("  게이트웨이: \(currentNetwork.gateway ?? "확인 불가")")
    print("  인터넷: \(currentNetwork.internetReachability.rawValue)")
    print("상태 기록: \(FileSupervisorHistoryStore.productionURL.path)")
  }

  private static func verifyHelperBoundary() async throws {
    guard helperServiceIsLoaded() else {
      throw CLIError.helperBoundaryHelperUnavailable
    }
    switch await probePrivilegedHelperDirectly() {
    case .rejected:
      print("root helper가 CLI의 직접 연결을 거부했습니다.")
    case .accepted(let version):
      throw CLIError.helperBoundaryAccepted(protocolVersion: version)
    case .timedOut:
      throw CLIError.helperBoundaryInconclusive
    }
  }

  private static func helperServiceIsLoaded() -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = ["print", "system/\(RuntinueIPCContract.helperMachServiceName)"]
    process.environment = [
      "LANG": "C",
      "LC_ALL": "C",
      "PATH": "/bin:/usr/bin:/usr/sbin",
    ]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
      process.waitUntilExit()
      return process.terminationStatus == 0
    } catch {
      return false
    }
  }

  private static func probePrivilegedHelperDirectly() async -> HelperBoundaryProbeOutcome {
    await withCheckedContinuation { continuation in
      let connection = NSXPCConnection(
        machServiceName: RuntinueIPCContract.helperMachServiceName,
        options: .privileged
      )
      connection.remoteObjectInterface = NSXPCInterface(
        with: PrivilegedLeaseXPCProtocol.self
      )
      let gate = HelperBoundaryProbeGate(
        connection: connection,
        continuation: continuation
      )
      connection.invalidationHandler = {
        gate.resolve(.rejected)
      }
      connection.interruptionHandler = {
        gate.resolve(.rejected)
      }
      connection.resume()

      guard
        let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
          gate.resolve(.rejected)
        }) as? PrivilegedLeaseXPCProtocol
      else {
        gate.resolve(.rejected)
        return
      }
      proxy.protocolVersion { version in
        gate.resolve(.accepted(protocolVersion: version))
      }
      gate.scheduleTimeout(after: 5)
    }
  }

  private static func startTrip(options: TripOptions) async throws {
    let request = StartTripWireRequest(
      networkTargetKind: options.networkTargetKind,
      expectedHotspotSSID: options.hotspotSSID,
      hotspotHandoffTimeoutSeconds: options.handoffTimeoutSeconds,
      hardCapSeconds: options.hardCapSeconds
    )
    do {
      let status = try await SupervisorXPCClient().startTrip(request)
      print("통근 세션을 시작했습니다.")
      if let sessionID = status.sessionID {
        print("세션 ID: \(sessionID.uuidString)")
      }
      printStatus(status)
    } catch let error as SupervisorXPCClientError {
      throw CLIError.supervisor(describe(error))
    }
  }

  private static func showSupervisorStatus(asJSON: Bool = false) async throws {
    do {
      let status = try await SupervisorXPCClient().status()
      if asJSON {
        let data = try JSONEncoder().encode(status)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
      } else {
        printStatus(status)
      }
    } catch let error as SupervisorXPCClientError {
      throw CLIError.supervisor(describe(error))
    }
  }

  private static func stopTrip() async throws {
    do {
      let status = try await SupervisorXPCClient().stop()
      printStatus(status)
    } catch let error as SupervisorXPCClientError {
      throw CLIError.supervisor(describe(error))
    }
  }

  private static func enableAdaptive(options: AdaptiveOptions) async throws {
    do {
      let status = try await SupervisorXPCClient().enableAdaptive(
        idleGraceSeconds: options.idleGraceSeconds,
        hardCapSeconds: options.hardCapSeconds
      )
      print("Adaptive 모드를 활성화했습니다.")
      printStatus(status)
    } catch let error as SupervisorXPCClientError {
      throw CLIError.supervisor(describe(error))
    }
  }

  private static func disableAdaptive() async throws {
    do {
      let status = try await SupervisorXPCClient().disableAdaptive()
      print("Adaptive 모드를 비활성화했습니다.")
      printStatus(status)
    } catch let error as SupervisorXPCClientError {
      throw CLIError.supervisor(describe(error))
    }
  }

  private static func enableDesk(options: DeskOptions) async throws {
    do {
      let status = try await SupervisorXPCClient().enableDesk(
        allowClosedLid: options.allowClosedLid,
        hardCapSeconds: options.hardCapSeconds
      )
      print("Desk 모드를 활성화했습니다.")
      printStatus(status)
    } catch let error as SupervisorXPCClientError {
      throw CLIError.supervisor(describe(error))
    }
  }

  private static func disableDesk() async throws {
    do {
      let status = try await SupervisorXPCClient().disableDesk()
      print("Desk 모드를 비활성화했습니다.")
      printStatus(status)
    } catch let error as SupervisorXPCClientError {
      throw CLIError.supervisor(describe(error))
    }
  }

  private static func printStatus(_ status: SupervisorStatusWire) {
    for line in SupervisorDiagnostics.observationLines(status.observation) {
      print(line)
    }
    switch status.verdict {
    case .protected:
      let remaining = status.remainingSeconds.map(formatDuration) ?? "확인 불가"
      print("보호 중입니다. 남은 시간: \(remaining)")
      if status.closedLidAllowed {
        print("현재 확인된 상태에서는 덮개를 닫아도 됩니다.")
      } else {
        print("덮개를 열어 둔 상태에서만 절전 방지가 유지됩니다.")
      }
    case .waitingForHotspot:
      print("핫스팟 연결을 확인하는 중입니다.")
      print("아직 덮개를 닫지 마세요.")
    case .acquiring:
      print("보호 설정을 확인하는 중입니다.")
      print("아직 덮개를 닫지 마세요.")
    case .releasing:
      print("정상 수면 상태로 복구하는 중입니다.")
      print("아직 덮개를 닫지 마세요.")
    case .recoveryPending:
      print("정상 수면 복구를 재시도하고 있습니다.")
      print("덮개를 닫지 마세요.")
    case .unsafe:
      print("기기 안전 조건을 충족하지 못해 보호를 중단했습니다.")
      print("덮개를 닫지 마세요.")
    case .unknown:
      print("보호 상태를 확인할 수 없습니다.")
      print("덮개를 닫지 마세요.")
    case .inactive:
      if status.mode == .adaptive {
        print("Adaptive 모드가 활동 신호를 기다리고 있습니다.")
      } else {
        print("활성 통근 세션이 없습니다.")
      }
    }
    if let detail = status.detail, !detail.isEmpty {
      print("상세: \(detail)")
    }
    if status.batteryPercent != nil || status.thermalLevel != nil {
      print(
        "기기: 배터리 \(status.batteryPercent.map { "\($0)%" } ?? "확인 불가"), "
          + "열 상태 \(status.thermalLevel ?? "확인 불가")"
      )
    }
  }

  private static func describe(_ error: SupervisorXPCClientError) -> String {
    switch error {
    case .encodingFailed:
      "Supervisor 요청을 만들 수 없음"
    case .unavailable:
      "Supervisor에 연결할 수 없음. 설치와 LaunchAgent 상태를 확인하세요"
    case .protocolMismatch:
      "Supervisor와 CLI 프로토콜 버전이 맞지 않음"
    case .rejected(let detail):
      "Supervisor가 요청을 거부함: \(detail)"
    case .malformedResponse:
      "Supervisor 응답을 해석할 수 없음"
    }
  }

  private static func formatDuration(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded(.down)))
    let hours = total / 3_600
    let minutes = total % 3_600 / 60
    if hours > 0 {
      return "\(hours)시간 \(minutes)분"
    }
    return "\(minutes)분"
  }

  private static func watchHandoff(options: WatchOptions) async throws {
    let clock = SystemUptimeClock()
    let networkProbe = MacNetworkProbe(clock: clock)
    let deviceProbe = MacDeviceProbe(clock: clock)
    let origin = await networkProbe.snapshot()
    let policy = HotspotTransitionPolicy(expectedSSID: options.hotspotSSID)
    let safetyPolicy = DeviceSafetyPolicy()
    let deadline = clock.now().adding(.seconds(options.timeoutSeconds))

    print("핫스팟 전환 대기")
    print("  시작 SSID: \(origin.ssid ?? "확인 불가")")
    print("  대상 SSID: \(options.hotspotSSID)")
    print("  제한 시간: \(options.timeoutSeconds)초")

    while clock.now() < deadline {
      let now = clock.now()
      let device = deviceProbe.snapshot()
      if case .stop(let reason) = safetyPolicy.evaluate(device, at: now) {
        throw CLIError.deviceUnsafe(reason)
      }

      var current = await networkProbe.snapshot()
      if current.ssid == options.hotspotSSID && current.routeReachable {
        current = await networkProbe.snapshot(confirmInternet: true)
      }
      switch policy.evaluate(origin: origin, current: current, at: clock.now()) {
      case .ready:
        print("핫스팟 전환과 기본 경로를 확인했습니다.")
        print("이 검사 전용 명령은 closed-lid 보호 lease를 활성화하지 않습니다.")
        return
      case .waiting(let reason):
        print("대기 중: \(describe(reason))")
      }

      try await ContinuousClock().sleep(for: .seconds(2))
    }

    throw CLIError.handoffTimedOut
  }

  private static func describe(_ verdict: DeviceSafetyVerdict) -> String {
    switch verdict {
    case .safe:
      "현재 신호 기준 통과"
    case .uncertain(let reason):
      "확인 필요: \(reason)"
    case .stop(let reason):
      "중단 필요: \(describe(reason))"
    }
  }

  private static func describe(_ reason: DeviceSafetyStopReason) -> String {
    switch reason {
    case .snapshotFromFuture:
      "센서 시간 순서가 올바르지 않음"
    case .staleSnapshot:
      "센서 정보가 오래됨"
    case .thermalUnavailable:
      "열 상태를 확인할 수 없음"
    case .thermalLimitReached(let observed, let cutoff):
      "열 상태 \(observed.rawValue), 중단 기준 \(cutoff.rawValue)"
    case .batteryUnavailable:
      "배터리 잔량을 확인할 수 없음"
    case .batteryBelowFloor(let observed, let floor):
      "배터리 \(observed)%, 최소 \(floor)%"
    case .lidClosedWithoutPermission:
      "closed-lid 허용 없이 덮개가 닫힘"
    }
  }

  private static func describe(_ reason: HotspotWaitingReason) -> String {
    switch reason {
    case .snapshotFromFuture:
      "네트워크 시간 순서가 올바르지 않음"
    case .staleSnapshot:
      "네트워크 정보가 오래됨"
    case .routeUnavailable:
      "기본 네트워크 경로가 아직 준비되지 않음"
    case .ssidUnavailable:
      "SSID를 확인할 수 없음. 위치 서비스 권한을 확인하세요"
    case .interfaceUnavailable:
      "기본 네트워크 인터페이스를 확인할 수 없음"
    case .unexpectedSSID(let observed):
      "현재 SSID \(observed ?? "확인 불가")"
    case .networkIdentityUnchanged:
      "시작 네트워크와 대상 네트워크가 같음"
    case .internetUnchecked:
      "인터넷 도달 여부를 아직 확인하지 않음"
    case .internetUnavailable:
      "핫스팟에서 실제 인터넷 도달을 확인하지 못함"
    }
  }

  private static func printUsage() {
    print(
      """
      사용법:
        runtinue trip start --for <시간> (--hotspot <SSID> | --usb-tether) [--handoff-timeout <시간>]
        runtinue start --for <시간> (--hotspot <SSID> | --usb-tether) [--handoff-timeout <시간>]
        runtinue status [--json]
        runtinue stop
        runtinue history [--limit <개수>]
        runtinue events
        runtinue diagnose
        runtinue verify-helper-boundary
        runtinue adaptive enable [--idle-grace <시간>] --max <시간>
        runtinue adaptive disable
        runtinue desk enable --max <시간> [--closed-lid]
        runtinue desk disable
        runtinue inspect
        runtinue watch-handoff --hotspot <SSID> [--timeout-seconds <초>]

      시간 예시: 90m, 2h, 5400s
      trip start는 지정한 핫스팟 연결을 확인한 뒤 유한한 closed-lid 보호 lease를 요청합니다.
      Wi-Fi 핫스팟에 이미 연결된 상태에서도 시작할 수 있습니다.
      adaptive enable은 서명된 hook의 활동 신호가 있을 때만 lease를 획득합니다.
      desk enable은 기본적으로 덮개가 열린 동안 process-owned assertion을 사용합니다.
      --closed-lid를 지정한 경우에만 privileged lease를 사용합니다.
      status는 Helper의 실제 상태까지 확인된 경우에만 보호 중이라고 표시합니다.
      history는 비권위 상태 전이 기록을 최근 항목부터 확인합니다.
      events는 현재 Supervisor 빌드의 요청, 보호와 해제 결과를 연결한 관찰 요약을 보여줍니다.
      diagnose는 실시간 Supervisor 상태, SleepDisabled, 센서와 네트워크를 함께 점검합니다.
      verify-helper-boundary는 설치된 root helper가 CLI 직접 연결을 거부하는지 확인합니다.
      inspect는 현재 네트워크와 기기 안전 신호를 읽습니다.
      watch-handoff는 시작 네트워크에서 지정한 핫스팟으로의 전환을 확인합니다.
      """
    )
  }

  private static func writeError(_ message: String) {
    FileHandle.standardError.write(Data(message.utf8))
  }
}

private struct HistoryOptions {
  let limit: Int

  init(arguments: [String]) throws {
    if arguments.isEmpty {
      limit = 20
      return
    }
    guard arguments.count == 2,
      arguments[0] == "--limit",
      let parsed = Int(arguments[1]),
      parsed > 0,
      parsed <= 1_000
    else {
      throw CLIError.invalidValue("--limit")
    }
    limit = parsed
  }
}

private struct DeskOptions {
  let hardCapSeconds: Double
  let allowClosedLid: Bool

  init(arguments: [String]) throws {
    var hardCapSeconds: Double?
    var allowClosedLid = false
    var index = 0
    while index < arguments.count {
      let option = arguments[index]
      index += 1
      switch option {
      case "--closed-lid":
        allowClosedLid = true
      case "--max":
        guard index < arguments.count else {
          throw CLIError.missingValue(option)
        }
        hardCapSeconds = try Self.parseDuration(arguments[index])
        index += 1
      default:
        throw CLIError.unknownOption(option)
      }
    }
    guard let hardCapSeconds, hardCapSeconds <= 24 * 60 * 60 else {
      throw CLIError.missingValue("--max")
    }
    self.hardCapSeconds = hardCapSeconds
    self.allowClosedLid = allowClosedLid
  }

  private static func parseDuration(_ value: String) throws -> Double {
    guard let unit = value.last else {
      throw CLIError.invalidValue("--max")
    }
    let multiplier: Double
    switch unit {
    case "s": multiplier = 1
    case "m": multiplier = 60
    case "h": multiplier = 3_600
    default: throw CLIError.invalidValue("--max")
    }
    guard let amount = Double(value.dropLast()), amount.isFinite, amount > 0 else {
      throw CLIError.invalidValue("--max")
    }
    return amount * multiplier
  }
}

private struct AdaptiveOptions {
  let idleGraceSeconds: Double
  let hardCapSeconds: Double

  init(arguments: [String]) throws {
    var idleGraceSeconds = 2 * 60.0
    var hardCapSeconds: Double?
    var index = 0
    while index < arguments.count {
      let option = arguments[index]
      index += 1
      guard index < arguments.count else {
        throw CLIError.missingValue(option)
      }
      switch option {
      case "--idle-grace":
        idleGraceSeconds = try Self.parseDuration(arguments[index], option: option)
      case "--max":
        hardCapSeconds = try Self.parseDuration(arguments[index], option: option)
      default:
        throw CLIError.unknownOption(option)
      }
      index += 1
    }
    guard idleGraceSeconds <= 60 * 60 else {
      throw CLIError.invalidValue("--idle-grace")
    }
    guard let hardCapSeconds, hardCapSeconds <= 24 * 60 * 60 else {
      throw CLIError.missingValue("--max")
    }
    self.idleGraceSeconds = idleGraceSeconds
    self.hardCapSeconds = hardCapSeconds
  }

  private static func parseDuration(_ value: String, option: String) throws -> Double {
    guard let unit = value.last else {
      throw CLIError.invalidValue(option)
    }
    let multiplier: Double
    switch unit {
    case "s": multiplier = 1
    case "m": multiplier = 60
    case "h": multiplier = 3_600
    default: throw CLIError.invalidValue(option)
    }
    guard let amount = Double(value.dropLast()), amount.isFinite, amount > 0 else {
      throw CLIError.invalidValue(option)
    }
    return amount * multiplier
  }
}

private struct TripOptions {
  let networkTargetKind: WireCommuteNetworkTargetKind
  let hotspotSSID: String?
  let hardCapSeconds: Double
  let handoffTimeoutSeconds: Double

  init(arguments: [String]) throws {
    var hotspotSSID: String?
    var useUSBTethering = false
    var hardCapSeconds: Double?
    var handoffTimeoutSeconds = 15 * 60.0
    var index = 0

    while index < arguments.count {
      let option = arguments[index]
      index += 1
      if option == "--usb-tether" {
        useUSBTethering = true
        continue
      }
      guard index < arguments.count else {
        throw CLIError.missingValue(option)
      }
      let value = arguments[index]
      switch option {
      case "--hotspot":
        hotspotSSID = value
      case "--for":
        hardCapSeconds = try Self.parseDuration(value, option: option)
      case "--handoff-timeout":
        handoffTimeoutSeconds = try Self.parseDuration(value, option: option)
      default:
        throw CLIError.unknownOption(option)
      }
      index += 1
    }

    if useUSBTethering, hotspotSSID != nil {
      throw CLIError.invalidValue("--hotspot과 --usb-tether는 함께 사용할 수 없음")
    }
    if let hotspotSSID, !hotspotSSID.isEmpty,
      hotspotSSID.utf8.count <= CommuteTripRequest.maximumHotspotSSIDBytes
    {
      networkTargetKind = .wifiHotspot
      self.hotspotSSID = hotspotSSID
    } else if useUSBTethering {
      networkTargetKind = .usbTethering
      self.hotspotSSID = nil
    } else {
      throw CLIError.missingValue("--hotspot 또는 --usb-tether")
    }
    guard let hardCapSeconds else {
      throw CLIError.missingValue("--for")
    }
    guard hardCapSeconds <= 24 * 60 * 60 else {
      throw CLIError.invalidValue("--for")
    }
    guard handoffTimeoutSeconds <= 24 * 60 * 60 else {
      throw CLIError.invalidValue("--handoff-timeout")
    }
    self.hardCapSeconds = hardCapSeconds
    self.handoffTimeoutSeconds = handoffTimeoutSeconds
  }

  private static func parseDuration(_ value: String, option: String) throws -> Double {
    guard let unit = value.last else {
      throw CLIError.invalidValue(option)
    }
    let multiplier: Double
    switch unit {
    case "s": multiplier = 1
    case "m": multiplier = 60
    case "h": multiplier = 3_600
    default:
      throw CLIError.invalidValue(option)
    }
    guard let amount = Double(value.dropLast()), amount.isFinite, amount > 0 else {
      throw CLIError.invalidValue(option)
    }
    return amount * multiplier
  }
}

private struct WatchOptions {
  let hotspotSSID: String
  let timeoutSeconds: Int

  init(arguments: [String]) throws {
    var hotspotSSID: String?
    var timeoutSeconds = 15 * 60
    var index = 0

    while index < arguments.count {
      switch arguments[index] {
      case "--hotspot":
        index += 1
        guard index < arguments.count else {
          throw CLIError.missingValue("--hotspot")
        }
        hotspotSSID = arguments[index]
      case "--timeout-seconds":
        index += 1
        guard index < arguments.count,
          let value = Int(arguments[index]),
          value > 0
        else {
          throw CLIError.invalidValue("--timeout-seconds")
        }
        timeoutSeconds = value
      default:
        throw CLIError.unknownOption(arguments[index])
      }
      index += 1
    }

    guard let hotspotSSID, !hotspotSSID.isEmpty,
      hotspotSSID.utf8.count <= CommuteTripRequest.maximumHotspotSSIDBytes
    else {
      throw CLIError.missingValue("--hotspot")
    }
    self.hotspotSSID = hotspotSSID
    self.timeoutSeconds = timeoutSeconds
  }
}

private enum CLIError: Error, CustomStringConvertible {
  case unknownCommand(String)
  case invalidSubcommand(String)
  case unknownOption(String)
  case missingValue(String)
  case invalidValue(String)
  case deviceUnsafe(DeviceSafetyStopReason)
  case handoffTimedOut
  case helperBoundaryHelperUnavailable
  case helperBoundaryAccepted(protocolVersion: Int)
  case helperBoundaryInconclusive
  case supervisor(String)

  var description: String {
    switch self {
    case .unknownCommand(let command):
      "알 수 없는 명령: \(command)"
    case .invalidSubcommand(let command):
      "지원하지 않는 \(command) 하위 명령"
    case .unknownOption(let option):
      "알 수 없는 옵션: \(option)"
    case .missingValue(let option):
      "필수 값 누락: \(option)"
    case .invalidValue(let option):
      "잘못된 값: \(option)"
    case .deviceUnsafe:
      "기기 안전 정책이 통근 세션 시작을 허용하지 않음"
    case .handoffTimedOut:
      "제한 시간 안에 핫스팟 전환을 확인하지 못함"
    case .helperBoundaryHelperUnavailable:
      "설치된 root helper 서비스를 확인할 수 없음"
    case .helperBoundaryAccepted(let protocolVersion):
      "보안 경계 위반: root helper가 CLI 직접 연결을 허용함, protocol \(protocolVersion)"
    case .helperBoundaryInconclusive:
      "root helper 거부 여부를 제한 시간 안에 확인하지 못함"
    case .supervisor(let detail):
      detail
    }
  }
}

private enum HelperBoundaryProbeOutcome: Equatable, Sendable {
  case rejected
  case accepted(protocolVersion: Int)
  case timedOut
}

private final class HelperBoundaryProbeGate: @unchecked Sendable {
  private let lock = NSLock()
  private let connection: NSXPCConnection
  private var continuation: CheckedContinuation<HelperBoundaryProbeOutcome, Never>?

  init(
    connection: NSXPCConnection,
    continuation: CheckedContinuation<HelperBoundaryProbeOutcome, Never>
  ) {
    self.connection = connection
    self.continuation = continuation
  }

  func resolve(_ outcome: HelperBoundaryProbeOutcome) {
    lock.lock()
    guard let continuation else {
      lock.unlock()
      return
    }
    self.continuation = nil
    lock.unlock()
    connection.invalidate()
    continuation.resume(returning: outcome)
  }

  func scheduleTimeout(after timeout: TimeInterval) {
    DispatchQueue.global(qos: .userInitiated).asyncAfter(
      deadline: .now() + timeout
    ) { [weak self] in
      self?.resolve(.timedOut)
    }
  }
}
